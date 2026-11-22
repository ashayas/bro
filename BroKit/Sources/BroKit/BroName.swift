import Foundation

/// Names are two indices, so there is no free-text field anywhere on the wire.
/// That is what makes "you can only say bro" true, rather than a UI suggestion.
public struct BroName: Codable, Hashable {
    public static let firsts = [
        "Turbo", "Salty", "Sunburnt", "Neon", "Chill", "Big", "Lil", "Captain",
        "Midnight", "Gator", "Flamingo", "Coconut", "Disco", "Golden", "Sandy", "Wavy",
        "Tropical", "Swamp", "Jetski", "Sunset", "Lucky", "Crispy", "Smooth", "Feral",
        "Mango", "Pelican", "Doctor", "Professor", "Uncle", "Barefoot", "Electric", "Humid",
    ]
    public static let lasts = [
        "Kyle", "Brad", "Chad", "Tanner", "Brody", "Trey", "Hunter", "Dale",
        "Tony", "Rico", "Marco", "Duke", "Ace", "Gus", "Nico", "Zane",
        "Biscuit", "Tank", "Moose", "Shrimp", "Noodle", "Keith", "Randy", "Skip",
        "Jules", "Sunny", "Kiki", "Roxy", "Deej", "Pickle", "Maverick", "Steve",
    ]

    public let first: UInt8
    public let last: UInt8

    public init?(first: UInt8, last: UInt8) {
        guard first < Self.firsts.count, last < Self.lasts.count else { return nil }
        self.first = first
        self.last = last
    }

    public static func random() -> BroName {
        BroName(first: .random(in: 0..<UInt8(firsts.count)), last: .random(in: 0..<UInt8(lasts.count)))!
    }

    public var text: String { "\(Self.firsts[Int(first)]) \(Self.lasts[Int(last)])" }
}
