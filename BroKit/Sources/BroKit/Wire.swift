import CryptoKit
import Foundation

// Envelope (what relays see):  version, ttl, kind, payload
// Message (signed):            signing key, agreement key, time, nonce, name, body, signature
//
// open    payload = message
// room    payload = AES-GCM(room key, message)
// direct  payload = ephemeral key, AES-GCM(shared key, message)
//
// The signature covers kind and context, so a message can't be replayed into another channel.

enum PacketKind: UInt8 {
    case open = 1, room, direct
}

struct Envelope {
    static let version: UInt8 = 1
    static let maxTTL: UInt8 = 4
    static let maxSize = 512

    var ttl: UInt8
    let kind: PacketKind
    let payload: Data
    /// Derived from content, so a forged ID can't suppress someone else's packet.
    let id: Data

    init(kind: PacketKind, payload: Data, ttl: UInt8 = Envelope.maxTTL) {
        self.kind = kind
        self.payload = payload
        self.ttl = ttl
        id = Data.digest(Data([kind.rawValue]), payload).prefix(16)
    }

    init?(_ data: Data) {
        guard data.count <= Self.maxSize, data.count > 3 else { return nil }
        let header = Array(data.prefix(3))
        guard header[0] == Self.version, let kind = PacketKind(rawValue: header[2]) else { return nil }
        self.init(kind: kind, payload: Data(data.dropFirst(3)), ttl: min(header[1], Self.maxTTL))
    }

    var encoded: Data { Data([Self.version, ttl, kind.rawValue]) + payload }
}

enum Body: Equatable {
    case presence(mood: Mood, isHost: Bool)
    case bro(Mood)
    case ack(Data)
    case goodbye

    var encoded: Data {
        switch self {
        case let .presence(mood, isHost): return Data([1, mood.rawValue, isHost ? 1 : 0])
        case let .bro(mood): return Data([2, mood.rawValue])
        case let .ack(id): return Data([3]) + id
        case .goodbye: return Data([4])
        }
    }

    /// Fixed sizes only. There is nowhere to hide a string.
    init?(_ reader: inout ByteReader) {
        switch reader.byte() {
        case 1:
            guard let mood = reader.byte().flatMap(Mood.init(rawValue:)),
                  let flag = reader.byte(), flag <= 1 else { return nil }
            self = .presence(mood: mood, isHost: flag == 1)
        case 2:
            guard let mood = reader.byte().flatMap(Mood.init(rawValue:)) else { return nil }
            self = .bro(mood)
        case 3:
            guard let id = reader.data(16) else { return nil }
            self = .ack(id)
        case 4:
            self = .goodbye
        default:
            return nil
        }
    }
}

struct Message {
    private static let signatureSize = 64

    let eventID: Data
    let senderID: String
    let agreementKey: Data
    let milliseconds: UInt64
    let name: BroName
    let body: Body
    let signed: Data

    private static func transcript(_ kind: PacketKind, _ context: Data, _ content: Data) -> Data {
        Data("brochat.message.v1".utf8) + Data([kind.rawValue, UInt8(context.count)]) + context + content
    }

    static func create(
        body: Body, name: BroName, identity: Identity, kind: PacketKind, context: Data, date: Date
    ) -> Message? {
        var content = identity.signing.publicKey.rawRepresentation + identity.agreementKey
        content.appendBigEndian(UInt64(max(0, date.timeIntervalSince1970) * 1000))
        content.append(Data.random(8))
        content.append(contentsOf: [name.first, name.last])
        content.append(body.encoded)
        guard let signature = try? identity.signing.signature(for: transcript(kind, context, content)) else {
            return nil
        }
        return Message(content + signature, kind: kind, context: context)
    }

    init?(_ data: Data, kind: PacketKind, context: Data) {
        guard data.count > Self.signatureSize else { return nil }
        let content = Data(data.prefix(data.count - Self.signatureSize))
        var reader = ByteReader(content)
        guard let signingKey = reader.data(32), let agreementKey = reader.data(32),
              let milliseconds = reader.uint64(), reader.data(8) != nil,
              let first = reader.byte(), let last = reader.byte(),
              let name = BroName(first: first, last: last),
              let body = Body(&reader), reader.isAtEnd,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: signingKey)
        else { return nil }

        let transcript = Self.transcript(kind, context, content)
        guard publicKey.isValidSignature(data.suffix(Self.signatureSize), for: transcript) else { return nil }

        eventID = Data.digest(transcript).prefix(16)
        senderID = Identity.peerID(signingKey: signingKey, agreementKey: agreementKey)
        self.agreementKey = agreementKey
        self.milliseconds = milliseconds
        self.name = name
        self.body = body
        signed = data
    }
}

enum Seal {
    private static let roomLabel = Data("brochat.room.seal.v1".utf8)
    private static let directLabel = Data("brochat.direct.seal.v1".utf8)

    static func room(_ plain: Data, key: SymmetricKey) -> Data? {
        try? AES.GCM.seal(plain, using: key, authenticating: roomLabel).combined
    }

    static func openRoom(_ sealed: Data, key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: roomLabel)
    }

    static func direct(_ plain: Data, to recipient: Data) -> Data? {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let header = ephemeral.publicKey.rawRepresentation
        guard let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient),
              let secret = try? ephemeral.sharedSecretFromKeyAgreement(with: publicKey),
              let box = try? AES.GCM.seal(plain, using: directKey(secret, header: header), authenticating: header),
              let combined = box.combined
        else { return nil }
        return header + combined
    }

    static func openDirect(_ sealed: Data, identity: Identity) -> Data? {
        var reader = ByteReader(sealed)
        guard sealed.count > 32, let header = reader.data(32), let body = reader.data(sealed.count - 32),
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: header),
              let secret = try? identity.agreement.sharedSecretFromKeyAgreement(with: publicKey),
              let box = try? AES.GCM.SealedBox(combined: body)
        else { return nil }
        return try? AES.GCM.open(box, using: directKey(secret, header: header), authenticating: header)
    }

    private static func directKey(_ secret: SharedSecret, header: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: header, sharedInfo: directLabel, outputByteCount: 32
        )
    }
}
