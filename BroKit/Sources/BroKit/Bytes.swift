import CryptoKit
import Foundation

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let characters = Array(hex)
        guard characters.count % 2 == 0 else { return nil }
        var out = Data(capacity: characters.count / 2)
        for start in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[start...start + 1]), radix: 16) else { return nil }
            out.append(byte)
        }
        self = out
    }

    static func random(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func digest(_ parts: Data...) -> Data {
        var hash = SHA256()
        parts.forEach { hash.update(data: $0) }
        return Data(hash.finalize())
    }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = Array(data) }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func byte() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func data(_ count: Int) -> Data? {
        guard count >= 0, count <= bytes.count - offset else { return nil }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    mutating func uint64() -> UInt64? {
        data(8)?.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

/// A set that forgets its oldest entries.
struct RecentSet<Element: Hashable> {
    private var members = Set<Element>()
    private var order: [Element] = []
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    func contains(_ element: Element) -> Bool { members.contains(element) }

    /// Returns false if the element was already present.
    @discardableResult
    mutating func insert(_ element: Element) -> Bool {
        guard members.insert(element).inserted else { return false }
        order.append(element)
        if order.count >= capacity * 2 {
            let dropped = order.prefix(order.count - capacity)
            members.subtract(dropped)
            order.removeFirst(dropped.count)
        }
        return true
    }
}

struct TokenBucket {
    let rate: Double
    let burst: Double
    private var tokens: Double
    private var updated: Date?

    init(rate: Double, burst: Double) {
        self.rate = rate
        self.burst = burst
        tokens = burst
    }

    mutating func take(at now: Date) -> Bool {
        if let updated {
            tokens = min(burst, tokens + max(0, now.timeIntervalSince(updated)) * rate)
        }
        updated = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
