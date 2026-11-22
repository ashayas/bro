import BroKit
import SwiftUI
import UIKit

/// A real keyboard that only lets you type bro.
struct TypeBroField: View {
    @Binding var isTyping: Bool
    let send: () -> Void
    let rejected: () -> Void

    @State private var text = ""

    private var isReady: Bool { text == TypedBro.word }

    var body: some View {
        HStack(spacing: 0) {
            BroOnlyTextField(text: $text, isTyping: $isTyping, submit: submit, rejected: rejected)
                .padding(.leading, 14)
                .frame(height: 44)
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(isReady ? Palette.pink : Palette.haze.opacity(0.4))
                    .frame(width: 44, height: 44)
            }
            .disabled(!isReady)
            .accessibilityLabel("Send typed bro")
            .accessibilityIdentifier("send-typed")
        }
        .background(Capsule().fill(Palette.plum))
        .overlay(Capsule().strokeBorder(isReady ? Palette.pink : Color.white.opacity(0.12), lineWidth: isReady ? 2 : 1))
    }

    private func submit() {
        guard isReady else { return }
        send()
        text = ""
    }
}

/// UIKit, because SwiftUI's TextField can only undo a letter after it lands, which loses fast typing.
private struct BroOnlyTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isTyping: Bool
    let submit: () -> Void
    let rejected: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        field.attributedPlaceholder = NSAttributedString(
            string: "type bro…", attributes: [.foregroundColor: UIColor(Palette.haze)]
        )
        let bold = UIFont.systemFont(ofSize: 17, weight: .bold)
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: bold, maximumPointSize: 22)
        field.textColor = UIColor(Palette.cream)
        field.tintColor = UIColor(Palette.pink)
        field.keyboardType = .asciiCapable
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .send
        field.accessibilityIdentifier = "type-bro"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        // Only when asked to stop, not on every render that happens while focus is settling.
        if context.coordinator.wasTyping && !isTyping {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
        context.coordinator.wasTyping = isTyping
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: BroOnlyTextField
        var wasTyping = false

        init(_ parent: BroOnlyTextField) { self.parent = parent }

        func textField(
            _ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String
        ) -> Bool {
            let proposed = ((field.text ?? "") as NSString).replacingCharacters(in: range, with: string)
            guard let valid = TypedBro.accept(proposed) else {
                parent.rejected()
                return false
            }
            if valid == proposed { return true }
            // Same word, tidied: "BRO " shows as "bro".
            field.text = valid
            parent.text = valid
            return false
        }

        /// Also catches input that skips the check above, like dictation.
        @objc func changed(_ field: UITextField) {
            let valid = TypedBro.accept(field.text ?? "") ?? ""
            if field.text != valid { field.text = valid }
            parent.text = valid
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.submit()
            // Keep the keyboard up so you can bro again.
            return false
        }

        func textFieldDidBeginEditing(_ field: UITextField) { parent.isTyping = true }
        func textFieldDidEndEditing(_ field: UITextField) { parent.isTyping = false }
    }
}
