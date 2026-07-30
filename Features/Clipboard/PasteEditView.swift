import SwiftUI

/// Edit-before-paste: the row's text, changed once, on its way to the pasteboard.
///
/// The stored history entry is NOT rewritten — the same rule the "Copy as"
/// transforms follow, because the history is a log of what was copied.
struct PasteEditView: View {
    /// Seeded once; the editor owns the text from then on. A Binding back into the
    /// list would make every keystroke redraw the rows behind the sheet.
    @State private var text: String
    private let paste: (String) -> Void
    private let cancel: () -> Void

    init(text: String, paste: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        _text = State(initialValue: text)
        self.paste = paste
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit before pasting").font(.headline)
            Text("The history entry stays exactly as it was copied.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 420, minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1))
                .accessibilityLabel("Text to paste")
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Paste") { paste(text) }
                    // ⌘↵, not plain ↵: Return belongs to the text editor above,
                    // and this sheet exists precisely to add line breaks.
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.isEmpty)
                    .help("Paste this text into the previous app (⌘↵)")
            }
        }
        .padding(16)
    }
}
