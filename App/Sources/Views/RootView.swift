import BroKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: BroStore

    var body: some View {
        ZStack {
            Palette.night.ignoresSafeArea()
            if store.isLocked {
                Wordmark()
            } else if store.state.onboarded {
                MainView()
                    .accessibilityHidden(store.activeChannel != nil)
                if let channel = store.activeChannel {
                    ChatView(channel: channel)
                        .id(channel)
                        .transition(.move(edge: .trailing))
                        .zIndex(1)
                }
            } else {
                OnboardingView()
            }
            if let banner = store.banner {
                BannerView(banner: banner)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .onOpenURL { url in
            if let code = BroCode(url: url) { store.pendingInvite = code }
        }
        .alert("Join this crew?", isPresented: inviteIsShown, presenting: store.pendingInvite) { code in
            Button("Join") { store.join(code) }
            Button("Nah", role: .cancel) {}
        } message: { code in
            Text("\(code.description)\nEveryone with this code will see you when you're in range.")
        }
    }

    // An invite opened during onboarding waits until you're in.
    private var inviteIsShown: Binding<Bool> {
        Binding(
            get: { store.state.onboarded && store.pendingInvite != nil },
            set: { if !$0 { store.pendingInvite = nil } }
        )
    }
}

private struct BannerView: View {
    @EnvironmentObject private var store: BroStore
    let banner: Banner

    var body: some View {
        Button {
            if let channel = banner.channel { store.show(channel) } else { store.dismissBanner() }
        } label: {
            HStack(spacing: 12) {
                if let mood = banner.mood { Sticker(mood: mood, size: 58) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(banner.title).font(.subheadline.bold()).foregroundColor(Palette.cream).lineLimit(1)
                    Text(banner.detail).font(.display(19)).foregroundColor(banner.mood?.label ?? Palette.cream).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Palette.night.opacity(0.97))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(banner.mood?.tint ?? Palette.pink, lineWidth: 2))
        }
        .buttonStyle(SquishButtonStyle())
        .padding(.horizontal, 12)
        .readableWidth()
        .accessibilityIdentifier("banner")
    }
}

private enum MainTab: CaseIterable {
    case nearby, crews, me

    var title: String {
        switch self {
        case .nearby: return "Nearby"
        case .crews: return "Crews"
        case .me: return "Me"
        }
    }

    var symbol: String {
        switch self {
        case .nearby: return "dot.radiowaves.left.and.right"
        case .crews: return "person.3.fill"
        case .me: return "person.crop.circle.fill"
        }
    }
}

private struct MainView: View {
    @EnvironmentObject private var store: BroStore
    @State private var tab = MainTab.nearby

    var body: some View {
        ZStack {
            SunsetBackground(dim: 0.5)
            VStack(spacing: 0) {
                Group {
                    switch tab {
                    case .nearby: NearbyView()
                    case .crews: CrewsView()
                    case .me: MeView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Content scrolls out of sight under the status bar, not through it.
                .clipped()
                tabBar
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 20, weight: .bold))
                            .frame(height: 24)
                            .overlay(alignment: .topTrailing) {
                                if hasUnread(item) {
                                    Circle().fill(Palette.mint).frame(width: 9, height: 9).offset(x: 9, y: -2)
                                }
                            }
                        Text(item.title.uppercased()).font(.display(13))
                    }
                    .foregroundColor(tab == item ? Palette.pink : Palette.haze)
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(SquishButtonStyle())
                .accessibilityLabel(item.title)
                .accessibilityIdentifier("tab-\(item.title)")
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .readableWidth()
        .padding(.top, 5)
        .background(Palette.night.opacity(0.96).ignoresSafeArea(edges: .bottom))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private func hasUnread(_ tab: MainTab) -> Bool {
        store.state.unread.keys.contains { channel in
            switch (tab, channel) {
            case (.nearby, .open), (.nearby, .direct), (.crews, .room): return true
            default: return false
            }
        }
    }
}
