import AppKit
import SwiftUI

// Opens and closes the two windows that used to rebuild an NSResponder on every
// use, many times over, with the run loop spun between cycles so the autorelease
// pool actually drains. The crash being hunted happens inside that drain:
//
//   __CFRunLoopDoBlocks -> objc_autoreleasePoolPop -> -[NSResponder dealloc]
//     -> object_cxxDestructFromClass -> swift_task_deinitOnExecutorImpl -> trap
//
// Run headless, so nobody's screen is taken over:
//
//   ./tools/stress/run.sh 50        # current code
//   ./tools/stress/run.sh 50 --old  # rebuilding the controller every open
//
// A crash IS the result. Reaching the end and printing a count is the pass.

let arguments = CommandLine.arguments
let cycles = Int(arguments.dropFirst().first(where: { Int($0) != nil }) ?? "50") ?? 50
let useOldPath = arguments.contains("--old")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let settings = SettingsStore()
let manager = ClipboardManager()
manager.attach(settings: settings)

/// Let AppKit finish what a close schedules. The teardown under test does not
/// happen at `close()`, it happens when the run loop drains its pool afterwards,
/// so a loop that never returns to the run loop tests nothing.
func spinRunLoop(_ seconds: TimeInterval = 0.02) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func stressClipboard() {
    let controller = ClipboardWindowController(manager: manager, settings: settings)
    for i in 1...cycles {
        controller.willShow(prev: nil)
        controller.showWindow(nil)
        controller.window?.orderFront(nil)
        spinRunLoop()
        controller.window?.close()
        spinRunLoop()
        if i % 10 == 0 { print("  clipboard: \(i)/\(cycles)") }
    }
}

/// What the code did before: a brand new hosting controller per open, which
/// destroys the previous one (an NSResponder) and its whole SwiftUI tree.
func stressClipboardOldWay() {
    let controller = ClipboardWindowController(manager: manager, settings: settings)
    for i in 1...cycles {
        let host = NSHostingController(
            rootView: ClipboardHistoryView(session: i, manager: manager,
                                           settings: settings, snippets: SnippetStore()))
        host.sizingOptions = []
        controller.window?.contentViewController = host   // the old controller dies here
        controller.showWindow(nil)
        controller.window?.orderFront(nil)
        spinRunLoop()
        controller.window?.close()
        spinRunLoop()
        if i % 10 == 0 { print("  clipboard (old path): \(i)/\(cycles)") }
    }
}

func stressCleaner() {
    for i in 1...cycles {
        CleanerWindow.show(playSound: {})
        spinRunLoop()
        // Closing used to drop the shared reference and take the controller,
        // its hosting controller and the SwiftUI tree with it.
        NSApp.windows.first { $0.title == "SnapDesk Cleaner" }?.close()
        spinRunLoop()
        if i % 10 == 0 { print("  cleaner: \(i)/\(cycles)") }
    }
}

print("stress: \(cycles) cycles, \(useOldPath ? "OLD path" : "current code")")
if useOldPath {
    stressClipboardOldWay()
} else {
    stressClipboard()
    stressCleaner()
}
print("survived \(cycles) cycles of each")
exit(0)
