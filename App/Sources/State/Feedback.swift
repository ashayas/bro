import AVFoundation
import BroKit
import UIKit

/// Sounds, haptics, and a voice that says "bro" a different way for each mood. Works offline.
final class Feedback {
    var settings = Settings()

    private let speech = AVSpeechSynthesizer()
    private var players: [String: AVAudioPlayer] = [:]
    private var sessionReady = false
    private lazy var voice = Self.pickVoice()

    func sent(_ mood: Mood) {
        play("send")
        speak(mood)
        buzz(mood)
    }

    func received(_ mood: Mood) {
        play("receive")
        speak(mood)
        buzz(mood)
    }

    func replay(_ mood: Mood) {
        speak(mood)
        buzz(mood)
    }

    func joined() {
        play("join")
        if settings.haptics { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }

    func tap() {
        if settings.haptics { UISelectionFeedbackGenerator().selectionChanged() }
    }

    private func prepareSession() {
        guard !sessionReady else { return }
        sessionReady = true
        // Ambient: respects the silent switch and doesn't stop your music.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        speech.usesApplicationAudioSession = true
    }

    private func play(_ name: String) {
        guard settings.effects else { return }
        prepareSession()
        if players[name] == nil, let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            players[name] = try? AVAudioPlayer(contentsOf: url)
        }
        players[name]?.currentTime = 0
        players[name]?.play()
    }

    private func speak(_ mood: Mood) {
        guard settings.voice, !UIAccessibility.isVoiceOverRunning else { return }
        prepareSession()
        speech.stopSpeaking(at: .immediate)
        let delivery = mood.delivery
        let utterance = AVSpeechUtterance(string: delivery.text)
        utterance.voice = voice
        utterance.pitchMultiplier = delivery.pitch
        utterance.rate = delivery.rate
        utterance.volume = delivery.volume
        utterance.preUtteranceDelay = 0.08
        speech.speak(utterance)
    }

    private func buzz(_ mood: Mood) {
        guard settings.haptics else { return }
        switch mood {
        case .angry, .sos, .shocked:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .party, .hype, .laughing:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .flex, .respect:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .sleepy, .chill, .sad:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        default:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private static func pickVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == "en-US" && $0.gender == .male
                // The novelty voices (bells, robots) also report a gender.
                && !$0.identifier.contains("speech.synthesis") && !$0.identifier.contains("eloquence")
        }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

private extension Mood {
    var delivery: (text: String, pitch: Float, rate: Float, volume: Float) {
        switch self {
        case .happy: return ("Bro!", 1.3, 0.48, 1)
        case .angry: return ("Bro!", 0.6, 0.62, 1)
        case .party: return ("Bro!", 1.6, 0.38, 1)
        case .chill: return ("Bro.", 0.85, 0.3, 0.8)
        case .hype: return ("Bro!", 1.75, 0.2, 1)
        case .laughing: return ("Bro, ho, ho!", 1.5, 0.58, 1)
        case .love: return ("Bro.", 1.2, 0.22, 0.8)
        case .flex: return ("Bro.", 0.5, 0.36, 1)
        case .respect: return ("Bro.", 0.75, 0.45, 1)
        case .sus: return ("Bro?", 0.9, 0.18, 0.9)
        case .shocked: return ("Bro?!", 1.95, 0.55, 1)
        case .confused: return ("Bro?", 1.4, 0.36, 0.9)
        case .sad: return ("Bro.", 1.1, 0.12, 0.7)
        case .sleepy: return ("Bro.", 0.55, 0.1, 0.5)
        case .wrecked: return ("Bro.", 0.5, 0.15, 0.7)
        case .sos: return ("Bro? Bro?", 1.65, 0.5, 1)
        }
    }
}
