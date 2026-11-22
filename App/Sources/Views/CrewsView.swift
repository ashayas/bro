import BroKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct CrewsView: View {
    @EnvironmentObject private var store: BroStore
    @State private var sharing = false
    @State private var confirmingReplace = false
    @State private var leaving: Room?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Crews").font(.script(58)).foregroundColor(.white).shadow(color: Palette.pink, radius: 10)
                CodePass(
                    share: { sharing = true },
                    replace: { confirmingReplace = true }
                )
                JoinField()
                SectionTitle("Your rooms")
                CrewRow(room: store.state.ownRoom)
                ForEach(store.state.joined) { room in
                    CrewRow(room: room)
                        .contextMenu {
                            Button(role: .destructive) { leaving = room } label: {
                                Label("Leave crew", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                }
                Text("A crew is online whenever two bros with the code are in range or on the same Wi-Fi.")
                    .font(.caption)
                    .foregroundColor(Palette.cream)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .readableWidth()
        }
        .sheet(isPresented: $sharing) {
            ShareSheet(items: [
                "Bro. Join my crew on Bro Chat: \(store.state.ownRoom.code.description)\n\(store.state.ownRoom.code.url.absoluteString)",
            ])
        }
        .confirmationDialog("Replace your code?", isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("Replace code", role: .destructive) { store.replaceCode() }
        } message: {
            Text("Bros with the old code lose you. You'll need to share the new one.")
        }
        .confirmationDialog(
            "Leave this crew?",
            isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
            presenting: leaving
        ) { room in
            Button("Leave crew", role: .destructive) { store.leave(room) }
        }
    }
}

private struct CodePass: View {
    @EnvironmentObject private var store: BroStore
    let share: () -> Void
    let replace: () -> Void

    var body: some View {
        let code = store.state.ownRoom.code
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("VIP BRO PASS").font(.display(27))
                    Text(store.state.name.text).font(.subheadline.bold())
                }
                Spacer()
                Sticker(mood: store.state.mood, size: 76)
            }
            HStack(spacing: 14) {
                QRCode(text: code.url.absoluteString)
                    .frame(width: 108, height: 108)
                VStack(alignment: .leading, spacing: 4) {
                    Text("YOUR CODE").font(.caption.bold())
                    Text(code.description)
                        .font(.display(28))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .accessibilityIdentifier("my-code")
                    Text("Scan it with the Camera, or read it out around the fire.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                action("Copy", "doc.on.doc.fill", store.copyCode)
                action("Share", "square.and.arrow.up", share)
                action("New code", "arrow.triangle.2.circlepath", replace)
            }
        }
        .foregroundColor(Palette.night)
        .padding(16)
        .background(LinearGradient(colors: [Palette.gold, Palette.orange, Palette.pink], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Palette.pink.opacity(0.5), radius: 18)
    }

    private func action(_ title: String, _ symbol: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                Text(title.uppercased()).font(.display(13)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundColor(Palette.cream)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.night.opacity(0.88)))
        }
        .buttonStyle(SquishButtonStyle())
    }
}

private struct JoinField: View {
    @EnvironmentObject private var store: BroStore
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            SectionTitle("Got a bro's code?")
            HStack(spacing: 8) {
                TextField("BRO-XXXX-XXXX", text: $input)
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundColor(Palette.cream)
                    .textInputAutocapitalization(.characters)
                    .disableAutocorrection(true)
                    .keyboardType(.asciiCapable)
                    .submitLabel(.join)
                    .focused($focused)
                    .onSubmit(join)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .panel(highlighted: focused)
                    .accessibilityIdentifier("join-field")
                Button("JOIN", action: join)
                    .buttonStyle(SunsetButtonStyle())
                    .frame(width: 100)
                    .disabled(BroCode(input) == nil)
                    .accessibilityIdentifier("join-button")
            }
        }
    }

    private func join() {
        guard let code = BroCode(input) else { return }
        input = ""
        focused = false
        store.join(code)
    }
}

private struct CrewRow: View {
    @EnvironmentObject private var store: BroStore
    let room: Room

    var body: some View {
        let members = store.members(of: room.id)
        Button {
            store.show(.room(room.id))
        } label: {
            HStack(spacing: 12) {
                Sticker(mood: store.lastBro(in: .room(room.id))?.mood ?? (room == store.state.ownRoom ? .respect : .chill), size: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.title(of: .room(room.id))).font(.headline).foregroundColor(Palette.cream).lineLimit(1)
                    Text(store.subtitle(of: .room(room.id)))
                        .font(.caption)
                        .foregroundColor(members.isEmpty ? Palette.haze : Palette.mint)
                }
                Spacer(minLength: 0)
                HStack(spacing: -12) {
                    ForEach(members.prefix(3)) { Avatar(mood: $0.mood, size: 32) }
                }
                UnreadBadge(count: store.state.unread[.room(room.id)] ?? 0)
                Image(systemName: "chevron.right").foregroundColor(Palette.pink)
            }
            .padding(10)
            .panel(highlighted: !members.isEmpty)
        }
        .buttonStyle(SquishButtonStyle())
        .accessibilityIdentifier(room == store.state.ownRoom ? "own-crew" : "joined-crew")
    }
}

private struct QRCode: View {
    let text: String
    private static let context = CIContext()

    var body: some View {
        if let image {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(7)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("QR code for your crew")
        }
    }

    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, let cgImage = Self.context.createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
