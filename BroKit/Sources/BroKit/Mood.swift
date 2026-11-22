import Foundation

/// The entire vocabulary of Bro Chat.
/// Raw values go over the air: append new moods, never renumber.
public enum Mood: UInt8, CaseIterable, Codable, Hashable {
    case happy = 0, angry, party, chill, hype, laughing, love, flex
    case respect, sus, shocked, confused, sad, sleepy, wrecked, sos
    case entrance, checkout

    private var info: (slug: String, title: String, line: String, emoji: String) {
        switch self {
        case .happy: return ("happy", "Happy", "bro!", "😁")
        case .angry: return ("angry", "Angry", "BRO!!!", "😡")
        case .party: return ("party", "Party", "brooo!", "🥳")
        case .chill: return ("chill", "Chill", "bro.", "🤙")
        case .hype: return ("hype", "Hype", "BROOOO", "🔥")
        case .laughing: return ("laughing", "Dead", "bro-ho-ho", "😂")
        case .love: return ("love", "Love", "bro <3", "😍")
        case .flex: return ("flex", "Flex", "BRO.", "💪")
        case .respect: return ("respect", "Respect", "bro o7", "🫡")
        case .sus: return ("sus", "Sus", "bro…?", "🤨")
        case .shocked: return ("shocked", "Shook", "BRO?!", "😱")
        case .confused: return ("confused", "Huh", "bro??", "🤷")
        case .sad: return ("sad", "Sad", "bro…", "😭")
        case .sleepy: return ("sleepy", "Sleepy", "brozzz", "😴")
        case .wrecked: return ("wrecked", "Wrecked", "brughh", "🤢")
        case .sos: return ("sos", "Where u at", "bro?!?!", "🔦")
        case .entrance: return ("entrance", "Entrance", "bro, go to entrance", "🚪")
        case .checkout: return ("checkout", "Checkout", "bro, go to checkout", "🛒")
        }
    }

    public var slug: String { info.slug }
    public var title: String { info.title }
    /// Directions tell a bro where to go, so they don't work as someone's face.
    public var isDirection: Bool { self == .entrance || self == .checkout }
    public static var faces: [Mood] { allCases.filter { !$0.isDirection } }

    /// Every line starts with bro. That is the rule.
    public var line: String { info.line }
    public var emoji: String { info.emoji }

    public init?(slug: String) {
        guard let match = Mood.allCases.first(where: { $0.slug == slug }) else { return nil }
        self = match
    }
}
