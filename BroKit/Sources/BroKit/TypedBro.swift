import Foundation

/// The keyboard is allowed, but it only knows one word.
/// A typed bro goes over the air as "no mood", so there is still no text in the protocol.
public enum TypedBro {
    public static let word = "bro"
    static let wireValue: UInt8 = 0xFF

    /// What the field should show after an edit, or nil if that edit isn't on the way to "bro".
    public static func accept(_ input: String) -> String? {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return word.hasPrefix(cleaned) || cleaned.isEmpty ? cleaned : nil
    }

    static func byte(for mood: Mood?) -> UInt8 { mood?.rawValue ?? wireValue }

    /// The outer optional is "invalid byte", the inner one is "typed".
    static func mood(from byte: UInt8) -> Mood?? {
        if byte == wireValue { return .some(nil) }
        guard let mood = Mood(rawValue: byte) else { return nil }
        return .some(mood)
    }
}
