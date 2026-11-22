import BroKit
import SwiftUI

enum Palette {
    static let night = Color(red: 0.075, green: 0.020, blue: 0.150)
    static let plum = Color(red: 0.185, green: 0.065, blue: 0.305)
    static let violet = Color(red: 0.47, green: 0.22, blue: 0.86)
    static let lilac = Color(red: 0.76, green: 0.62, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.24, blue: 0.62)
    static let orange = Color(red: 1.0, green: 0.55, blue: 0.27)
    static let gold = Color(red: 1.0, green: 0.82, blue: 0.40)
    static let mint = Color(red: 0.36, green: 0.96, blue: 0.83)
    static let cream = Color(red: 1.0, green: 0.94, blue: 0.96)
    static let haze = Color(red: 0.80, green: 0.70, blue: 0.90)

    static let sunset = LinearGradient(colors: [pink, orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let heat = LinearGradient(colors: [gold, orange, pink], startPoint: .top, endPoint: .bottom)
}

extension Font {
    static func display(_ size: CGFloat) -> Font { .custom("Anton-Regular", size: size, relativeTo: .title) }
    static func script(_ size: CGFloat) -> Font { .custom("Yellowtail-Regular", size: size, relativeTo: .largeTitle) }
}

extension Mood {
    var asset: String { "bro-\(slug)" }

    var tint: Color {
        switch self {
        case .angry, .sos: return Color(red: 1, green: 0.30, blue: 0.30)
        case .party, .love, .shocked: return Palette.pink
        case .hype, .laughing, .happy: return Palette.orange
        case .chill, .sus, .checkout: return Palette.mint
        case .flex, .respect, .entrance: return Palette.gold
        case .confused, .sad, .sleepy, .wrecked: return Palette.violet
        }
    }

    /// `tint`, lifted until it reads as small text on night.
    var label: Color {
        switch self {
        case .confused, .sad, .sleepy, .wrecked: return Palette.lilac
        default: return tint
        }
    }

    /// Dark text on light tints, white on dark ones.
    var ink: Color {
        switch self {
        case .confused, .sad, .sleepy, .wrecked: return .white
        default: return Palette.night
        }
    }
}

struct SunsetBackground: View {
    var dim = 0.55

    var body: some View {
        // Overlay, so the picture's aspect ratio can't widen the layout.
        Palette.night
            .overlay(Image(decorative: "scene-strip").resizable().scaledToFill())
            .overlay(Palette.night.opacity(dim))
            .overlay(LinearGradient(colors: [.clear, Palette.night.opacity(0.9)], startPoint: .center, endPoint: .bottom))
            .clipped()
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

struct Wordmark: View {
    var size: CGFloat = 64

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.08) {
            Text("Bro")
                .font(.custom("Yellowtail-Regular", fixedSize: size * 1.25))
                .foregroundColor(.white)
                .shadow(color: Palette.pink, radius: size * 0.06)
                .shadow(color: Palette.pink.opacity(0.8), radius: size * 0.18)
            Text("CHAT")
                .font(.custom("Anton-Regular", fixedSize: size))
                .foregroundColor(.clear)
                .overlay(Palette.heat.mask(Text("CHAT").font(.custom("Anton-Regular", fixedSize: size))))
                .shadow(color: Palette.night.opacity(0.85), radius: 0, x: size * 0.04, y: size * 0.05)
        }
        .rotationEffect(.degrees(-4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bro Chat")
    }
}

struct Panel: ViewModifier {
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .background(Palette.plum.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(highlighted ? Palette.pink : Color.white.opacity(0.12), lineWidth: highlighted ? 2 : 1)
            )
    }
}

extension View {
    func panel(highlighted: Bool = false) -> some View { modifier(Panel(highlighted: highlighted)) }

    /// Keeps phone layouts from stretching across an iPad.
    func readableWidth() -> some View {
        frame(maxWidth: 620).frame(maxWidth: .infinity)
    }
}

struct SunsetButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.display(24))
            .foregroundColor(isEnabled ? Palette.night : Palette.haze)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Palette.sunset.opacity(isEnabled ? 1 : 0))
            .background(Palette.plum)
            .clipShape(Capsule())
            .shadow(color: Palette.pink.opacity(isEnabled ? 0.55 : 0), radius: 14, y: 4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct SquishButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.display(21))
            .foregroundColor(Palette.cream)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
