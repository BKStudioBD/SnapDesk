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



// MARK: - OCR and capture

/// A page of text, drawn fresh each round so nothing is cached between passes.
func page(_ text: String, index: Int) -> CGImage? {
    let size = NSSize(width: 420, height: 90)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    ("\(text) \(index)" as NSString).draw(at: NSPoint(x: 12, y: 30), withAttributes: [
        .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage
}

func rss() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kerr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kerr == KERN_SUCCESS ? info.resident_size : 0
}

func stressOCR() async {
    var options = OCROptions()
    options.engine = .detailed          // the pass that does the real work
    var read = 0, missed = 0, failed = 0
    let before = rss()
    for i in 1...cycles {
        guard let img = page("SnapDesk stress line", index: i) else { failed += 1; continue }
        do {
            let text = try await OCRService.recognizeText(in: img, options: options)
            if text.contains("\(i)") { read += 1 } else { missed += 1 }
        } catch {
            failed += 1
        }
        if i % 25 == 0 {
            print("  ocr: \(i)/\(cycles)  read=\(read) missed=\(missed) failed=\(failed)  rss=\(rss() / 1_048_576)MB")
        }
    }
    print("  ocr done: read=\(read) missed=\(missed) failed=\(failed)")
    print("  memory: \(before / 1_048_576)MB -> \(rss() / 1_048_576)MB")
}

func stressCapture() async {
    guard let screen = NSScreen.main else { print("  no screen"); return }
    var ok = 0, blank = 0, failed = 0
    let before = rss()
    let started = Date()
    for i in 1...cycles {
        do {
            let img = try await CaptureService.captureScreen(screen)
            if CaptureService.looksBlank(img) { blank += 1 } else { ok += 1 }
        } catch {
            failed += 1
        }
        if i % 25 == 0 {
            print("  capture: \(i)/\(cycles)  ok=\(ok) blank=\(blank) failed=\(failed)  rss=\(rss() / 1_048_576)MB")
        }
    }
    print("  capture done: ok=\(ok) blank=\(blank) failed=\(failed) in \(Int(Date().timeIntervalSince(started)))s")
    print("  memory: \(before / 1_048_576)MB -> \(rss() / 1_048_576)MB")
    print("  capture state after: \(Permissions.captureState)")
}

print("stress: \(cycles) cycles, \(useOldPath ? "OLD path" : "current code")")
if arguments.contains("--ocr") {
    let done = DispatchSemaphore(value: 0)
    Task { await stressOCR(); done.signal() }
    while done.wait(timeout: .now() + 0.02) == .timedOut { spinRunLoop(0.02) }
} else if arguments.contains("--capture") {
    let done = DispatchSemaphore(value: 0)
    Task { await stressCapture(); done.signal() }
    while done.wait(timeout: .now() + 0.02) == .timedOut { spinRunLoop(0.02) }
} else if useOldPath {
    stressClipboardOldWay()
} else {
    stressClipboard()
    stressCleaner()
}
print("survived \(cycles) cycles of each")
exit(0)
