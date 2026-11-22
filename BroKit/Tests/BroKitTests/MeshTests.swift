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

    func testCanStillBroSomeoneWhoWalkedOff() {
        let net = TestNet(), a = net.user(), b = net.user()
        net.connect(a, b); net.settle(); net.disconnect(a, b)
        net.clock.advance(60); a.node.tick()
        XCTAssertNil(a.node.peers[b.id])
        XCTAssertNotNil(a.node.say(.sos, in: .direct(b.id)))
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

    func testRateLimitedBroIsNotAckedUntilAccepted() {
        let net = TestNet(), a = net.user(), b = net.user()
        net.connect(a, b); net.settle(); net.disconnect(a, b)
        for _ in 0..<20 {
            a.node.say(.hype, in: .direct(b.id))
            net.clock.advance(1)
        }
        net.connect(a, b); net.deliver()
        XCTAssertEqual(b.bros.count, 12)
        XCTAssertEqual(Set(a.acks.map(\.id)), Set(b.bros.map(\.id)))
        for _ in 0..<3 {
            net.clock.advance(21); a.node.tick(); net.deliver()
        }
        XCTAssertEqual(b.bros.count, 20, "dropped bros must arrive on retry")
    }

    func testAckComesAfterTheAppHasTheBro() {
        let net = TestNet(), a = net.user(), b = net.user()
        net.connect(a, b); net.settle()
        var queuedWhenSaved = -1
        b.node.onEvent = { if case .bro = $0 { queuedWhenSaved = net.queue.count } }
        a.node.say(.happy, in: .direct(b.id))
        net.deliver()
        XCTAssertEqual(queuedWhenSaved, 0)
    }

    func testFreshIdentitiesCannotFloodDirectBros() {
        let net = TestNet(), victim = net.user()
        for _ in 0..<70 {
            let attacker = net.user()
            attacker.node.contacts[victim.id] = victim.node.identity.agreementKey
            net.connect(attacker, victim)
            attacker.node.say(.angry, in: .direct(victim.id)); net.deliver()
            net.disconnect(attacker, victim)
        }
        XCTAssertEqual(victim.bros.count, 40)
    }

    func testRotatingCodeRevokesPeopleYouMessaged() {
        let net = TestNet(), me = net.user(open: false, rooms: [camp]), old = net.user(rooms: [camp])
        net.connect(me, old); net.settle()
        me.node.say(.happy, in: .direct(old.id)); net.deliver()
        me.node.setRooms([boat], ownRoomID: boat.id); net.deliver()
        old.node.say(.angry, in: .direct(me.id)); net.deliver()
        XCTAssertTrue(me.bros.isEmpty)
    }

    func testLeavingARoomRemovesGhostPeers() {
        let net = TestNet(), me = net.user(rooms: [camp]), other = net.user(open: false, rooms: [camp])
        net.connect(me, other); net.settle()
        me.node.setRooms([], ownRoomID: nil)
        XCTAssertNil(me.node.peers[other.id])
    }

    func testLateBroCannotUndoGoodbye() {
        let net = TestNet(), a = net.user(), b = net.user()
        net.connect(a, b); net.settle()
        net.clock.advance(1); a.node.say(.happy, in: .open)
        let late = net.queue
        net.queue.removeAll()
        net.clock.advance(1); a.node.setOpen(false); net.deliver()
        net.queue = late; net.deliver()
        XCTAssertNil(b.node.peers[a.id])
    }

    func testClosingStopsShoutsAndCatchUp() {
        let net = TestNet(), a = net.user(), late = net.user()
        a.node.say(.party, in: .open)
        a.node.setOpen(false)
        XCTAssertEqual(a.port.cancelledShouts, 1)
        net.connect(a, late); net.deliver()
        XCTAssertTrue(late.bros.isEmpty)
    }

    func testUnsignedOpenJunkIsNotRelayed() {
        let net = TestNet(), a = net.user(), b = net.user()
        net.connect(a, b); net.deliver()
        let before = net.traffic.count
        a.node.receive(Envelope(kind: .open, payload: Data.random(120)).encoded, from: "stranger")
        XCTAssertEqual(net.traffic.count, before)
    }

    func testOutboxSurvivesRelaunch() {
        let net = TestNet(), a = net.user(), b = net.user()
        net.connect(a, b); net.settle(); net.disconnect(a, b)
        let bro = a.node.say(.sad, in: .direct(b.id))!
        let saved = try! JSONDecoder().decode([OutboxItem].self, from: JSONEncoder().encode(a.node.outbox))

        let revived = TestNet.User(
            node: MeshNode(identity: a.node.identity, name: a.node.name, now: { net.clock.now }),
            port: TestNet.Port(id: net.users.count, net: net)
        )
        net.users.append(revived)
        revived.node.contacts = [b.id: b.node.identity.agreementKey]
        revived.node.outbox = saved
        net.clock.advance(200)
        net.connect(revived, b); net.deliver()
        XCTAssertEqual(b.bros.map(\.id), [bro.id])
        XCTAssertTrue(revived.node.outbox.isEmpty)
    }

    func testRetryDoesNotNeedVisiblePresence() {
        let net = TestNet(), closed = net.user(open: false), open = net.user()
        closed.node.contacts[open.id] = open.node.identity.agreementKey
        net.connect(closed, open); net.settle()
        closed.node.say(.chill, in: .direct(open.id)); net.deliver()
        net.disconnect(closed, open)
        let bro = open.node.say(.respect, in: .direct(closed.id))!
        net.clock.advance(200)
        net.connect(closed, open); net.deliver()
        XCTAssertEqual(closed.bros.map(\.id), [bro.id])
    }

    func testBlockedNameIsMutedOnAir() {
        let net = TestNet(), a = net.user(), b = net.user()
        a.node.say(.angry, in: .open)
        b.node.mutedNames = [a.node.name]
        b.port.onShout?(a.port.shouts[0])
        XCTAssertTrue(b.bros.isEmpty)
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
