import CommonCrypto
import CryptoKit
import Foundation

/// `BRO-XXXX-XXXX`: 40 bits from an alphabet without lookalike characters.
public struct BroCode: Hashable, Codable, CustomStringConvertible {
    public static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    public static let length = 8

    public let raw: String

    public init?(_ input: String) {
        var cleaned = input.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if cleaned.count == Self.length + 3, cleaned.hasPrefix("BRO") { cleaned.removeFirst(3) }
        guard cleaned.count == Self.length, cleaned.allSatisfy(Self.alphabet.contains) else { return nil }
        raw = cleaned
    }

    public static func random() -> BroCode {
        var generator = SystemRandomNumberGenerator()
        return BroCode(String((0..<length).map { _ in alphabet.randomElement(using: &generator)! }))!
    }

    public var description: String { "BRO-\(raw.prefix(4))-\(raw.suffix(4))" }
    public var url: URL { URL(string: "brochat://join/\(raw)")! }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "brochat", url.host?.lowercased() == "join" else { return nil }
        self.init(url.lastPathComponent)
    }
}

/// Everyone holding the same code derives the same room. The code is never transmitted.
public struct Room: Codable, Hashable, Identifiable {
    public let code: BroCode
    public let id: String
    let key: Data

    /// Deliberately slow, so recorded traffic can't cheaply be used to guess codes.
    public init(code: BroCode) {
        var derived = [UInt8](repeating: 0, count: 40)
        let count = derived.count
        let salt = Array("brochat.room.v1".utf8)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), code.raw, code.raw.utf8.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 120_000,
            &derived, count
        )
        precondition(status == kCCSuccess, "PBKDF2 rejected constant parameters")
        self.code = code
        key = Data(derived[0..<32])
        id = Data(derived[32..<40]).hex
    }

    var symmetricKey: SymmetricKey { SymmetricKey(data: key) }
    var context: Data { Data(hex: id) ?? Data() }
}
