import BroKit
import SwiftUI

struct OnboardingView: View {
    private enum Step { case welcome, profile, reach }

    @EnvironmentObject private var store: BroStore
    @State private var step = Step.welcome
    @State private var name = BroName.random()
    @State private var mood = Mood.happy
    @State private var isOpen = true

    var body: some View {
        ZStack {
            switch step {
            case .welcome: welcome
            case .profile: profile
            case .reach: reach
            }
        }
    }

    private var welcome: some View {
        ZStack {
            Palette.night
                .overlay(Image(decorative: "scene-hero").resizable().scaledToFill())
                .overlay(LinearGradient(colors: [.clear, .clear, Palette.night.opacity(0.95)], startPoint: .top, endPoint: .bottom))
                .clipped()
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 12) {
                Wordmark(size: 62)
                Spacer()
                Text("ONE WORD.\nNO SIGNAL NEEDED.")
                    .font(.display(38))
                    .foregroundColor(Palette.cream)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Chat with the bros around you over Bluetooth or Wi-Fi. You can only say bro.")
                    .font(.callout)
                    .foregroundColor(Palette.cream)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("SAY LESS") { go(.profile) }
                    .buttonStyle(SunsetButtonStyle())
                    .accessibilityIdentifier("onboarding-start")
                    .padding(.top, 10)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 14)
            .readableWidth()
        }
    }

    private var profile: some View {
        page(title: "WHO EVEN ARE YOU, BRO?", button: "THAT'S ME", identifier: "onboarding-profile") {
            go(.reach)
        } content: {
            Sticker(mood: mood, size: 180)
            NamePicker(name: $name)
            Text("No typing names. That is how words get in.").font(.footnote).foregroundColor(Palette.haze)
            MoodFacePicker(selection: $mood)
        }
    }

    private var reach: some View {
        page(title: "WHO CAN BRO YOU?", button: "LET'S GO", identifier: "onboarding-finish") {
            store.finishOnboarding(name: name, mood: mood, isOpen: isOpen)
        } content: {
            Image("scene-camp")
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityHidden(true)
            choice(open: true, title: "OPEN", detail: "Anyone nearby can see you and bro you.")
            choice(open: false, title: "CODE ONLY", detail: "Invisible, except to bros who share a code with you.")
            Text("iOS will ask for Bluetooth and local network next. Bluetooth works with zero signal. Wi-Fi reaches bros on the same network. Nothing touches the internet.")
                .font(.footnote)
                .foregroundColor(Palette.cream)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .panel()
        }
    }

    private func choice(open: Bool, title: String, detail: String) -> some View {
        Button {
            isOpen = open
        } label: {
            HStack(spacing: 14) {
                Sticker(mood: open ? .party : .sus, size: 72)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.display(24)).foregroundColor(Palette.cream)
                    Text(detail)
                        .font(.footnote)
                        .foregroundColor(Palette.haze)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isOpen == open ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isOpen == open ? Palette.mint : Palette.haze)
            }
            .padding(12)
            .panel(highlighted: isOpen == open)
        }
        .buttonStyle(SquishButtonStyle())
        .accessibilityAddTraits(isOpen == open ? .isSelected : [])
    }

    private func page<Content: View>(
        title: String, button: String, identifier: String, action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            SunsetBackground(dim: 0.45)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        Text(title)
                            .font(.display(38))
                            .foregroundColor(Palette.cream)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        content()
                    }
                    .padding(22)
                    .readableWidth()
                }
                .clipped()
                Button(button, action: action)
                    .buttonStyle(SunsetButtonStyle())
                    .accessibilityIdentifier(identifier)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .readableWidth()
            }
        }
    }

    private func go(_ next: Step) {
        withAnimation(.easeInOut(duration: 0.25)) { step = next }
    }
}

struct NamePicker: View {
    @Binding var name: BroName

    var body: some View {
        HStack(spacing: 10) {
            Text(name.text.uppercased())
                .font(.display(30))
                .foregroundColor(Palette.gold)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("bro-name")
            Button {
                name = .random()
            } label: {
                Image(systemName: "dice.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Palette.night)
                    .frame(width: 50, height: 50)
                    .background(Palette.mint)
                    .clipShape(Circle())
            }
            .buttonStyle(SquishButtonStyle())
            .accessibilityLabel("Roll a new name")
        }
        .padding(10)
        .panel()
    }
}

struct MoodFacePicker: View {
    @Binding var selection: Mood
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Mood.faces, id: \.self) { mood in
                Button {
                    selection = mood
                } label: {
                    Sticker(mood: mood, size: 66)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .panel(highlighted: selection == mood)
                }
                .buttonStyle(SquishButtonStyle())
                .accessibilityLabel("\(mood.title) face")
                .accessibilityAddTraits(selection == mood ? .isSelected : [])
            }
        }
    }
}
