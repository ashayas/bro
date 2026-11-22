import BroKit
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: BroStore
    let channel: Channel
    @State private var blast: Bro?

    var body: some View {
        let bros = store.bros(in: channel)
        ZStack {
            SunsetBackground(dim: 0.38)
            VStack(spacing: 0) {
                header
                ZStack {
                    if bros.isEmpty {
                        emptyState
                    } else {
                        timeline(bros)
                    }
                    if let blast {
                        BroBlast(bro: blast) { self.blast = nil }.id(blast.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                if channel == .open && !store.state.isOpen {
                    Button("OPEN UP TO BRO HERE") { store.setOpen(true) }
                        .buttonStyle(SunsetButtonStyle())
                        .padding(16)
                        .readableWidth()
                } else {
                    BroPad { store.say($0, in: channel) }
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                if value.startLocation.x < 28 && value.translation.width > 70 { store.closeChat() }
            }
        )
        .onChange(of: store.latestBroID) { id in
            blast = store.bros(in: channel).last { $0.id == id }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: store.closeChat) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(Palette.pink)
                    .frame(width: 46, height: 46)
            }
            .accessibilityLabel("Back")
            .accessibilityIdentifier("chat-back")
            Avatar(mood: headerMood, size: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(store.title(of: channel).uppercased())
                    .font(.display(21))
                    .foregroundColor(Palette.cream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityIdentifier("chat-title")
                Text(store.subtitle(of: channel))
                    .font(.caption)
                    .foregroundColor(Palette.mint)
                    .accessibilityIdentifier("chat-subtitle")
            }
            Spacer(minLength: 0)
            if case let .direct(id) = channel {
                Menu {
                    Button(role: .destructive) { store.block(id) } label: { Label("Block this bro", systemImage: "hand.raised.fill") }
                } label: {
                    Image(systemName: "ellipsis").foregroundColor(Palette.cream).frame(width: 46, height: 46)
                }
                .accessibilityLabel("More")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(Palette.night.opacity(0.92).ignoresSafeArea(edges: .top))
    }

    private var headerMood: Mood {
        switch channel {
        case .open: return .party
        case .room: return .respect
        case let .direct(id): return store.mood(of: id)
        }
    }

    private var emptyState: some View {
        let closed = channel == .open && !store.state.isOpen
        return VStack(spacing: 6) {
            Sticker(mood: closed ? .sus : .chill, size: 150)
            Text(closed ? "YOU'RE CLOSED" : "SAY BRO").font(.display(38)).foregroundColor(Palette.cream)
            Text(closed ? "The Strip is for open bros." : "It's all you can say.").font(.callout).foregroundColor(Palette.cream)
        }
    }

    private func timeline(_ bros: [Bro]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(bros.enumerated()), id: \.element.id) { index, bro in
                        BroBubble(
                            bro: bro,
                            showsSender: showsSender(at: index, in: bros),
                            receipt: index == bros.count - 1 ? store.receipt(for: bro) : nil
                        )
                        .id(bro.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .readableWidth()
            }
            .onAppear { scrollToEnd(proxy, bros.last?.id, animated: false) }
            .onChange(of: bros.last?.id) { scrollToEnd(proxy, $0, animated: true) }
        }
    }

    private func showsSender(at index: Int, in bros: [Bro]) -> Bool {
        guard !bros[index].isMine, !channel.isDirect else { return false }
        return index == 0 || bros[index - 1].senderID != bros[index].senderID
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ id: String?, animated: Bool) {
        guard let id else { return }
        // iOS 15 ignores scrollTo until the lazy stack has laid out.
        DispatchQueue.main.async {
            if animated {
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            } else {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }
}

private struct BroBubble: View {
    @EnvironmentObject private var store: BroStore
    let bro: Bro
    let showsSender: Bool
    let receipt: String?
    @State private var plays = 0

    var body: some View {
        VStack(alignment: bro.isMine ? .trailing : .leading, spacing: 2) {
            if showsSender {
                Text(bro.name.text)
                    .font(.caption.bold())
                    .foregroundColor(Palette.cream)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.night.opacity(0.7)))
            }
            Button {
                plays += 1
                store.replay(bro)
            } label: {
                HStack(spacing: -4) {
                    if bro.isMine {
                        line
                        sticker
                    } else {
                        sticker
                        line
                    }
                }
            }
            .buttonStyle(SquishButtonStyle())
            .accessibilityLabel("\(bro.isMine ? "You" : bro.name.text), \(bro.mood.title) bro")
            .accessibilityIdentifier("bubble-\(bro.isMine ? "out" : "in")-\(bro.mood.slug)")
            .contextMenu {
                if !bro.isMine && bro.isVerified {
                    Button { store.show(.direct(bro.senderID)) } label: { Label("Bro them directly", systemImage: "paperplane.fill") }
                    Button(role: .destructive) { store.block(bro.senderID) } label: { Label("Block this bro", systemImage: "hand.raised.fill") }
                }
            }
            if !bro.isVerified {
                footnote("Heard on air · unverified")
            } else if let receipt {
                footnote(receipt).accessibilityIdentifier("receipt")
            }
        }
        .frame(maxWidth: .infinity, alignment: bro.isMine ? .trailing : .leading)
    }

    private var sticker: some View {
        PerformingSticker(mood: bro.mood, size: 112, trigger: plays).zIndex(1)
    }

    private var line: some View {
        Text(bro.mood.line)
            .font(.display(25))
            .foregroundColor(bro.mood.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Capsule().fill(bro.mood.tint))
            .rotationEffect(.degrees(bro.isMine ? -3 : 3))
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundColor(Palette.cream)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.night.opacity(0.7)))
    }
}

/// The big one that pops when a bro lands.
private struct BroBlast: View {
    let bro: Bro
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var leaving = false

    var body: some View {
        VStack(spacing: -14) {
            PerformingSticker(mood: bro.mood, size: 230, trigger: shown ? 1 : 0)
            Text(bro.mood.line)
                .font(.display(52))
                .foregroundColor(bro.mood.ink)
                .padding(.horizontal, 24)
                .padding(.vertical, 2)
                .background(Capsule().fill(bro.mood.tint))
                .rotationEffect(.degrees(-6))
        }
        .scaleEffect(reduceMotion ? 1 : (leaving ? 1.25 : shown ? 1 : 0.3))
        .opacity(shown && !leaving ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.58)) { shown = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                withAnimation(.easeIn(duration: 0.2)) { leaving = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.07, execute: done)
        }
    }
}

