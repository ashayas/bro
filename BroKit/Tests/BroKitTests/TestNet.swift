import Foundation
@testable import BroKit

final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

/// In-memory links with explicit delivery, so tests are deterministic.
final class TestNet {
    final class Port: BroTransport {
        let id: Int
        unowned let net: TestNet
        var status: TransportStatus = .ready
        var links: Set<LinkID> = []
        var shouts: [AirShout] = []
        var cancelledShouts = 0
        var onPacket: ((Data, LinkID) -> Void)?
        var onLinkUp: ((LinkID) -> Void)?
        var onLinkDown: ((LinkID) -> Void)?
        var onStatus: ((TransportStatus) -> Void)?
        var onShout: ((AirShout) -> Void)?

        init(id: Int, net: TestNet) {
            self.id = id
            self.net = net
        }

        func start() {}
        func stop() {}
        func shout(_ shout: AirShout) { shouts.append(shout) }
        func cancelShouts() { cancelledShouts += 1 }
        func send(_ packet: Data, to link: LinkID) {
            guard links.contains(link), let other = Int(link) else { return }
            net.queue.append((id, other, packet))
            net.traffic.append(packet)
        }
    }

    final class User {
        let node: MeshNode
        let port: Port
        var bros: [Bro] = []
        var acks: [(id: String, channel: Channel, from: String)] = []

        init(node: MeshNode, port: Port) {
            self.node = node
            self.port = port
            node.attach(port)
            node.onEvent = { [unowned self] event in
                switch event {
                case let .bro(bro): bros.append(bro)
                case let .ack(id, channel, from): acks.append((id, channel, from))
                default: break
                }
            }
        }

        var id: String { node.myID }
    }

    let clock = TestClock()
    var users: [User] = []
    var queue: [(from: Int, to: Int, data: Data)] = []
    var traffic: [Data] = []

    func user(open: Bool = true, rooms: [Room] = [], clock custom: TestClock? = nil) -> User {
        let time = custom ?? clock
        let node = MeshNode(identity: Identity(), name: .random(), isOpen: open, now: { time.now })
        let user = User(node: node, port: Port(id: users.count, net: self))
        users.append(user)
        node.setRooms(rooms, ownRoomID: rooms.first?.id)
        return user
    }

    func connect(_ a: User, _ b: User) {
        a.port.links.insert(String(b.port.id))
        b.port.links.insert(String(a.port.id))
        a.port.onLinkUp?(String(b.port.id))
        b.port.onLinkUp?(String(a.port.id))
    }

    func disconnect(_ a: User, _ b: User) {
        a.port.links.remove(String(b.port.id))
        b.port.links.remove(String(a.port.id))
        a.port.onLinkDown?(String(b.port.id))
        b.port.onLinkDown?(String(a.port.id))
    }

    func deliver() {
        var steps = 0
        while !queue.isEmpty {
            let item = queue.removeFirst()
            users[item.to].port.onPacket?(item.data, String(item.from))
            steps += 1
            precondition(steps < 100_000, "packet storm")
        }
    }

    /// One presence round, plus a tick for anything it triggered.
    func settle() {
        for _ in 0..<2 {
            users.forEach {
                $0.node.requestPresence()
                $0.node.tick()
            }
            deliver()
        }
    }
}
