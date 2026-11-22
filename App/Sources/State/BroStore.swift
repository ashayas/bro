import BroKit
import Combine
import SwiftUI
import UIKit

struct Banner: Equatable, Identifiable {
    let id = UUID()
    let mood: Mood
    let title: String
    let detail: String
    var channel: Channel?
}

/// The app's only mutable state. Views read it and call its methods. Main thread only.
final class BroStore: ObservableObject {
    private static let historyPerChannel = 200
    private static let historyTotal = 2000
    private static let directThreadLimit = 100

    @Published private(set) var state: SavedState
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var bluetoothStatus = TransportStatus.off
    @Published private(set) var wifiStatus = TransportStatus.off
    @Published private(set) var linkCount = 0
    @Published private(set) var activeChannel: Channel?
    @Published private(set) var banner: Banner?
    @Published private(set) var latestBroID: String?
    @Published var pendingInvite: BroCode?
    /// Launched before first unlock, so the real identity can't be read yet.
    @Published private(set) var isLocked: Bool

    private var disk: Disk
    private var node: MeshNode
    private let radios = Radios()
    private let feedback = Feedback()
    private let notifier = Notifier()
    private var observers: [NSObjectProtocol] = []
    private var saveWork: DispatchWorkItem?
    private var bannerWork: DispatchWorkItem?
    private var isActive = false

    var myID: String { node.myID }
    var rooms: [Room] { [state.ownRoom] + state.joined }

    init() {
        var disk = Disk()
        let identity = disk.loadIdentity()
        let state = disk.loadState()
        self.disk = disk
        self.state = state
        isLocked = !disk.canSave
        node = MeshNode(identity: identity, name: state.name, mood: state.mood, isOpen: state.isOpen)
        configureNode()
        radios.onChange = { [weak self] in self?.refreshRadios() }
    }

    private func configureNode() {
        node.contacts = state.people.compactMapValues(\.key)
        node.roommates = state.roommates
        node.invited = state.invited
        node.blocked = state.blocked
        node.mutedNames = blockedNames
        node.outbox = state.outbox
        node.remember(broIDs: state.bros.map(\.id))
        node.setRooms(rooms, ownRoomID: state.ownRoom.id)
        node.attach(radios.ble)
        node.attach(radios.lan)
        node.onEvent = { [weak self] in self?.handle($0) }
        feedback.settings = state.settings
    }

    private func unlock() {
        guard isLocked else { return }
        var disk = Disk()
        let identity = disk.loadIdentity()
        let state = disk.loadState()
        guard disk.canSave else { return }
        self.disk = disk
        self.state = state
        node = MeshNode(identity: identity, name: state.name, mood: state.mood, isOpen: state.isOpen)
        configureNode()
        isLocked = false
        if state.onboarded {
            goOnline()
            if isActive { radios.becameActive() }
        }
    }

    private var blockedNames: Set<BroName> {
        Set(state.blocked.compactMap { state.people[$0]?.name })
    }

