import SwiftUI
import AppKit

/// SwiftUI wrapper around NSVisualEffectView — the same vibrancy "glass" the
/// capture editor uses, so every window shares one look. Default = behind-window
/// HUD glass (dark, high-contrast).

extension View {
    /// Grouped form with its opaque background hidden so the window glass shows.
    func glassForm() -> some View {
        self.formStyle(.grouped).scrollContentBackground(.hidden)
    }
}
