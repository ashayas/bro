import BroKit
import SwiftUI
import UIKit

struct NearbyView: View {
    @EnvironmentObject private var store: BroStore

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Wordmark(size: 44).padding(.top, 4)
                OpenSwitch()
                RadioWarning()
                RadarView()
                stripCard
                if !store.peers.isEmpty {
                    SectionTitle("In range")
                    ForEach(store.peers) { peer in
                        PersonRow(
                            id: peer.id, title: peer.name.text, mood: peer.mood,
                            detail: peer.isOpen ? "Open to bros" : "In your crew",
                            unread: store.state.unread[.direct(peer.id)] ?? 0
                        )
                    }
                }
                let away = store.directThreads.filter { thread in
                    guard case let .direct(id) = thread.channel else { return false }
                    return store.peer(id) == nil
                }
                if !away.isEmpty {
                    SectionTitle("Out of range")
                    ForEach(away) { thread in
                        if case let .direct(id) = thread.channel {
                            PersonRow(
                                id: id, title: store.name(of: id), mood: store.mood(of: id),
                                detail: thread.mood.line, unread: store.state.unread[thread.channel] ?? 0
                            )
                        }
                    }
                }
            }
            .padding(16)
            .readableWidth()
        }
    }

    private var stripCard: some View {
        Button {
            store.show(.open)
        } label: {
            HStack(spacing: 12) {
                Sticker(mood: store.lastBro(in: .open)?.mood ?? .party, size: 70)
                VStack(alignment: .leading, spacing: 0) {
                    Text("The Strip").font(.script(34)).foregroundColor(.white).shadow(color: Palette.pink, radius: 6)
                    Text(stripDetail)
                        .font(.footnote)
                        .foregroundColor(Palette.cream)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                UnreadBadge(count: store.state.unread[.open] ?? 0)
                Image(systemName: "chevron.right").foregroundColor(Palette.pink)
            }
            .padding(12)
            .panel(highlighted: true)
        }
        .buttonStyle(SquishButtonStyle())
        .accessibilityIdentifier("open-strip")
    }

    private var stripDetail: String {
        guard store.state.isOpen else { return "You're closed. Open up to hear the Strip." }
        guard let last = store.lastBro(in: .open) else { return "Bro at everyone open around you." }
        return "\(last.isMine ? "You" : last.name.text): \(last.mood.line)"
    }
}

private struct OpenSwitch: View {
    @EnvironmentObject private var store: BroStore

    var body: some View {
        Toggle(isOn: Binding(get: { store.state.isOpen }, set: store.setOpen)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(store.state.isOpen ? "OPEN TO BROS" : "CODE ONLY")
                    .font(.display(21))
                    .foregroundColor(store.state.isOpen ? Palette.mint : Palette.gold)
                Text(store.state.isOpen ? "Anyone nearby can bro you" : "Only bros with a shared code")
                    .font(.caption)
                    .foregroundColor(Palette.haze)
            }
        }
        .tint(Palette.pink)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .panel()
        .accessibilityIdentifier("open-switch")
    }
}

private struct RadioWarning: View {
    @EnvironmentObject private var store: BroStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let problem {
            Button {
                if problem.fixInSettings, let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                HStack(spacing: 10) {
                    Sticker(mood: .sad, size: 46)
                    Text(problem.text)
                        .font(.footnote.bold())
                        .foregroundColor(Palette.cream)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .panel()
            }
            .buttonStyle(SquishButtonStyle())
        }
    }

    private var problem: (text: String, fixInSettings: Bool)? {
        let settings = store.state.settings
        if !settings.bluetooth && !settings.wifi {
            return ("Both radios are off. Turn one on under Me.", false)
        }
        if settings.bluetooth {
            switch store.bluetoothStatus {
            case .denied: return ("Bluetooth permission is off. Tap to fix it in Settings.", true)
            case .poweredOff: return ("Bluetooth is off. Turn it on for off-grid bros.", false)
            case .failed: return ("Bluetooth had a moment. Toggle it under Me.", false)
            default: break
            }
        }
        if settings.wifi, store.wifiStatus == .denied {
            return ("Local network permission is off. Tap to fix it in Settings.", true)
        }
        return nil
    }
}

