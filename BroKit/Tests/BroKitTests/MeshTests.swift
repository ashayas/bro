import XCTest
@testable import BroKit

final class MeshTests: XCTestCase {
    static let camp = Room(code: BroCode("CAMP2345")!)
    static let boat = Room(code: BroCode("BQAT6789")!)
    var camp: Room { Self.camp }
    var boat: Room { Self.boat }

    func testOpenBrosDiscoverEachOtherAndBro() {
        let net = TestNet(), a = net.user(), b = net.user()
        net.connect(a, b); net.settle()
        XCTAssertEqual(a.node.peers[b.id]?.isOpen, true)
        let bro = a.node.say(.party, in: .open)!
        net.deliver()
        XCTAssertEqual(b.bros.map(\.id), [bro.id])
        XCTAssertEqual(b.bros.first?.mood, .party)
        XCTAssertEqual(b.bros.first?.name, a.node.name)
    }

    func testClosedBroIsInvisibleAndOutOfTheOpenChannel() {
        let net = TestNet(), open = net.user(), closed = net.user(open: false)
        net.connect(open, closed); net.settle()
        XCTAssertNil(open.node.peers[closed.id])
        XCTAssertNil(closed.node.say(.happy, in: .open))
        open.node.say(.happy, in: .open)
        net.deliver()
        XCTAssertTrue(closed.bros.isEmpty)
    }

    func testClosingTakesYouOffTheRadarImmediately() {
        let net = TestNet(), a = net.user(), b = net.user()
        net.connect(a, b); net.settle()
        net.clock.advance(1)
        a.node.setOpen(false)
        net.deliver()
        XCTAssertNil(b.node.peers[a.id])
    }

    func testStrangerCannotDirectMessageClosedBro() {
        let net = TestNet(), stranger = net.user(), closed = net.user(open: false)
        net.connect(stranger, closed); net.settle()
        stranger.node.contacts[closed.id] = closed.node.identity.agreementKey
        XCTAssertNotNil(stranger.node.say(.angry, in: .direct(closed.id)))
        net.deliver()
        XCTAssertTrue(closed.bros.isEmpty)
        XCTAssertTrue(stranger.acks.isEmpty, "an ack would reveal they are here")
    }

    func testAnyoneCanDirectMessageOpenBro() {
        let net = TestNet(), a = net.user(), b = net.user()
        net.connect(a, b); net.settle()
        let bro = a.node.say(.love, in: .direct(b.id))!
        net.deliver()
        XCTAssertEqual(b.bros.first?.channel, .direct(a.id))
        XCTAssertEqual(a.acks.map(\.id), [bro.id])
    }

    func testClosedBrosWithTheCodeShareARoomAndCanDirectMessage() {
        let net = TestNet(), a = net.user(open: false, rooms: [camp]), b = net.user(open: false, rooms: [camp])
        net.connect(a, b); net.settle()
        XCTAssertEqual(a.node.peers[b.id]?.isIn(room: camp.id), true)
        XCTAssertEqual(a.node.peers[b.id]?.isOpen, false)
        let inRoom = a.node.say(.sos, in: .room(camp.id))!
        let direct = a.node.say(.sad, in: .direct(b.id))!
        net.deliver()
        XCTAssertEqual(Set(b.bros.map(\.id)), [inRoom.id, direct.id])
        XCTAssertEqual(Set(a.acks.map(\.id)), [inRoom.id, direct.id])
    }

    func testWrongCodeHearsNothingButStillRelays() {
        let net = TestNet()
        let a = net.user(open: false, rooms: [camp])
        let middle = net.user(open: false, rooms: [boat])
        let b = net.user(open: false, rooms: [camp])
        net.connect(a, middle); net.connect(middle, b); net.settle()
        a.node.say(.hype, in: .room(camp.id))
        net.deliver()
        XCTAssertTrue(middle.node.peers.isEmpty)
        XCTAssertTrue(middle.bros.isEmpty)
        XCTAssertEqual(b.bros.count, 1)
    }

    func testClosedBroHearsRepliesFromSomeoneTheyMessagedFirst() {
        let net = TestNet(), closed = net.user(open: false), open = net.user()
        closed.node.contacts[open.id] = open.node.identity.agreementKey
        net.connect(closed, open); net.settle()
        closed.node.say(.chill, in: .direct(open.id)); net.deliver()
        open.node.say(.respect, in: .direct(closed.id)); net.deliver()
        XCTAssertEqual(closed.bros.map(\.mood), [.respect])
    }

    func testLeavingARoomRevokesTheRoommateAllowance() {
        let net = TestNet(), me = net.user(open: false, rooms: [camp]), other = net.user(rooms: [camp])
        net.connect(me, other); net.settle()
        me.node.setRooms([], ownRoomID: nil); net.deliver()
        other.node.say(.angry, in: .direct(me.id)); net.deliver()
        XCTAssertTrue(me.bros.isEmpty)
    }

    func testFiveHopsYesSixHopsNo() {
        let net = TestNet(), line = (0..<7).map { _ in net.user() }
        for (a, b) in zip(line, line.dropFirst()) { net.connect(a, b) }
        line[0].node.say(.shocked, in: .open)
        net.deliver()
        // Origin plus four relays.
        XCTAssertEqual(line.dropFirst().map { $0.bros.count }, [1, 1, 1, 1, 1, 0])
    }

