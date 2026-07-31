import AppKit
import SwiftUI

/// The cleaner window: a dashboard of the machine, plus three things it can
/// actually recover space from: caches, build folders, and apps you're done
/// with.
///
/// Every destructive action in here goes to the Trash, with one exception the
/// UI names out loud (emptying the Trash itself). Nothing is removed without
/// being listed, sized and ticked first.
///
/// It looks like the rest of SnapDesk: standard title bar, system materials,
/// system controls, and it follows the Mac's light or dark appearance.
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "SnapDesk Cleaner"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 460, height: 460)
        window.center()
        super.init(window: window)
        window.delegate = self
        let host = NSHostingController(rootView: CleanerRootView(playSound: playSound))
        // Without this the hosting controller reports its content's ideal size
        // and the window snaps to it, ignoring contentRect and any resize.
        host.sizingOptions = []
        window.contentViewController = host
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
    // Owned here, not by the tab views: a `switch` in a ViewBuilder rebuilds the
    // branch it lands on, so tab-local @State and .task were destroyed on every
    // switch: ticks lost, and Developer re-walked the whole home directory.
    @State private var clean = CleanModel()
    @State private var developer = DeveloperModel()
    @State private var uninstall = UninstallModel()

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
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            // Each tab keeps its scan and its ticks while the window is open:
            // switching away and back re-uses the model above rather than
            // starting over.
            switch tab {
            case .dashboard: DashboardTab()
            case .clean: CleanTab(model: clean, playSound: playSound)
            case .developer: DeveloperTab(model: developer, playSound: playSound)
            case .uninstall: UninstallTab(model: uninstall, playSound: playSound)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
