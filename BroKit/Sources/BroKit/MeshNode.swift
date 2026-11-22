import Foundation

public enum Channel: Hashable, Codable {
    case open
    case room(String)
    case direct(String)
}

public struct Peer: Identifiable, Equatable {
    public let id: String
    public let agreementKey: Data
    public internal(set) var name: BroName
    public internal(set) var mood: Mood
    public internal(set) var openSeen: Date?
    public internal(set) var roomsSeen: [String: Date] = [:]
    public internal(set) var hostedRooms: Set<String> = []

    public var isOpen: Bool { openSeen != nil }
    public func isIn(room id: String) -> Bool { roomsSeen[id] != nil }
}

public struct Bro: Identifiable, Codable, Equatable {
    public let id: String
    public let channel: Channel
    public let senderID: String
    public let name: BroName
    public let mood: Mood
    public let date: Date
    public let isMine: Bool
    /// False for connectionless shouts, which can't carry a signature.
    public let isVerified: Bool

    /// Links a "heard on air" bro to its signed copy.
    public var airToken: String { String(id.prefix(16)) }
}

/// A direct bro that hasn't been acknowledged yet. Persist it to keep trying after a relaunch.
public struct OutboxItem: Codable, Equatable {
    public let id: String
    let peerID: String
    let signed: Data
    let created: Date
    var attempted: Date
}

public enum MeshEvent {
    case bro(Bro)
    case ack(broID: String, channel: Channel, from: String)
    case peersChanged
    case linksChanged
}

/// Who hears what, who may message whom, and flood relay between transports.
/// Knows nothing about radios or UI. Main queue only.
public final class MeshNode {
    public enum Timing {
        public static let presenceInterval: TimeInterval = 12
        public static let presenceLifetime: TimeInterval = 40
        public static let maxClockSkew: TimeInterval = 15 * 60
        public static let retryInterval: TimeInterval = 8
        public static let backgroundRetryInterval: TimeInterval = 20
        public static let relayMemory: TimeInterval = 120
    }

    public static let maxRooms = 12
    private static let maxPeers = 300
    private static let maxAckedRoomSize = 12
    private static let maxContacts = 1000
    private static let maxOutbox = 100

    public let identity: Identity
    public let myID: String
    public var onEvent: ((MeshEvent) -> Void)?

    public private(set) var name: BroName
    public private(set) var mood: Mood
    public private(set) var isOpen: Bool
    public private(set) var rooms: [Room] = []
    public private(set) var ownRoomID: String?
    public private(set) var peers: [String: Peer] = [:]

    public var blocked: Set<String> = [] {
        didSet {
            blocked.forEach { peers[$0] = nil }
            onEvent?(.peersChanged)
        }
    }
    /// Agreement keys of people we can message while they're out of sight.
    public var contacts: [String: Data] = [:]
    /// People who have proven they hold one of our codes, by room.
    public var roommates: [String: Set<String>] = [:]
    /// People we messaged first. They can answer even if we're closed.
    public var invited: Set<String> = []
    /// Shouts carry no identity, so blocking can only match them by name.
    public var mutedNames: Set<BroName> = []

    private let now: () -> Date
    private var transports: [BroTransport] = []
    private var linkOwners: [LinkID: BroTransport] = [:]
    private var linkBudgets: [LinkID: TokenBucket] = [:]
    private var senderBudgets: [String: TokenBucket] = [:]
    private var openBudget = TokenBucket(rate: 10, burst: 40)
    private var directBudget = TokenBucket(rate: 5, burst: 40)
    private var relayBudget = TokenBucket(rate: 80, burst: 500)
    private var sendBudget = TokenBucket(rate: 2, burst: 8)
    private var seenPackets = RecentSet<Data>(capacity: 8000)
    private var seenEvents = RecentSet<String>(capacity: 4000)
    private var seenShouts = RecentSet<Data>(capacity: 1000)
    private var latestPresence: [String: UInt64] = [:]
    private var recent: [(envelope: Envelope, at: Date, isMine: Bool)] = []
    private var pending: [String: OutboxItem] = [:]
    private var lastPresence = Date.distantPast
    private var presenceRequested = false
    private var timer: Timer?

