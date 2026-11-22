import BroKit
import SwiftUI

struct MeView: View {
    @EnvironmentObject private var store: BroStore
    @State private var confirmingClear = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Sticker(mood: store.state.mood, size: 150)
                NamePicker(name: Binding(
                    get: { store.state.name },
                    set: { store.setProfile(name: $0, mood: store.state.mood) }
                ))
                SectionTitle("Your face")
                MoodFacePicker(selection: Binding(
                    get: { store.state.mood },
                    set: { store.setProfile(name: store.state.name, mood: $0) }
                ))

                SectionTitle("Radios")
                group {
                    setting("Bluetooth", detail: "No signal needed. Hops phone to phone.", \.bluetooth)
                    setting("Same Wi-Fi", detail: "Also works phone to phone while the app is open.", \.wifi)
                    Text("\(store.linkCount) live links")
                        .font(.caption)
                        .foregroundColor(Palette.mint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                SectionTitle("Vibes")
                group {
                    setting("Say it out loud", detail: "Every mood says bro differently.", \.voice)
                    setting("Sound effects", detail: "Follows your silent switch.", \.effects)
                    setting("Haptics", detail: "Feel the bro.", \.haptics)
                    setting("Notifications", detail: "For crews and direct bros. Never the Strip.", \.notifications)
                }

                if !store.state.blocked.isEmpty {
                    SectionTitle("Not bros")
                    group {
                        ForEach(store.state.blocked.sorted(), id: \.self) { id in
                            HStack {
                                Text(store.name(of: id)).foregroundColor(Palette.cream)
                                Spacer()
                                Button("Unblock") { store.unblock(id) }.foregroundColor(Palette.pink)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }

                SectionTitle("The bro code")
                group {
                    fact("No accounts, servers, analytics or internet.")
                    fact("Crew and direct bros are end-to-end encrypted. The Strip is public.")
                    fact("No text exists in the protocol. Even the keyboard can only type bro.")
                    fact("Force-quit the app and you go dark until you open it again.")
                }

                Button("Clear all bros", role: .destructive) { confirmingClear = true }
                    .frame(minHeight: 44)
            }
            .padding(16)
            .readableWidth()
        }
        .confirmationDialog("Clear every chat on this phone?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear all bros", role: .destructive) { store.clearHistory() }
        }
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity)
            .panel()
    }

    private func setting(_ title: String, detail: String, _ path: WritableKeyPath<Settings, Bool>) -> some View {
        Toggle(isOn: Binding(
            get: { store.state.settings[keyPath: path] },
            set: { store.update(path, to: $0) }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.bold()).foregroundColor(Palette.cream)
                Text(detail).font(.caption).foregroundColor(Palette.haze).fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Palette.pink)
    }

    private func fact(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(Palette.cream)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
