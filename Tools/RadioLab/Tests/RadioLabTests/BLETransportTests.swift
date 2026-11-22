import FakeCoreBluetooth
import XCTest
@testable import BroRadio

final class BLETransportTests: XCTestCase {
    final class Phone {
        let device: Air.Device
        let identity: Identity
        let node: MeshNode
        let radio: BLETransport
        var bros: [Bro] = []
        var acks: [String] = []

        init(device: Air.Device, identity: Identity = Identity(), open: Bool = true, rooms: [Room] = []) {
            self.device = device
            self.identity = identity
            node = MeshNode(identity: identity, name: .random(), isOpen: open)
            radio = BLETransport(restorationID: "test")
            node.attach(radio)
            node.setRooms(rooms, ownRoomID: nil)
            node.onEvent = { [unowned self] event in
                switch event {
                case let .bro(bro): bros.append(bro)
                case let .ack(id, _, _): acks.append(id)
                default: break
                }
            }
            Air.shared.current = device
            node.start()
        }

        var verified: [Bro] { bros.filter(\.isVerified) }

        func sees(_ other: Phone) -> Bool { node.peers[other.node.myID] != nil }

        func setBackground(_ value: Bool) {
            device.background = value
            radio.setForeground(!value)
        }
    }

    var phones: [Phone] = []

    override func setUp() {
        Air.shared = Air()
    }

    override func tearDown() {
        phones.forEach { $0.node.stop() }
        phones.removeAll()
        XCTAssertEqual(Air.shared.violations, [], "CoreBluetooth rules broken")
        Air.shared.close()
    }

    @discardableResult
    func phone(open: Bool = true, rooms: [Room] = []) -> Phone {
        let made = Phone(device: Air.shared.device(), open: open, rooms: rooms)
        phones.append(made)
        return made
    }

    func until(_ what: String, timeout: TimeInterval = 16, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(condition(), "timed out: \(what)", file: file, line: line)
    }

    func testTwoPhonesLinkBothWaysAndBro() {
        let a = phone(), b = phone()
        until("discovery") { a.sees(b) && b.sees(a) }
        let bro = a.node.say(.party, in: .direct(b.node.myID))!
        until("delivery and ack") { b.verified.count == 1 && a.acks == [bro.id] }
        XCTAssertEqual(a.radio.links.count, 2)
    }

    func testClosedPhonesWithACodeFindEachOther() {
        let room = Room(code: BroCode("CAMP2345")!)
        let a = phone(open: false, rooms: [room]), b = phone(open: false, rooms: [room])
        until("discovery") { a.sees(b) && b.sees(a) }
        a.node.say(.sos, in: .room(room.id))
        until("room bro") { b.verified.count == 1 }
    }

    func testSmallestPossibleMTU() {
        Air.shared.mtu = 23
        let a = phone(), b = phone()
        until("discovery at MTU 23") { a.sees(b) && b.sees(a) }
        a.node.say(.angry, in: .direct(b.node.myID))
        until("delivery") { b.verified.count == 1 }
        XCTAssertGreaterThan(Air.shared.writes, 5)
    }

    func testNotificationBackpressureLosesNothing() {
        Air.shared.mtu = 23
        Air.shared.notifyBuffer = 4
        let a = phone(), b = phone()
        until("discovery", timeout: 30) { a.sees(b) && b.sees(a) }
        for _ in 0..<5 { a.node.say(.hype, in: .direct(b.node.myID)) }
        until("all five", timeout: 30) { b.verified.count == 5 && a.acks.count == 5 }
        XCTAssertGreaterThan(Air.shared.backpressureEvents, 0)
    }

    func testCampfireRelay() {
        let a = phone(), middle = phone(), b = phone()
        Air.shared.setInRange(a.device, b.device, false)
        until("two hops") { a.sees(b) && b.sees(a) && middle.sees(a) }
        a.node.say(.chill, in: .direct(b.node.myID))
        until("relayed") { b.verified.count == 1 }
        XCTAssertTrue(middle.bros.isEmpty)
    }

    func testAdvertisingAloneDeliversABro() {
        // The shout is never sent as a packet, so advertising is the only way it can arrive.
        let a = phone(), b = phone()
        until("ready") { a.radio.status == .ready && b.radio.status == .ready }
        Air.shared.setInRange(a.device, b.device, false)
        until("unlinked") { a.radio.links.isEmpty }
        a.radio.shout(AirShout(mood: .love, name: a.node.name, eventID: Data.random(16)))
        Air.shared.setInRange(a.device, b.device, true)
        until("heard on air", timeout: 4) { b.bros.contains { !$0.isVerified && $0.mood == .love } }
    }

