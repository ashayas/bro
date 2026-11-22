import Foundation
import Network

/// Same Wi-Fi, and Apple's peer-to-peer Wi-Fi when there's no router.
/// Bonjour finds bros and TCP carries the same sealed packets as Bluetooth.
public final class LANTransport: BroTransport {
    public static let serviceType = "_brochat._tcp"
    private static let policyDenied: Int32 = -65570
    private static let maxIncoming = 24
    private static let maxOutgoing = 16
    /// Every bro announces every 12 seconds, so silence this long isn't a bro.
    private static let idleTimeout: TimeInterval = 45
    private static let fallbackDelay: TimeInterval = 10
    /// First byte of the hello frame. Envelopes start with their version, which is never zero.
    private static let helloTag: UInt8 = 0
    private static let maxQueuedBytes = 96 * 1024

    private final class Link {
        let id: LinkID = "lan/\(UUID().uuidString)"
        let connection: NWConnection
        let isOutgoing: Bool
        var remoteName: String?
        let created = Date()
        var lastHeard = Date()
        var framer = StreamFramer()
        var ready = false
        var queuedBytes = 0

        init(_ connection: NWConnection, remoteName: String?) {
            self.connection = connection
            self.remoteName = remoteName
            isOutgoing = remoteName != nil
        }
    }

    public private(set) var status: TransportStatus = .off {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    public var links: Set<LinkID> { Set(connections.values.filter(\.ready).map(\.id)) }
    public var onPacket: ((Data, LinkID) -> Void)?
    public var onLinkUp: ((LinkID) -> Void)?
    public var onLinkDown: ((LinkID) -> Void)?
    public var onStatus: ((TransportStatus) -> Void)?
    public var onShout: ((AirShout) -> Void)?

    private let serviceType: String
    private var running = false
    private var name = ""
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var found: [String: (endpoint: NWEndpoint, since: Date)] = [:]
    private var connections: [LinkID: Link] = [:]
    private var timer: Timer?

    public convenience init() { self.init(serviceType: LANTransport.serviceType) }

    init(serviceType: String) { self.serviceType = serviceType }

    public func start() {
        guard !running else { return }
        running = true
        status = .starting
        // Fresh every launch, so it isn't a tracker.
        name = Data.random(8).hex
        startListener()
        startBrowser()
        timer = .scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.reconcile() }
    }

    public func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        found.removeAll()
        Array(connections.values).forEach(close)
        status = .off
    }

    public func send(_ packet: Data, to link: LinkID) {
        guard let link = connections[link], link.ready else { return }
        let framed = StreamFramer.frame(packet)
        guard link.queuedBytes + framed.count <= Self.maxQueuedBytes else { return close(link) }
        link.queuedBytes += framed.count
        link.connection.send(content: framed, completion: .contentProcessed { [weak self, weak link] error in
            guard let link else { return }
            link.queuedBytes -= framed.count
            if error != nil { self?.close(link) }
        })
    }

    private func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 6
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    private func startListener() {
        guard let listener = try? NWListener(using: parameters()) else {
            status = .failed("Couldn't listen on the local network")
            return
        }
        listener.service = NWListener.Service(name: name, type: serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.running, self.count(outgoing: false) < Self.maxIncoming else { return connection.cancel() }
            self.adopt(connection, remoteName: nil)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .failed:
                listener.cancel()
                self.listener = nil
            case let .waiting(error):
                self.report(error)
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters())
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, browser === self.browser else { return }
            switch state {
            case .ready:
                self.status = .ready
            case let .waiting(error):
                self.report(error)
            case let .failed(error):
                self.report(error)
                browser.cancel()
                self.browser = nil
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, browser === self.browser else { return }
            var next: [String: (endpoint: NWEndpoint, since: Date)] = [:]
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint, name != self.name else { continue }
                next[name] = (result.endpoint, self.found[name]?.since ?? Date())
            }
            self.found = next
            self.reconcile()
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    private func report(_ error: NWError) {
        if case let .dns(code) = error, code == Self.policyDenied {
            status = .denied
        } else {
            status = .failed(error.localizedDescription)
        }
    }

    private func reconcile() {
        guard running else { return }
        if listener == nil { startListener() }
        if browser == nil { startBrowser() }

        let now = Date()
        for link in Array(connections.values) {
            let neverConnected = !link.ready && now.timeIntervalSince(link.created) > 8
            let wentSilent = link.ready && now.timeIntervalSince(link.lastHeard) > Self.idleTimeout
            if neverConnected || wentSilent { close(link) }
        }
        // Includes whoever dialled us, thanks to the hello.
        let linked = Set(connections.values.compactMap(\.remoteName))
        for (remote, entry) in found where !linked.contains(remote) && count(outgoing: true) < Self.maxOutgoing {
            // Lower name dials. If discovery only worked one way, dial anyway after a wait.
            let isCaller = name < remote
            let isStranded = now.timeIntervalSince(entry.since) > Self.fallbackDelay
            if isCaller || isStranded {
                adopt(NWConnection(to: entry.endpoint, using: parameters()), remoteName: remote)
            }
        }
    }

    private func adopt(_ connection: NWConnection, remoteName: String?) {
        let link = Link(connection, remoteName: remoteName)
        connections[link.id] = link
        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link else { return }
            switch state {
            case .ready:
                guard !link.ready, self.connections[link.id] != nil else { return }
                link.ready = true
                link.lastHeard = Date()
                self.receive(link)
                self.send(Data([Self.helloTag]) + Data(self.name.utf8), to: link.id)
                self.onLinkUp?(link.id)
            case .failed, .cancelled:
                self.close(link)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func receive(_ link: Link) {
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak link] data, _, done, error in
            guard let self, let link, self.connections[link.id] != nil else { return }
            if let data { link.framer.append(data).forEach { self.handle($0, on: link) } }
            if done || error != nil {
                self.close(link)
            } else {
                self.receive(link)
            }
        }
    }

    private func handle(_ frame: Data, on link: Link) {
        link.lastHeard = Date()
        guard frame.first == Self.helloTag else {
            onPacket?(frame, link.id)
            return
        }
        guard let remote = String(data: frame.dropFirst(), encoding: .utf8), remote.count == 16 else { return }
        if remote == name { return close(link) }
        if link.remoteName == nil { link.remoteName = remote }
    }

    private func count(outgoing: Bool) -> Int {
        connections.values.filter { $0.isOutgoing == outgoing }.count
    }

    private func close(_ link: Link) {
        guard connections.removeValue(forKey: link.id) != nil else { return }
        link.connection.cancel()
        if link.ready { onLinkDown?(link.id) }
    }
}