    public var outbox: [OutboxItem] {
        get { pending.values.sorted { ($0.created, $0.id) < ($1.created, $1.id) } }
        set { pending = Dictionary(newValue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }

    public init(
        identity: Identity, name: BroName, mood: Mood = .happy, isOpen: Bool = true,
        now: @escaping () -> Date = Date.init
    ) {
        self.identity = identity
        myID = identity.peerID
        self.name = name
        self.mood = mood
        self.isOpen = isOpen
        self.now = now
    }

    // MARK: Lifecycle

    /// Pass `false` when the caller switches radios on and off itself.
    public func start(startingTransports: Bool = true) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if startingTransports { transports.forEach { $0.start() } }
        requestPresence()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        transports.forEach { $0.stop() }
    }

    public func attach(_ transport: BroTransport) {
        transports.append(transport)
        transport.onPacket = { [weak self] in self?.receive($0, from: $1) }
        transport.onShout = { [weak self] in self?.hear($0) }
        transport.onLinkUp = { [weak self, weak transport] link in
            guard let self, let transport else { return }
            self.linkUp(link, on: transport)
        }
        transport.onLinkDown = { [weak self] link in
            self?.linkOwners[link] = nil
            self?.linkBudgets[link] = nil
            self?.onEvent?(.linksChanged)
        }
    }

    public func tick() {
        let time = now()
        let cutoff = time.addingTimeInterval(-Timing.presenceLifetime)
        var changed = false
        for (id, original) in peers {
            var peer = original
            if let seen = peer.openSeen, seen < cutoff { peer.openSeen = nil }
            peer.roomsSeen = peer.roomsSeen.filter { $0.value >= cutoff }
            guard peer != original else { continue }
            changed = true
            peers[id] = peer.openSeen == nil && peer.roomsSeen.isEmpty ? nil : peer
        }
        if changed { onEvent?(.peersChanged) }

        recent.removeAll { time.timeIntervalSince($0.at) > Timing.relayMemory }
        pending = pending.filter { time.timeIntervalSince($0.value.created) < Timing.maxClockSkew }
        if senderBudgets.count > 2000 { senderBudgets.removeAll() }
        if latestPresence.count > 4000 { latestPresence.removeAll() }
        if linkBudgets.count > 500 { linkBudgets = linkBudgets.filter { linkOwners[$0.key] != nil } }
        if contacts.count > Self.maxContacts {
            contacts = contacts.filter { invited.contains($0.key) || peers[$0.key] != nil }
        }
        if !linkOwners.isEmpty { retryPending(after: Timing.backgroundRetryInterval) }

        if presenceRequested || time.timeIntervalSince(lastPresence) >= Timing.presenceInterval {
            announce()
        }
    }

    /// Coalesced onto the next tick, so a burst of new links means one announcement.
    public func requestPresence() { presenceRequested = true }

    /// Seed from saved history, so a relaunch doesn't show the same bro twice.
    public func remember(broIDs: [String]) {
        broIDs.forEach { seenEvents.insert($0) }
    }

    // MARK: Settings

    public func setProfile(name: BroName, mood: Mood) {
        guard name != self.name || mood != self.mood else { return }
        self.name = name
        self.mood = mood
        requestPresence()
    }

    public func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        if !open {
            transports.forEach { $0.cancelShouts() }
            // Nobody who arrives later should be handed what we said while open.
            recent.removeAll { $0.isMine && $0.envelope.kind == .open }
            post(.goodbye, in: .open)
        }
        isOpen = open
        requestPresence()
        onEvent?(.peersChanged)
    }