    func testDenseMeshDeliversExactlyOnce() {
        let net = TestNet(), crowd = (0..<14).map { _ in net.user() }
        for i in crowd.indices { for j in crowd.indices where j > i { net.connect(crowd[i], crowd[j]) } }
        crowd[0].node.say(.party, in: .open)
        net.deliver()
        XCTAssertTrue(crowd.dropFirst().allSatisfy { $0.bros.count == 1 })
        XCTAssertLessThanOrEqual(net.traffic.count, 14 * 14)
    }

    func testWalkingIntoRangeDeliversRecentBros() {
        let net = TestNet(), a = net.user(), b = net.user()
        a.node.say(.sleepy, in: .open)
        net.clock.advance(90)
        net.connect(a, b); net.deliver()
        XCTAssertEqual(b.bros.count, 1)
    }

    func testOldBrosAreNotReplayedToNewLinks() {
        let net = TestNet(), a = net.user(), b = net.user()
        a.node.say(.sleepy, in: .open)
        net.clock.advance(130)
        net.connect(a, b); net.deliver()
        XCTAssertTrue(b.bros.isEmpty)
    }

    func testDirectBroRetriesWhenRecipientReturns() {
        let net = TestNet(), a = net.user(), b = net.user()
        net.connect(a, b); net.settle(); net.disconnect(a, b)
        let bro = a.node.say(.wrecked, in: .direct(b.id))!
        net.clock.advance(300); a.node.tick()
        net.connect(a, b); net.settle()
        XCTAssertEqual(b.bros.map(\.id), [bro.id])
        XCTAssertEqual(a.acks.first?.id, bro.id)
    }

    func testLostAckIsRepeatedWithoutDuplicatingTheBro() {
        let net = TestNet(), a = net.user(), b = net.user()
        net.connect(a, b); net.settle()
        a.node.say(.flex, in: .direct(b.id))
        let outbound = net.queue.removeLast()
        b.port.onPacket?(outbound.data, String(a.port.id))
        net.queue.removeAll() // the ack is lost
        net.clock.advance(10)
        net.settle()
        XCTAssertEqual(b.bros.count, 1)
        XCTAssertEqual(a.acks.count, 1)
    }

    func testPresenceExpires() {
        let net = TestNet(), a = net.user(), b = net.user()
        net.connect(a, b); net.settle(); net.disconnect(a, b)
        net.clock.advance(41); a.node.tick()
        XCTAssertTrue(a.node.peers.isEmpty)
    }

    func testBlockingSilencesEveryChannel() {
        let net = TestNet(), a = net.user(rooms: [camp]), b = net.user(rooms: [camp])
        net.connect(a, b); net.settle()
        b.node.blocked = [a.id]
        a.node.say(.happy, in: .open); a.node.say(.happy, in: .room(camp.id)); a.node.say(.happy, in: .direct(b.id))
        net.settle()
        XCTAssertTrue(b.bros.isEmpty)
        XCTAssertNil(b.node.peers[a.id])
    }

    func testMessagesOutsideClockWindowAreDropped() {
        let net = TestNet(), skewed = TestClock()
        skewed.advance(16 * 60)
        let a = net.user(clock: skewed), b = net.user()
        net.connect(a, b)
        a.node.say(.happy, in: .open); net.deliver()
        XCTAssertTrue(b.bros.isEmpty)
    }

    func testReplayAfterRelayMemoryDoesNotResurrectPresence() {
        let net = TestNet(), a = net.user(), b = net.user(), late = net.user()
        net.connect(a, b); net.settle(); net.disconnect(a, b)
        net.clock.advance(100)
        net.connect(b, late); net.deliver()
        XCTAssertNil(late.node.peers[a.id])
    }

    func testAirShoutShowsUnverifiedAndOnlyOnce() {
        let net = TestNet(), a = net.user(), b = net.user()
        let bro = a.node.say(.hype, in: .open)!
        let shout = a.port.shouts[0]
        b.port.onShout?(shout); b.port.onShout?(shout)
        XCTAssertEqual(b.bros.count, 1)
        XCTAssertFalse(b.bros[0].isVerified)
        XCTAssertEqual(b.bros[0].id, bro.airToken)
    }

    func testOnlyOpenBrosAreShouted() {
        let net = TestNet(), a = net.user(rooms: [camp]), b = net.user()
        net.connect(a, b); net.settle()
        a.node.say(.love, in: .room(camp.id)); a.node.say(.love, in: .direct(b.id))
        XCTAssertTrue(a.port.shouts.isEmpty)
    }

    func testClosedBroIgnoresShouts() {
        let net = TestNet(), a = net.user(), b = net.user(open: false)
        a.node.say(.hype, in: .open)
        b.port.onShout?(a.port.shouts[0])
        XCTAssertTrue(b.bros.isEmpty)
    }

    func testFloodingIsRateLimited() {
        let net = TestNet(), a = net.user(), b = net.user()
        net.connect(a, b)
        let sent = (0..<50).compactMap { _ in a.node.say(.angry, in: .open) }
        net.deliver()
        XCTAssertEqual(sent.count, 8)
        XCTAssertEqual(b.bros.count, 8)
    }

    func testSealedTrafficLeaksNeitherCodeNorIdentity() {
        let net = TestNet(), a = net.user(open: false, rooms: [camp]), b = net.user(open: false, rooms: [camp])
        net.connect(a, b); net.settle()
        a.node.say(.happy, in: .room(camp.id)); net.deliver()
        XCTAssertFalse(net.traffic.isEmpty)
        for secret in [Data(camp.code.raw.utf8), camp.context, a.node.identity.agreementKey] {
            XCTAssertTrue(net.traffic.allSatisfy { $0.range(of: secret) == nil })
        }
    }
}