    func testShoutingReturnsToTheBeacon() {
        let a = phone()
        until("ready") { a.radio.status == .ready }
        a.radio.shout(AirShout(mood: .party, name: a.node.name, eventID: Data.random(16)))
        let shoutingEnds = Date().addingTimeInterval(7)
        until("wait out the shouts", timeout: 9) { Date() > shoutingEnds }
        let b = phone()
        until("still discoverable") { b.sees(a) }
    }

    func testBluetoothOffAndOnAgain() {
        let a = phone(), b = phone()
        until("discovery") { a.sees(b) && b.sees(a) }
        Air.shared.setPower(a.device, on: false)
        until("links drop") { a.radio.links.isEmpty && b.radio.links.isEmpty && a.radio.status == .poweredOff }
        Air.shared.setPower(a.device, on: true)
        until("relink") { a.radio.links.count == 2 && b.radio.links.count == 2 }
        a.node.say(.flex, in: .direct(b.node.myID))
        until("delivery") { b.verified.count == 1 }
    }

    func testWalkOutOfRangeAndBack() {
        let a = phone(), b = phone()
        until("discovery") { a.sees(b) && b.sees(a) }
        Air.shared.setInRange(a.device, b.device, false)
        until("gone") { a.radio.links.isEmpty }
        let bro = a.node.say(.sad, in: .direct(b.node.myID))!
        Air.shared.setInRange(a.device, b.device, true)
        until("caught up") { b.verified.map(\.id) == [bro.id] }
    }

    func testConnectedPhonesKeepTalkingInTheBackground() {
        let a = phone(), b = phone()
        until("discovery") { a.sees(b) && b.sees(a) }
        a.setBackground(true)
        b.setBackground(true)
        a.node.say(.sleepy, in: .direct(b.node.myID))
        until("background delivery") { b.verified.count == 1 }
    }

    func testForegroundPhoneFindsPocketedPhone() {
        let pocket = phone()
        pocket.setBackground(true)
        let active = phone()
        until("found in pocket") { active.sees(pocket) && pocket.sees(active) }
    }

    func testStateRestorationAfterEviction() {
        let a = phone(), old = phone()
        until("discovery") { a.sees(old) && old.sees(a) }
        Air.shared.evictForRestoration(old.device)
        let revived = Phone(device: old.device, identity: old.identity)
        phones.removeAll { $0 === old }
        phones.append(revived)
        until("restored links") { revived.radio.links.count == 2 && revived.sees(a) }
        a.node.say(.respect, in: .direct(revived.node.myID))
        until("delivered after restore") { revived.verified.count == 1 }
        withExtendedLifetime(old) {}
    }

    func testPeerAppQuittingDropsTheGhostLink() {
        let a = phone(), b = phone()
        until("discovery") { a.sees(b) && b.sees(a) }
        Air.shared.killApp(b.device)
        phones.removeAll { $0 === b }
        until("ghost gone", timeout: 5) { a.radio.links.isEmpty }
        withExtendedLifetime(b) {}
    }

    func testAdvertisingFailureRecovers() {
        Air.shared.failingAdvertisements = 1
        let a = phone()
        a.setBackground(true) // can't find b by itself, so b has to hear a's advert
        let b = phone()
        until("advertising retried") { b.sees(a) && b.radio.links.count == 2 }
    }

    func testDepartedPeersDoNotHoldEveryConnectionSlot() {
        let me = phone()
        let departed = (0..<6).map { _ in phone() }
        until("six links", timeout: 25) { me.radio.links.count == 12 }
        me.setBackground(false)
        departed.forEach { Air.shared.setInRange(me.device, $0.device, false) }
        until("all gone") { me.radio.links.isEmpty }
        let staleAfter = Date().addingTimeInterval(5)
        until("slots go stale", timeout: 8) { Date() > staleAfter }
        let newcomer = phone()
        departed.forEach { Air.shared.setInRange(newcomer.device, $0.device, false) }
        until("room for the newcomer", timeout: 9) { me.radio.links.count == 2 }
    }

    func testPermissionDenied() {
        let device = Air.shared.device()
        device.authorized = false
        let denied = Phone(device: device)
        phones.append(denied)
        until("denied") { denied.radio.status == .denied }
    }

    func testCrowdBeyondTheConnectionLimit() {
        let crowd = (0..<10).map { _ in phone() }
        until("everyone sees everyone", timeout: 30) {
            crowd.allSatisfy { one in crowd.allSatisfy { $0 === one || one.sees($0) } }
        }
        crowd[0].node.say(.party, in: .open)
        until("everyone gets the bro") { crowd.dropFirst().allSatisfy { $0.verified.count == 1 } }
    }
}
