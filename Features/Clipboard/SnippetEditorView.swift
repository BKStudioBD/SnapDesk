import SwiftUI

/// Create or edit a snippet: a name, and the body it pastes.
struct SnippetEditorView: View {
    @State private var title: String
    /// NOT called `body` — that name belongs to `View`.
    @State private var text: String
    private let isNew: Bool
    private let save: (String, String) -> Void
    private let cancel: () -> Void

    init(title: String, text: String, isNew: Bool,
         save: @escaping (String, String) -> Void, cancel: @escaping () -> Void) {
        _title = State(initialValue: title)
        _text = State(initialValue: text)
        self.isNew = isNew
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "New snippet" : "Edit snippet").font(.headline)
            Text("Snippets are yours: the history limit never removes them, and clearing history on quit leaves them alone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $title)
                .accessibilityLabel("Snippet name")
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 420, minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1))
                .accessibilityLabel("Snippet text")
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(title, text) }
                    // ⌘↵ for the same reason as the paste editor: Return types a
                    // line break in the body field.
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.isEmpty)
                    .help("Save this snippet (⌘↵)")
            }
        }
        .padding(16)
    }
}
