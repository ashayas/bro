import BroKit
import SwiftUI

struct Sticker: View {
    let mood: Mood
    var size: CGFloat = 96

    var body: some View {
        Image(mood.asset)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct Avatar: View {
    let mood: Mood
    var size: CGFloat = 52

    var body: some View {
        Sticker(mood: mood, size: size * 0.98)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [mood.tint.opacity(0.75), Palette.violet.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(mood.tint, lineWidth: 2))
    }
}

/// A sticker that acts out its mood each time `trigger` changes.
struct PerformingSticker: View {
    let mood: Mood
    var size: CGFloat
    var trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        Sticker(mood: mood, size: size)
            .modifier(Performance(mood: mood, progress: progress))
            .onChange(of: trigger) { _ in perform() }
            .onAppear { if trigger > 0 { perform() } }
    }

    private func perform() {
        guard !reduceMotion else { return }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { progress = 0 }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: 0.85)) { progress = 1 }
        }
    }
}

private struct Performance: AnimatableModifier {
    let mood: Mood
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let envelope = sin(progress * .pi)
        let wave = sin(progress * .pi * 10) * envelope
        var x: CGFloat = 0, y: CGFloat = 0, angle: CGFloat = 0, scale: CGFloat = 1

        switch mood {
        case .angry, .shocked, .sos:
            x = wave * 9
            scale += envelope * 0.12
        case .party, .happy, .laughing:
            y = -abs(wave) * 16
            angle = wave * 9
        case .hype, .flex:
            scale += envelope * 0.22 + abs(wave) * 0.08
        case .love:
            scale += abs(wave) * 0.16
        case .chill, .sus, .confused:
            angle = sin(progress * .pi * 3) * envelope * 12
        case .respect:
            y = -envelope * 10
            scale += envelope * 0.08
        case .entrance, .checkout:
            // Lunges the way it's pointing.
            x = abs(wave) * 14
            scale += envelope * 0.1
        case .sad, .sleepy, .wrecked:
            y = envelope * 8
            angle = -envelope * 14
        }
        return content
            .scaleEffect(scale)
            .rotationEffect(.degrees(Double(angle)))
            .offset(x: x, y: y)
    }
}
