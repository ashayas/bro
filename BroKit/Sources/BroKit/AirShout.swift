import CryptoKit
import Foundation

/// A whole open-channel bro packed into one advertised 128-bit service UUID.
/// No connection, so any number of phones in range can hear it.
///
///     B7 0B 01 | mood | name (2) | event ID prefix (8) | checksum (2)
///
/// The checksum covers a ten-minute time window, so a recorded shout can't be replayed later.
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

    private static let window: TimeInterval = 600

    private static func checksum(_ content: Data, window: Int64) -> Data {
        var input = content
        input.appendBigEndian(window)
        return Data.digest(input).prefix(2)
    }

    private static func window(at date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 / window)
    }

    func uuidBytes(at date: Date = Date()) -> Data {
        let content = Self.header + Data([mood.rawValue, name.first, name.last]) + token
        return content + Self.checksum(content, window: Self.window(at: date))
    }

    init?(uuidBytes: Data, at date: Date = Date()) {
        guard uuidBytes.count == 16 else { return nil }
        var reader = ByteReader(uuidBytes)
        guard reader.data(3) == Self.header,
              let mood = reader.byte().flatMap(Mood.init(rawValue:)),
              let first = reader.byte(), let last = reader.byte(),
              let name = BroName(first: first, last: last),
              let token = reader.data(8), let checksum = reader.data(2),
              case let current = Self.window(at: date), case let content = Data(uuidBytes.prefix(14)),
              (current - 1...current + 1).contains(where: { Self.checksum(content, window: $0) == checksum })
        else { return nil }
        self.mood = mood
        self.name = name
        self.token = token
    }
}
