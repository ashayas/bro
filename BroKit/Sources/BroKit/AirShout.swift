import CryptoKit
import Foundation

/// A whole open-channel bro packed into one advertised 128-bit service UUID.
/// No connection, so any number of phones in range can hear it.
///
///     B7 0B 01 | mood | name (2) | event ID prefix (8) | checksum (2)
///
/// There is no room for a signature, so the UI labels these "heard on air"
/// until the signed copy arrives over the mesh. Only open bros are shouted.
public struct AirShout: Equatable {
    private static let header = Data([0xB7, 0x0B, 0x01])

    public let mood: Mood
    public let name: BroName
    public let token: Data

    init(mood: Mood, name: BroName, eventID: Data) {
        self.mood = mood
        self.name = name
        token = Data(eventID.prefix(8))
    }

    var uuidBytes: Data {
        let content = Self.header + Data([mood.rawValue, name.first, name.last]) + token
        return content + Data.digest(content).prefix(2)
    }

    init?(uuidBytes: Data) {
        guard uuidBytes.count == 16 else { return nil }
        var reader = ByteReader(uuidBytes)
        guard reader.data(3) == Self.header,
              let mood = reader.byte().flatMap(Mood.init(rawValue:)),
              let first = reader.byte(), let last = reader.byte(),
              let name = BroName(first: first, last: last),
              let token = reader.data(8), let checksum = reader.data(2),
              checksum == Data.digest(Data(uuidBytes.prefix(14))).prefix(2)
        else { return nil }
        self.mood = mood
        self.name = name
        self.token = token
    }
}
