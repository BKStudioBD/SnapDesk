import SwiftUI

/// The cleaner's own palette.
///
/// This is the one window in SnapDesk that does not follow the system
/// appearance: it is a dark dashboard on purpose, so the numbers and the green
/// "reclaimable" figures read the same whatever the Mac is set to. Everything
/// else in the app uses native materials.
enum CleanerTheme {
    static let background = Color(hex: "#0F172A")
    static let card = Color(hex: "#1A2338")
    static let line = Color(hex: "#2B3752")
    static let text = Color(hex: "#E8ECF5")
    static let muted = Color(hex: "#94A3B8")
    static let accent = Color(hex: "#22C55E")
    static let warning = Color(hex: "#F59E0B")

    /// Health ring / gauge colour: green when there is room, amber when it is
    /// getting tight, red when it isn't. Never colour alone — every place this
    /// is used also shows the number.
    static func gauge(_ score: Int) -> Color {
        switch score {
        case 70...: accent
        case 40..<70: warning
        default: Color(hex: "#EF4444")
        }
    }
}

/// A panel on the dark background — the shape every section in the cleaner uses.
struct CleanerCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(CleanerTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(CleanerTheme.line, lineWidth: 1))
    }
}