    public func setRooms(_ newRooms: [Room], ownRoomID: String?) {
        let kept = Array(newRooms.prefix(Self.maxRooms))
        let keptIDs = Set(kept.map(\.id))
        for room in rooms where !keptIDs.contains(room.id) {
            post(.goodbye, in: .room(room.id))
            let revoked = roommates.removeValue(forKey: room.id) ?? []
            // Having messaged someone must not outlive the code they got in with.
            invited.subtract(revoked.filter { id in !roommates.values.contains { $0.contains(id) } })
            for (id, var peer) in peers where peer.isIn(room: room.id) {
                peer.roomsSeen[room.id] = nil
                peers[id] = peer.openSeen == nil && peer.roomsSeen.isEmpty ? nil : peer
            }
        }
        rooms = kept
        self.ownRoomID = ownRoomID
        requestPresence()
        onEvent?(.peersChanged)
    }

    // MARK: Saying bro

    @discardableResult
    public func say(_ mood: Mood, in channel: Channel) -> Bro? {
        if channel == .open, !isOpen { return nil }
        let time = now()
        guard sendBudget.take(at: time), let message = post(.bro(mood), in: channel) else { return nil }

        let id = message.eventID.hex
        seenEvents.insert(id)
        switch channel {
        case .open:
            let shout = AirShout(mood: mood, name: name, eventID: message.eventID)
            seenShouts.insert(shout.token)
            transports.forEach { $0.shout(shout) }
        case let .direct(peerID):
            invited.insert(peerID)
            pending[id] = OutboxItem(id: id, peerID: peerID, signed: message.signed, created: time, attempted: time)
            if pending.count > Self.maxOutbox, let oldest = pending.values.min(by: { $0.created < $1.created }) {
                pending[oldest.id] = nil
            }
        case .room:
            break
        }
        return Bro(
            id: id, channel: channel, senderID: myID, name: name, mood: mood,
            date: time, isMine: true, isVerified: true
        )
    }

    private func announce() {
        presenceRequested = false
        lastPresence = now()
        if isOpen { post(.presence(mood: mood, isHost: false), in: .open) }
        for room in rooms {
            post(.presence(mood: mood, isHost: room.id == ownRoomID), in: .room(room.id))
        }
    }

    @discardableResult
    private func post(_ body: Body, in channel: Channel) -> Message? {
        let kind: PacketKind
        let context: Data
        let seal: (Data) -> Data?
        switch channel {
        case .open:
            kind = .open
            context = Data()
            seal = { $0 }
        case let .room(id):
            guard let room = rooms.first(where: { $0.id == id }) else { return nil }
            kind = .room
            context = room.context
            seal = { Seal.room($0, key: room.symmetricKey) }
        case let .direct(id):
            guard let key = key(for: id) else { return nil }
            kind = .direct
            context = key
            seal = { Seal.direct($0, to: key) }
        }
        guard let message = Message.create(
            body: body, name: name, identity: identity, kind: kind, context: context, date: now()
        ), let payload = seal(message.signed) else { return nil }
        originate(Envelope(kind: kind, payload: payload))
        return message
    }

    private func key(for peerID: String) -> Data? {
        peers[peerID]?.agreementKey ?? contacts[peerID]
    }

    // MARK: Relay

    private func originate(_ envelope: Envelope) {
        seenPackets.insert(envelope.id)
        remember(envelope, isMine: true)
        flood(envelope, except: nil)
    }

    private func remember(_ envelope: Envelope, isMine: Bool) {
        recent.append((envelope, now(), isMine))
        if recent.count > 160 { recent.removeFirst(recent.count - 160) }
    }

    private func flood(_ envelope: Envelope, except source: LinkID?) {
        let data = envelope.encoded
        for (link, transport) in linkOwners where link != source {
            transport.send(data, to: link)
        }
    }