/// The keyboard. There is no other keyboard.
private struct BroPad: View {
    let send: (Mood) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("PICK A BRO").font(.display(15)).foregroundColor(Palette.haze)
                Spacer()
                // A wide screen always shows all sixteen.
                if sizeClass != .regular {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        Label(expanded ? "Less" : "All 16", systemImage: expanded ? "chevron.down" : "chevron.up")
                            .font(.caption.bold())
                            .foregroundColor(Palette.pink)
                            .frame(minWidth: 70, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("pad-expand")
                }
            }
            .padding(.horizontal, 14)

            if expanded || sizeClass == .regular {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: sizeClass == .regular ? 8 : 4), spacing: 4) {
                    ForEach(Mood.allCases, id: \.self, content: key)
                }
                .padding(.horizontal, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Mood.allCases, id: \.self) { key($0).frame(width: 86) }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .padding(.vertical, 5)
        .background(Palette.night.opacity(0.94).ignoresSafeArea(edges: .bottom))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private func key(_ mood: Mood) -> some View {
        Button {
            send(mood)
        } label: {
            VStack(spacing: -3) {
                Sticker(mood: mood, size: 70)
                Text(mood.title.uppercased())
                    .font(.display(12))
                    .foregroundColor(mood.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SquishButtonStyle())
        .accessibilityLabel("\(mood.title) bro")
        .accessibilityIdentifier("send-\(mood.slug)")
    }
}
