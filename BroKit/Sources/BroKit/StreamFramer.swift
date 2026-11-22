import Foundation

/// Turns a byte stream (TCP, or chunked GATT writes) back into packets.
/// The magic lets it resync if Bluetooth state restoration drops us mid-packet.
struct StreamFramer {
    private static let magic: [UInt8] = [0xB7, 0x0B]
    private var buffer: [UInt8] = []

    static func frame(_ packet: Data) -> Data {
        var out = Data(magic)
        out.appendBigEndian(UInt16(packet.count))
        out.append(packet)
        return out
    }

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(contentsOf: data)
        var packets: [Data] = []
        var start = 0
        while buffer.count - start >= 4 {
            let length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard buffer[start] == Self.magic[0], buffer[start + 1] == Self.magic[1],
                  length > 0, length <= Envelope.maxSize
            else {
                start += 1
                continue
            }
            let end = start + 4 + length
            guard end <= buffer.count else { break }
            packets.append(Data(buffer[start + 4..<end]))
            start = end
        }
        buffer.removeFirst(start)
        return packets
    }
}