    private func linkUp(_ link: LinkID, on transport: BroTransport) {
        linkOwners[link] = transport
        // Walk into range and you get the last two minutes.
        let cutoff = now().addingTimeInterval(-Timing.relayMemory)
        for item in recent where item.at >= cutoff {
            transport.send(item.envelope.encoded, to: link)
        }
        requestPresence()
        retryPending(after: Timing.retryInterval)
        onEvent?(.linksChanged)
    }

    func receive(_ data: Data, from link: LinkID) {
        let time = now()
        var budget = linkBudgets[link] ?? TokenBucket(rate: 60, burst: 320)
        let allowed = budget.take(at: time)
        linkBudgets[link] = budget
        guard allowed, let envelope = Envelope(data), seenPackets.insert(envelope.id) else { return }

        // Open packets can be checked, so junk stops here. Sealed ones only get a budget.
        var openMessage: Message?
        if envelope.kind == .open {
            guard let message = Message(envelope.payload, kind: .open, context: Data()) else { return }
            openMessage = message
        }
        if envelope.ttl > 0, relayBudget.take(at: time) {
            var onward = envelope
            onward.ttl -= 1
            remember(onward, isMine: false)
            flood(onward, except: link)
        }

        switch envelope.kind {
        case .open:
            if let openMessage { handle(openMessage, in: .open) }
        case .room:
            for room in rooms {
                guard let plain = Seal.openRoom(envelope.payload, key: room.symmetricKey) else { continue }
                if let message = Message(plain, kind: .room, context: room.context) {
                    handle(message, in: .room(room.id))
                }
                break
            }
        case .direct:
            if let plain = Seal.openDirect(envelope.payload, identity: identity),
               let message = Message(plain, kind: .direct, context: identity.agreementKey) {
                handle(message, in: .direct(message.senderID))
            }
        }
    }

    // MARK: Policy

    private func handle(_ message: Message, in channel: Channel) {
        let sender = message.senderID
        guard sender != myID, !blocked.contains(sender) else { return }
        let time = now()
        let sent = Date(timeIntervalSince1970: Double(message.milliseconds) / 1000)
        guard abs(time.timeIntervalSince(sent)) <= Timing.maxClockSkew else { return }

        switch message.body {
        case let .presence(mood, isHost):
            guard isNewest(message, in: channel) else { return }
            saw(message, in: channel, sent: sent, mood: mood, isHost: isHost)
            retryPending(after: Timing.retryInterval, for: sender)
        case .goodbye:
            guard isNewest(message, in: channel), var peer = peers[sender] else { return }
            switch channel {
            case .open: peer.openSeen = nil
            case let .room(id): peer.roomsSeen[id] = nil
            case .direct: return
            }
            peers[sender] = peer.openSeen == nil && peer.roomsSeen.isEmpty ? nil : peer
            onEvent?(.peersChanged)
        case let .ack(id):
            guard channel != .open else { return }
            if pending[id.hex]?.peerID == sender, channel == .direct(sender) { pending[id.hex] = nil }
            onEvent?(.ack(broID: id.hex, channel: channel, from: sender))
        case let .bro(mood):
            receiveBro(mood, message, in: channel, sent: sent, at: time)
        }
    }

