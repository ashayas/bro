import Foundation

public typealias LinkID = String

public enum TransportStatus: Equatable {
    case off, starting, ready, denied, poweredOff, unsupported
    case failed(String)
}

/// A way to move opaque packets to direct neighbours. Main queue only.
public protocol BroTransport: AnyObject {
    var status: TransportStatus { get }
    var links: Set<LinkID> { get }

    var onPacket: ((Data, LinkID) -> Void)? { get set }
    var onLinkUp: ((LinkID) -> Void)? { get set }
    var onLinkDown: ((LinkID) -> Void)? { get set }
    var onStatus: ((TransportStatus) -> Void)? { get set }
    var onShout: ((AirShout) -> Void)? { get set }

    func start()
    func stop()
    func send(_ packet: Data, to link: LinkID)
    /// Connectionless broadcast, where the radio supports it.
    func shout(_ shout: AirShout)
}

public extension BroTransport {
    func shout(_ shout: AirShout) {}
}