    func launch() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
                self?.unlock()
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.becameActive()
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.enteredBackground()
            },
        ]
        // Radios wait for onboarding, so permission prompts arrive with an explanation.
        if state.onboarded { goOnline() }
        save()
    }

    private func goOnline() {
        node.start(startingTransports: false)
        radios.configure(bluetooth: state.settings.bluetooth, wifi: state.settings.wifi)
    }

    private func becameActive() {
        isActive = true
        unlock()
        guard state.onboarded else { return }
        radios.becameActive()
        node.requestPresence()
        notifier.clear()
        if let activeChannel { markRead(activeChannel) }
    }

    private func enteredBackground() {
        isActive = false
        saveNow()
        if state.onboarded { radios.enteredBackground() }
    }

    // MARK: Actions

    func finishOnboarding(name: BroName, mood: Mood, isOpen: Bool) {
        state.name = name
        state.mood = mood
        state.isOpen = isOpen
        state.onboarded = true
        node.setProfile(name: name, mood: mood)
        node.setOpen(isOpen)
        goOnline()
        radios.becameActive()
        notifier.requestPermission()
        save()
    }

    func say(_ mood: Mood, in channel: Channel) {
        guard let bro = node.say(mood, in: channel) else {
            let closed = channel == .open && !state.isOpen
            show(Banner(
                mood: closed ? .sus : .chill,
                title: closed ? "You're closed, bro" : "Easy, bro",
                detail: closed ? "Open up to bro on the Strip." : "That's a lot of bro. One sec."
            ))
            return
        }
        append(bro)
        if case let .direct(id) = channel { state.invited.insert(id) }
        latestBroID = bro.id
        feedback.sent(mood)
        save()
    }

    func replay(_ bro: Bro) {
        feedback.replay(bro.mood)
    }

    func show(_ channel: Channel) {
        guard state.onboarded else { return }
        if case let .room(id) = channel, !rooms.contains(where: { $0.id == id }) { return }
        dismissKeyboard()
        latestBroID = nil
        banner = nil
        withAnimation(.easeOut(duration: 0.24)) { activeChannel = channel }
        markRead(channel)
    }

    func closeChat() {
        withAnimation(.easeOut(duration: 0.22)) { activeChannel = nil }
    }

    func setOpen(_ open: Bool) {
        state.isOpen = open
        node.setOpen(open)
        feedback.tap()
        save()
    }

    func setProfile(name: BroName, mood: Mood) {
        state.name = name
        state.mood = mood
        node.setProfile(name: name, mood: mood)
        feedback.tap()
        save()
    }

    func update<Value>(_ setting: WritableKeyPath<Settings, Value>, to value: Value) {
        state.settings[keyPath: setting] = value
        feedback.settings = state.settings
        radios.configure(bluetooth: state.settings.bluetooth, wifi: state.settings.wifi)
        if state.settings.notifications { notifier.requestPermission() }
        refreshRadios()
        save()
    }

    func join(_ code: BroCode) {
        if let existing = rooms.first(where: { $0.code == code }) { return show(.room(existing.id)) }
        guard rooms.count < MeshNode.maxRooms else {
            show(Banner(mood: .wrecked, title: "Too many crews", detail: "Leave one first, bro."))
            return
        }
        // Key derivation is slow on purpose.
        DispatchQueue.global(qos: .userInitiated).async {
            let room = Room(code: code)
            DispatchQueue.main.async {
                guard !self.rooms.contains(room) else { return }
                self.state.joined.append(room)
                self.node.setRooms(self.rooms, ownRoomID: self.state.ownRoom.id)
                self.feedback.joined()
                self.show(.room(room.id))
                self.save()
            }
        }
    }

    func leave(_ room: Room) {
        state.joined.removeAll { $0 == room }
        node.setRooms(rooms, ownRoomID: state.ownRoom.id)
        forgetRoom(room.id)
    }

    func replaceCode() {
        let old = state.ownRoom.id
        state.ownRoom = Room(code: .random())
        node.setRooms(rooms, ownRoomID: state.ownRoom.id)
        forgetRoom(old)
    }

    private func forgetRoom(_ id: String) {
        if activeChannel == .room(id) { closeChat() }
        state.bros.removeAll { $0.channel == .room(id) }
        state.unread[.room(id)] = nil
        state.roomHosts[id] = nil
        state.roommates[id] = nil
        state.invited = node.invited
        save()
    }

    func block(_ id: String) {
        remember(id)
        state.blocked.insert(id)
        node.blocked = state.blocked
        node.mutedNames = blockedNames
        state.bros.removeAll { $0.senderID == id || $0.channel == .direct(id) }
        state.unread[.direct(id)] = nil
        if activeChannel == .direct(id) { closeChat() }
        save()
    }

    func unblock(_ id: String) {
        state.blocked.remove(id)
        node.blocked = state.blocked
        node.mutedNames = blockedNames
        save()
    }

    func clearHistory() {
        state.bros.removeAll()
        state.receipts.removeAll()
        state.unread.removeAll()
        save()
    }

    func copyCode() {
        UIPasteboard.general.string = state.ownRoom.code.description
        feedback.tap()
        show(Banner(mood: .respect, title: "Code copied", detail: "Only give it to real bros."))
    }

    func dismissBanner() {
        withAnimation { banner = nil }
    }

    // MARK: Reading

    func bros(in channel: Channel) -> [Bro] {
        state.bros.filter { $0.channel == channel }
    }

    func lastBro(in channel: Channel) -> Bro? {
        state.bros.last { $0.channel == channel }
    }

    var directThreads: [Bro] {
        var seen = Set<Channel>()
        return state.bros.reversed().filter { bro in
            guard case .direct = bro.channel else { return false }
            return seen.insert(bro.channel).inserted
        }
    }

    func members(of roomID: String) -> [Peer] {
        peers.filter { $0.isIn(room: roomID) }
    }

    func peer(_ id: String) -> Peer? {
        peers.first { $0.id == id }
    }

    func name(of id: String) -> String {
        (peer(id)?.name ?? state.people[id]?.name)?.text ?? "Mystery Bro"
    }

    func mood(of id: String) -> Mood {
        peer(id)?.mood ?? state.people[id]?.mood ?? .chill
    }

    func title(of channel: Channel) -> String {
        switch channel {
        case .open: return "The Strip"
        case let .direct(id): return name(of: id)
        case let .room(id):
            if id == state.ownRoom.id { return "Your Crew" }
            if let host = state.roomHosts[id] { return "\(host.text)'s Crew" }
            return rooms.first { $0.id == id }?.code.description ?? "Crew"
        }
    }

    func subtitle(of channel: Channel) -> String {
        switch channel {
        case .open:
            let count = peers.filter(\.isOpen).count
            return count == 1 ? "1 open bro in range" : "\(count) open bros in range"
        case let .room(id):
            let count = members(of: id).count
            return count == 0 ? "Just you, bro" : "You + \(count) online"
        case let .direct(id):
            return peer(id) == nil ? "Out of range" : "In range"
        }
    }

    func receipt(for bro: Bro) -> String? {
        guard bro.isMine else { return nil }
        let count = state.receipts[bro.id]?.count ?? 0
        switch bro.channel {
        case .open: return "Shouted"
        case .room: return count == 0 ? "Sent" : "Bro'd by \(count)"
        case .direct: return count == 0 ? "Floating…" : "Bro'd"
        }
    }

    // MARK: Events from the mesh

    private func handle(_ event: MeshEvent) {
        switch event {
        case let .bro(bro):
            received(bro)
        case let .ack(id, channel, from):
            guard let bro = state.bros.last(where: { $0.id == id }), bro.isMine, bro.channel == channel else { return }
            state.receipts[id, default: []].insert(from)
            save()
        case .peersChanged:
            refreshPeers()
        case .linksChanged:
            refreshRadios()
        }
    }

    private func received(_ bro: Bro) {
        guard !state.bros.contains(where: { $0.id == bro.id }) else { return }
        if bro.isVerified, bro.channel == .open,
           let index = state.bros.firstIndex(where: { !$0.isVerified && $0.id == bro.airToken }) {
            // The signed copy of something we heard on air.
            state.bros[index] = bro
            save()
            return
        }

        append(bro)
        if bro.isVerified {
            state.people[bro.senderID] = Person(
                name: bro.name, mood: bro.mood,
                key: node.contacts[bro.senderID] ?? node.peers[bro.senderID]?.agreementKey
            )
            state.roommates = node.roommates
        }

        let visible = isActive && activeChannel == bro.channel
        if visible {
            latestBroID = bro.id
            feedback.received(bro.mood)
        } else if state.bros.contains(where: { $0.id == bro.id }) { // not if the caps just dropped it
            state.unread[bro.channel, default: 0] += 1
            let title = bro.channel.isDirect ? bro.name.text : "\(bro.name.text) · \(title(of: bro.channel))"
            if isActive {
                show(Banner(mood: bro.mood, title: title, detail: bro.mood.line, channel: bro.channel))
                // The Strip can be a crowd. Only talk out loud for bros aimed at you.
                if bro.channel != .open { feedback.received(bro.mood) }
            } else if state.settings.notifications, bro.channel != .open {
                notifier.post(bro, title: title, badge: state.unread.filter { $0.key != .open }.values.reduce(0, +))
            }
        }
        // The ack goes out as soon as we return, so this has to be on disk first.
        if bro.channel == .open { save() } else { saveNow() }
    }

    private func append(_ bro: Bro) {
        state.bros.append(bro)
        let count = state.bros.lazy.filter { $0.channel == bro.channel }.count
        if count > Self.historyPerChannel, let oldest = state.bros.firstIndex(where: { $0.channel == bro.channel }) {
            state.receipts[state.bros[oldest].id] = nil
            state.bros.remove(at: oldest)
        }
        if bro.channel.isDirect {
            let threads = Set(state.bros.lazy.map(\.channel).filter(\.isDirect))
            if threads.count > Self.directThreadLimit, let stalest = state.bros.first(where: { $0.channel.isDirect })?.channel {
                drop { $0.channel == stalest }
                state.unread[stalest] = nil
            }
        }
        if state.bros.count > Self.historyTotal {
            let ids = Set(state.bros.prefix(state.bros.count - Self.historyTotal).map(\.id))
            drop { ids.contains($0.id) }
        }
    }

    private func drop(_ matches: (Bro) -> Bool) {
        for bro in state.bros where matches(bro) { state.receipts[bro.id] = nil }
        state.bros.removeAll(where: matches)
    }

    private func refreshPeers() {
        peers = node.peers.values.sorted { ($0.name.text, $0.id) < ($1.name.text, $1.id) }

        var people = state.people
        for peer in peers {
            people[peer.id] = Person(name: peer.name, mood: peer.mood, key: peer.agreementKey)
        }
        if people.count > 600 {
            let keep = Set(state.bros.map(\.senderID))
                .union(state.blocked).union(state.invited).union(peers.map(\.id))
            people = people.filter { keep.contains($0.key) }
        }

        var hosts = state.roomHosts
        for room in state.joined {
            if let host = peers.first(where: { $0.isIn(room: room.id) && $0.hostedRooms.contains(room.id) }) {
                hosts[room.id] = host.name
            }
        }
        guard people != state.people || hosts != state.roomHosts || node.roommates != state.roommates else { return }
        state.people = people
        state.roomHosts = hosts
        state.roommates = node.roommates
        save()
    }

    private func remember(_ id: String) {
        guard let peer = peer(id) else { return }
        state.people[id] = Person(name: peer.name, mood: peer.mood, key: peer.agreementKey)
    }

    private func refreshRadios() {
        bluetoothStatus = radios.ble.status
        wifiStatus = radios.lan.status
        linkCount = radios.ble.links.count + radios.lan.links.count
    }

    private func markRead(_ channel: Channel) {
        guard state.unread[channel] != nil else { return }
        state.unread[channel] = nil
        save()
    }

    private func show(_ banner: Banner) {
        bannerWork?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { self.banner = banner }
        let work = DispatchWorkItem { [weak self] in self?.dismissBanner() }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: Saving

    private func save() {
        guard saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        state.outbox = node.outbox
        disk.save(state)
    }
}

extension Channel {
    var isDirect: Bool {
        if case .direct = self { return true }
        return false
    }
}
