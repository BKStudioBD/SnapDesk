import AppKit
import SwiftUI

/// The cleaner window: a dashboard of the machine, and the caches it can
/// actually recover space from.
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
            // Reused, never rebuilt. Closing this window used to drop `shared`,
            // which released the window controller, its NSHostingController and
            // the whole SwiftUI tree from inside AppKit's own close
            // notification. That teardown shape, an NSResponder deallocating on
            // the main run loop and releasing a SwiftUI object with a
            // main-actor-isolated deinit, is what three of this app's crash
            // reports are. The clipboard window had the same defect.
            //
            // A reopen still gets fresh state: the session bump below changes
            // the root view's identity, so the sizes are measured again rather
            // than shown from before the last clean.
            existing.refresh()
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

    /// Bumped on every reopen; the root view hangs its `.id` on it.
    private var session = 0
    private var hosting: NSHostingController<CleanerRootView>?
    private let playSound: () -> Void

    /// New state, same objects: no AppKit teardown.
    private func refresh() {
        session &+= 1
        hosting?.rootView = CleanerRootView(session: session, playSound: playSound)
    }

    private init(playSound: @escaping () -> Void) {
        self.playSound = playSound
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "SnapDesk Cleaner"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 460, height: 460)
        window.center()
        super.init(window: window)
        window.delegate = self
        let host = NSHostingController(rootView: CleanerRootView(session: 0, playSound: playSound))
        // Without this the hosting controller reports its content's ideal size
        // and the window snaps to it, ignoring contentRect and any resize.
        host.sizingOptions = []
        window.contentViewController = host
        hosting = host
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The window is ordered out, not released, and `shared` keeps pointing at
    /// this controller. Dropping it here is what tore an NSResponder down inside
    /// AppKit's close notification; see `show`.
    func windowWillClose(_ notification: Notification) {}
}

/// The two tabs, and the only piece of state they share.
struct CleanerRootView: View {
    /// Changes on every reopen, so `.id` below discards the previous `@State`
    /// and the caches are measured again instead of shown stale.
    var session: Int = 0
    var playSound: () -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard", clean = "Clean"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .dashboard: "gauge.with.dots.needle.33percent"
            case .clean: "sparkles"
            }
        }
    }

    @State private var tab: Tab = .dashboard
    // Owned here, not by the tab view: a `switch` in a ViewBuilder rebuilds the
    // branch it lands on, so tab-local @State and .task were destroyed on every
    // switch, losing the ticks and the measured sizes with them.
    @State private var clean = CleanModel()

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

            // Clean keeps its scan and its ticks while the window is open:
            // switching away and back re-uses the model above rather than
            // starting over.
            switch tab {
            case .dashboard: DashboardTab()
            case .clean: CleanTab(model: clean, playSound: playSound)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(session)
    }
}
