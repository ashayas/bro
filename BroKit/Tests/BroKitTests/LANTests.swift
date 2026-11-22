import XCTest
@testable import BroKit

/// Real Bonjour and real TCP on this machine.
final class LANTests: XCTestCase {
    func testTwoNodesFindEachOtherAndBroOverTheNetwork() {
        // A private service type, so nearby real apps don't join the test.
        let type = "_brot\(Int.random(in: 1000...9999))._tcp"
        let a = MeshNode(identity: Identity(), name: .random())
        let b = MeshNode(identity: Identity(), name: .random())
        a.attach(LANTransport(serviceType: type)); b.attach(LANTransport(serviceType: type))

        let found = expectation(description: "found"), heard = expectation(description: "heard")
        var didFind = false, didHear = false
        a.onEvent = { _ in
            if !didFind, a.peers[b.myID] != nil { didFind = true; found.fulfill() }
        }
        b.onEvent = { event in
            if case let .bro(bro) = event, !didHear, bro.mood == .party { didHear = true; heard.fulfill() }
        }
        a.start(); b.start()
        defer { a.stop(); b.stop() }
        wait(for: [found], timeout: 25)
        a.say(.party, in: .open)
        wait(for: [heard], timeout: 10)
    }
}