private struct RadarView: View {
    private struct Slot {
        let angle: Double
        let distance: CGFloat
    }

    // Positions are decorative: we don't measure where anyone is.
    private static let slots = [
        Slot(angle: -60, distance: 0.75), Slot(angle: 140, distance: 0.75), Slot(angle: 30, distance: 0.8),
        Slot(angle: 220, distance: 0.82), Slot(angle: 85, distance: 0.72), Slot(angle: -105, distance: 0.8),
        Slot(angle: 182, distance: 0.8), Slot(angle: -15, distance: 0.85),
    ]

    @EnvironmentObject private var store: BroStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle().fill(Palette.night.opacity(0.58)).frame(width: side, height: side)
                ForEach(1..<4, id: \.self) { ring in
                    Circle()
                        .strokeBorder(Palette.pink.opacity(0.35), lineWidth: 1.5)
                        .frame(width: side * CGFloat(ring) / 3, height: side * CGFloat(ring) / 3)
                }
                Circle()
                    .fill(AngularGradient(colors: [.clear, .clear, .clear, Palette.pink.opacity(0.45)], center: .center))
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(sweeping ? 360 : 0))
                    .animation(sweeping ? .linear(duration: 3.5).repeatForever(autoreverses: false) : .default, value: sweeping)
                Avatar(mood: store.state.mood, size: side * 0.28).accessibilityHidden(true)
                ForEach(Array(store.peers.prefix(Self.slots.count).enumerated()), id: \.element.id) { index, peer in
                    let slot = Self.slots[index]
                    let radians = slot.angle * .pi / 180
                    Button {
                        store.show(.direct(peer.id))
                    } label: {
                        Avatar(mood: peer.mood, size: max(44, side * 0.18))
                    }
                    .buttonStyle(SquishButtonStyle())
                    .offset(
                        x: CGFloat(cos(radians)) * side / 2 * slot.distance,
                        y: CGFloat(sin(radians)) * side / 2 * slot.distance
                    )
                    .accessibilityLabel("Bro \(peer.name.text)")
                }
                Text(status)
                    .font(.display(15))
                    .foregroundColor(Palette.cream)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Palette.night.opacity(0.85)))
                    .offset(y: side * 0.47)
                    .accessibilityIdentifier("radar-status")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 256)
        .padding(.bottom, 8)
        .onAppear {
            guard !reduceMotion else { return }
            // Next tick, or the repeat animation captures the initial layout too.
            DispatchQueue.main.async { sweeping = true }
        }
    }

    private var status: String {
        switch store.peers.count {
        case 0: return "LOOKING FOR BROS…"
        case 1: return "1 BRO IN RANGE"
        default: return "\(store.peers.count) BROS IN RANGE"
        }
    }
}

private struct PersonRow: View {
    @EnvironmentObject private var store: BroStore
    let id: String
    let title: String
    let mood: Mood
    let detail: String
    let unread: Int

    var body: some View {
        Button {
            store.show(.direct(id))
        } label: {
            HStack(spacing: 12) {
                Avatar(mood: mood)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundColor(Palette.cream)
                    Text(detail).font(.caption).foregroundColor(Palette.haze)
                }
                Spacer(minLength: 0)
                UnreadBadge(count: unread)
                Text("BRO").font(.display(16)).foregroundColor(Palette.pink)
            }
            .padding(10)
            .panel()
        }
        .buttonStyle(SquishButtonStyle())
        .accessibilityIdentifier("person-\(title)")
        .contextMenu {
            Button(role: .destructive) { store.block(id) } label: { Label("Block this bro", systemImage: "hand.raised.fill") }
        }
    }
}

struct UnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(min(count, 99))")
                .font(.caption.bold())
                .foregroundColor(Palette.night)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Palette.mint))
                .accessibilityLabel("\(count) unread")
        }
    }
}
