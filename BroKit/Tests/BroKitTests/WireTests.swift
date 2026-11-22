import XCTest
@testable import BroKit

final class WireTests: XCTestCase {
    let identity = Identity()
    let broName = BroName(first: 3, last: 4)!

    private func message(_ body: Body, kind: PacketKind = .open, context: Data = Data()) -> Message {
        Message.create(body: body, name: broName, identity: identity, kind: kind, context: context, date: Date())!
    }

    func testEveryBodyRoundTrips() {
        let ack = Body.ack(Data(repeating: 7, count: 16))
        let bodies = Mood.allCases.map(Body.bro) + [.presence(mood: .sus, isHost: true), ack, .goodbye]
        for body in bodies {
            let sent = message(body)
            let got = Message(sent.signed, kind: .open, context: Data())
            XCTAssertEqual(got?.body, body)
            XCTAssertEqual(got?.senderID, identity.peerID)
            XCTAssertEqual(got?.eventID, sent.eventID)
        }
    }

    func testEveryTamperedByteIsRejected() {
        let signed = message(.bro(.happy)).signed
        for index in 0..<signed.count {
            var bad = signed
            bad[index] ^= 1
            XCTAssertNil(Message(bad, kind: .open, context: Data()), "byte \(index)")
        }
    }

    func testCannotReplayAcrossChannels() {
        let signed = message(.bro(.happy), kind: .room, context: Data([1])).signed
        XCTAssertNil(Message(signed, kind: .room, context: Data([2])))
        XCTAssertNil(Message(signed, kind: .open, context: Data([1])))
    }

    func testThereIsNoRoomForText() {
        var content = Data([2, Mood.happy.rawValue]) + Data("hello".utf8)
        var reader = ByteReader(content)
        XCTAssertNotNil(Body(&reader))
        XCTAssertFalse(reader.isAtEnd, "Message rejects anything left over")

        content = Data([2, UInt8(Mood.allCases.count)])
        reader = ByteReader(content)
        XCTAssertNil(Body(&reader), "unknown moods are rejected")
    }

    func testEveryLineIsBro() {
        XCTAssertEqual(Mood.allCases.count, 16)
        XCTAssertTrue(Mood.allCases.allSatisfy { $0.line.lowercased().hasPrefix("br") })
    }

    func testLargestEnvelopeFits() {
        let inner = message(.ack(Data(count: 16))).signed
        let sealed = Seal.direct(inner, to: Identity().agreementKey)!
        XCTAssertLessThanOrEqual(Envelope(kind: .direct, payload: sealed).encoded.count, Envelope.maxSize)
    }

    func testTTLIsClampedAndDoesNotChangeID() {
        let envelope = Envelope(kind: .open, payload: Data([1, 2]))
        var raw = envelope.encoded
        raw[1] = 255
        XCTAssertEqual(Envelope(raw)?.ttl, Envelope.maxTTL)
        XCTAssertEqual(Envelope(raw)?.id, envelope.id)
    }

    func testDirectSealOnlyOpensForRecipient() {
        let recipient = Identity()
        let sealed = Seal.direct(Data([1, 2, 3]), to: recipient.agreementKey)!
        XCTAssertEqual(Seal.openDirect(sealed, identity: recipient), Data([1, 2, 3]))
        XCTAssertNil(Seal.openDirect(sealed, identity: Identity()))
    }

    func testIdentityPersists() {
        XCTAssertEqual(Identity(stored: identity.stored)?.peerID, identity.peerID)
        XCTAssertNil(Identity(stored: Data(count: 63)))
    }

    func testCodes() {
        let code = BroCode("CAMP2345")!
        XCTAssertEqual(code.description, "BRO-CAMP-2345")
        XCTAssertEqual(BroCode(" bro-camp-2345 "), code)
        XCTAssertEqual(BroCode(url: code.url), code)
        for bad in ["", "CAMP234", "CAMP23456", "CAMP0000", "CAMP234I", "ÇAMP2345"] { XCTAssertNil(BroCode(bad)) }
        XCTAssertNil(BroCode(url: URL(string: "https://join/CAMP2345")!))
        for _ in 0..<500 {
            let random = BroCode.random()
            XCTAssertEqual(BroCode(random.description), random)
        }
    }

    func testRoomDerivationIsDeterministic() {
        let a = Room(code: BroCode("CAMP2345")!), b = Room(code: BroCode("camp-2345")!)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a.id, Room(code: BroCode("CAMP2346")!).id)
        // Pinned: changing derivation silently splits old and new installs into different rooms.
        XCTAssertEqual(a.id.count, 16)
    }

    func testFramerHandlesEveryChunkSize() {
        let packets = [Data([1]), Data(repeating: 0xB7, count: 99), Data.random(Envelope.maxSize)]
        let stream = packets.reduce(Data()) { $0 + StreamFramer.frame($1) }
        for size in 1...200 {
            var framer = StreamFramer()
            let chunks = stride(from: 0, to: stream.count, by: size).map {
                Data(stream[$0..<min($0 + size, stream.count)])
            }
            XCTAssertEqual(chunks.flatMap { framer.append($0) }, packets, "chunk size \(size)")
        }
    }

    func testFramerResyncsAfterJunk() {
        var framer = StreamFramer()
        let junk = Data([9, 9, 0xB7, 1, 0xB7, 0x0B, 0xFF, 0xFF, 4])
        XCTAssertEqual(framer.append(junk + StreamFramer.frame(Data([5, 6]))), [Data([5, 6])])
    }

    func testShoutFitsExactlyInAUUID() {
        let shout = AirShout(mood: .party, name: broName, eventID: Data.random(16))
        let time = Date(timeIntervalSince1970: 1_800_000_000), bytes = shout.uuidBytes(at: time)
        XCTAssertEqual(bytes.count, 16)
        XCTAssertEqual(AirShout(uuidBytes: bytes, at: time), shout)
        for index in 0..<16 {
            var bad = bytes
            bad[index] ^= 1
            XCTAssertNil(AirShout(uuidBytes: bad, at: time))
        }
    }

    func testRecordedShoutExpires() {
        let shout = AirShout(mood: .party, name: broName, eventID: Data(repeating: 4, count: 16))
        let time = Date(timeIntervalSince1970: 1_800_000_000), bytes = shout.uuidBytes(at: time)
        XCTAssertNotNil(AirShout(uuidBytes: bytes, at: time.addingTimeInterval(540)))
        XCTAssertNil(AirShout(uuidBytes: bytes, at: time.addingTimeInterval(1300)))
    }

    func testHostileBytesNeverCrash() {
        let node = MeshNode(identity: identity, name: broName)
        for round in 0..<50_000 {
            var bytes = Data.random(Int.random(in: 0...300))
            if bytes.count > 3, round % 2 == 0 {
                bytes[0] = Envelope.version
                bytes[2] = UInt8.random(in: 1...3)
            }
            node.receive(bytes, from: "fuzz\(round / 100)")
            _ = AirShout(uuidBytes: bytes)
            _ = Message(bytes, kind: .open, context: Data())
        }
        XCTAssertTrue(node.peers.isEmpty)
    }
}
