import AppKit
import SwiftUI

/// The cleaner window: a dashboard of the machine, plus three things it can
/// actually recover space from — caches, build folders, and apps you're done
/// with.
///
/// Every destructive action in here goes to the Trash, with one exception the
/// UI names out loud (emptying the Trash itself). Nothing is removed without
/// being listed, sized and ticked first.
final class CleanerWindow: NSWindowController, NSWindowDelegate {
    private static var shared: CleanerWindow?

    static func show(playSound: @escaping () -> Void) {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = CleanerWindow(playSound: playSound)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(playSound: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "SnapDesk Cleaner"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        // The one window in the app that is dark whatever the Mac is set to —
        // a dashboard reads better on a dark ground, and the reclaimable figures
        // keep the same weight in both system appearances.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(CleanerTheme.background)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: CleanerRootView(playSound: playSound))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

/// The four tabs, and the only piece of state they share.
struct CleanerRootView: View {
    var playSound: () -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard", clean = "Clean", developer = "Developer", uninstall = "Uninstall"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .dashboard: "gauge.with.dots.needle.33percent"
            case .clean: "sparkles"
            case .developer: "hammer"
            case .uninstall: "trash"
            }
        }
    }

    @State private var tab: Tab = .dashboard

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 28)      // room for the hidden title bar
            .padding(.bottom, 10)

            Divider().overlay(CleanerTheme.line)

            // Each tab keeps its own scan while the window is open: switching
            // away and back should not re-walk the whole home directory.
            switch tab {
            case .dashboard: DashboardTab()
            case .clean: CleanTab(playSound: playSound)
            case .developer: DeveloperTab(playSound: playSound)
            case .uninstall: UninstallTab(playSound: playSound)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CleanerTheme.background)
        .preferredColorScheme(.dark)
    }
}
