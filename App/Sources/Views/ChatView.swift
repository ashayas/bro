import BroKit
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: BroStore
    let channel: Channel
    @State private var blast: Bro?
    @State private var typing = false

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
                    if let blast, let mood = blast.mood {
                        BroBlast(mood: mood) { self.blast = nil }.id(blast.id)
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
                    BroPad(typing: $typing, send: { store.say($0, in: channel) }, rejected: store.rejectTyping)
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                if value.startLocation.x < 28 && value.translation.width > 70 {
                    typing = false
                    store.closeChat()
                }
            }
        )
        .onChange(of: store.latestBroID) { id in
            // Typed bros have no sticker to blow up.
            blast = store.bros(in: channel).last { $0.id == id && $0.mood != nil }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                typing = false
                store.closeChat()
            } label: {
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
            Sticker(mood: closed ? .sus : .chill, size: typing ? 80 : 150)
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
            .onChange(of: typing) { isTyping in
                guard isTyping else { return }
                // After the keyboard has finished resizing us.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    scrollToEnd(proxy, bros.last?.id, animated: true)
                }
            }
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
                if let mood = bro.mood {
                    HStack(spacing: -4) {
                        if bro.isMine {
                            line(mood)
                            sticker(mood)
                        } else {
                            sticker(mood)
                            line(mood)
                        }
                    }
                } else {
                    typedLine
                }
            }
            .buttonStyle(SquishButtonStyle())
            .accessibilityLabel("\(bro.isMine ? "You" : bro.name.text), \(bro.line)")
            .accessibilityIdentifier("bubble-\(bro.isMine ? "out" : "in")-\(bro.mood?.slug ?? "typed")")
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

    private var typedLine: some View {
        Text(bro.line)
            .font(.title3.bold())
            .foregroundColor(bro.isMine ? Palette.night : Palette.cream)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(bro.isMine ? Palette.pink : Palette.plum))
            .padding(.vertical, 4)
    }

    private func sticker(_ mood: Mood) -> some View {
        PerformingSticker(mood: mood, size: 112, trigger: plays).zIndex(1)
    }

    private func line(_ mood: Mood) -> some View {
        Text(mood.line)
            .font(.display(25))
            .foregroundColor(mood.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Capsule().fill(mood.tint))
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
    let mood: Mood
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var leaving = false

    var body: some View {
        VStack(spacing: -14) {
            PerformingSticker(mood: mood, size: 230, trigger: shown ? 1 : 0)
            Text(mood.line)
                // Directions are a sentence, not a shout.
                .font(.display(mood.isDirection ? 36 : 52))
                .foregroundColor(mood.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 24)
                .padding(.vertical, 2)
                .background(Capsule().fill(mood.tint))
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

/// The stickers, plus a keyboard that can only type bro.
private struct BroPad: View {
    @Binding var typing: Bool
    let send: (Mood?) -> Void
    let rejected: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var expanded = false

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                TypeBroField(isTyping: $typing, send: { send(nil) }, rejected: rejected)
                if typing {
                    toggle("Stickers", symbol: "keyboard.chevron.compact.down", identifier: "pad-stickers") {
                        typing = false
                    }
                } else if !isWide {
                    // A wide screen always shows them all.
                    toggle(
                        expanded ? "Less" : "All \(Mood.allCases.count)",
                        symbol: expanded ? "chevron.down" : "chevron.up", identifier: "pad-expand"
                    ) {
                        withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                    }
                }
            }
            .padding(.horizontal, 10)

            // The system keyboard needs the room.
            if !typing {
                stickers
            }
        }
        .padding(.vertical, 5)
        .background(Palette.night.opacity(0.94).ignoresSafeArea(edges: .bottom))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    @ViewBuilder private var stickers: some View {
        if expanded || isWide {
            // Five across keeps eighteen to four rows, which still fits an iPhone SE.
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: isWide ? 9 : 5)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Mood.allCases, id: \.self) { key($0, size: isWide ? 70 : 62) }
            }
            .padding(.horizontal, 6)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Mood.allCases, id: \.self) { key($0, size: 70).frame(width: 86) }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func toggle(_ title: String, symbol: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.bold())
                .foregroundColor(Palette.pink)
                .frame(minWidth: 70, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
    }

    private func key(_ mood: Mood, size: CGFloat) -> some View {
        Button {
            send(mood)
        } label: {
            VStack(spacing: -3) {
                Sticker(mood: mood, size: size)
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
