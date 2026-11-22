import CryptoKit
import Foundation

/// A device identity: no account, phone number or server.
public struct Identity {
    let signing: Curve25519.Signing.PrivateKey
    let agreement: Curve25519.KeyAgreement.PrivateKey

    public init() {
        signing = .init()
        agreement = .init()
    }

    public init?(stored: Data) {
        var reader = ByteReader(stored)
        guard let first = reader.data(32), let second = reader.data(32), reader.isAtEnd,
              let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: first),
              let agreement = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: second)
        else { return nil }
        self.signing = signing
        self.agreement = agreement
    }

    public var stored: Data { signing.rawRepresentation + agreement.rawRepresentation }
    public var agreementKey: Data { agreement.publicKey.rawRepresentation }
    public var peerID: String {
        Self.peerID(signingKey: signing.publicKey.rawRepresentation, agreementKey: agreementKey)
    }

    /// The ID covers both keys, so nobody can pair their encryption key with your signature.
    static func peerID(signingKey: Data, agreementKey: Data) -> String {
        Data.digest(signingKey, agreementKey).prefix(10).hex
    }
}