    private func receiveBro(_ mood: Mood, _ message: Message, in channel: Channel, sent: Date, at time: Date) {
        guard mayReceive(from: message.senderID, in: channel) else { return }

        let id = message.eventID.hex
        guard !seenEvents.contains(id) else {
            // A retry of something we accepted means our ack went missing.
            if case .direct = channel { post(.ack(message.eventID), in: channel) }
            return
        }
        var budget = senderBudgets[message.senderID] ?? TokenBucket(rate: 2, burst: 12)
        let allowed = budget.take(at: time)
        senderBudgets[message.senderID] = budget
        guard allowed else { return }

        var shouldAck = false
        switch channel {
        case .open:
            guard openBudget.take(at: time) else { return }
            seenShouts.insert(Data(message.eventID.prefix(8)))
            if isNewest(message, in: channel) { saw(message, in: channel, sent: sent, mood: mood, isHost: nil) }
        case let .room(roomID):
            // A late bro must not undo a newer goodbye.
            if isNewest(message, in: channel) { saw(message, in: channel, sent: sent, mood: mood, isHost: nil) }
            shouldAck = peers.values.filter { $0.isIn(room: roomID) }.count <= Self.maxAckedRoomSize
        case .direct:
            // Caps the total, since fresh identities dodge the per-sender limit.
            guard directBudget.take(at: time) else { return }
            contacts[message.senderID] = message.agreementKey
            shouldAck = true
        }
        // Only once admitted: a dropped bro must be retryable, and must not be acked.
        seenEvents.insert(id)

        onEvent?(.bro(Bro(
            id: id, channel: channel, senderID: message.senderID, name: message.name, mood: mood,
            date: min(sent, time), isMine: false, isVerified: true
        )))
        // Ack last: the app has saved it by now.
        if shouldAck { post(.ack(message.eventID), in: channel) }
    }

    /// The product rule: open to you, or holds a code you share.
    private func mayReceive(from sender: String, in channel: Channel) -> Bool {
        switch channel {
        case .open: return isOpen
        case .room: return true
        case .direct: return isOpen || invited.contains(sender) || roommates.values.contains { $0.contains(sender) }
        }
    }

    private func isNewest(_ message: Message, in channel: Channel) -> Bool {
        let key = "\(message.senderID)|\(channel)"
        if let latest = latestPresence[key], latest > message.milliseconds { return false }
        latestPresence[key] = message.milliseconds
        return true
    }

    private func saw(_ message: Message, in channel: Channel, sent: Date, mood: Mood, isHost: Bool?) {
        let time = min(sent, now())
        let id = message.senderID
        // Keep the key after they walk off, so you can still bro them and retries still seal.
        contacts[id] = message.agreementKey
        if case let .room(roomID) = channel, (roommates[roomID]?.count ?? 0) < 200 {
            // Membership outlives presence: they still hold the code.
            roommates[roomID, default: []].insert(id)
        }
        // A replayed two-minute-old packet must not put someone back on the radar.
        guard now().timeIntervalSince(time) <= Timing.presenceLifetime else { return }
        guard peers[id] != nil || peers.count < Self.maxPeers else { return }

        let old = peers[id]
        var peer = old ?? Peer(id: id, agreementKey: message.agreementKey, name: message.name, mood: mood)
        peer.name = message.name
        peer.mood = mood
        switch channel {
        case .open:
            peer.openSeen = time
        case let .room(roomID):
            peer.roomsSeen[roomID] = time
            if isHost == true { peer.hostedRooms.insert(roomID) }
        case .direct:
            return
        }
        peers[id] = peer
        if old == nil { requestPresence() }
        onEvent?(.peersChanged)
    }

    private func retryPending(after interval: TimeInterval, for peerID: String? = nil) {
        let time = now()
        for (id, item) in pending
        where (peerID == nil || item.peerID == peerID) && time.timeIntervalSince(item.attempted) >= interval {
            // Same signed bro, fresh seal: new packet to the relays, same event to the recipient.
            guard let key = key(for: item.peerID), let payload = Seal.direct(item.signed, to: key) else { continue }
            pending[id]?.attempted = time
            originate(Envelope(kind: .direct, payload: payload))
        }
    }

    private func hear(_ shout: AirShout) {
        guard isOpen, !mutedNames.contains(shout.name), seenShouts.insert(shout.token), openBudget.take(at: now()) else { return }
        onEvent?(.bro(Bro(
            id: shout.token.hex, channel: .open, senderID: "air:\(shout.token.hex)",
            name: shout.name, mood: shout.mood, date: now(), isMine: false, isVerified: false
        )))
    }
}
