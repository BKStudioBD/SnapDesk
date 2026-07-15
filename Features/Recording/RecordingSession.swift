import AppKit
import AVFoundation
import ScreenCaptureKit

/// One screen-recording run, CleanShot-style: 3-2-1 countdown over the region,
/// an accent border marking what's recorded, and a floating glass control bar
/// (timer · pause/resume · stop · cancel). SnapDesk's own windows are excluded
/// from the capture, so none of this chrome appears in the video.
/// All methods are called on the main thread (menu / hotkey / timer).
final class RecordingSession: NSObject {
    private let recorder = ScreenRecorder()
    private let selection: RegionSelection
    private let settings: SettingsStore
    private let url: URL
    /// Privacy blur regions (screen-local points, same space as the selection);
    /// they stay pixelated in the video for the whole recording.
    private let blurRects: [CGRect]

    private var borderWindow: NSWindow?
    private var barWindow: NSWindow?
    private var countdownWindow: NSWindow?
    private var timeLabel: NSTextField?
    private var pauseButton: NSButton?

    private var timer: Timer?
    private var startDate = Date()
    private var pausedAccum: TimeInterval = 0
    private var pauseBegan: Date?
    private var discardOnFinish = false
    private var cancelled = false
    private var finishedOnce = false
    private var startedRecording = false

    /// True when the user cancelled/discarded (so a nil URL isn't an error).
    var wasDiscarded: Bool { discardOnFinish || cancelled }

    private(set) var isPaused = false

    /// (elapsed "M:SS" for the menu bar) — fired every timer tick.
    var onTick: ((String) -> Void)?
    /// State changed (started / paused / stopped) — refresh menus/icons.
    var onStateChange: (() -> Void)?
    /// Recording ended. URL is nil on failure or cancel.
    var onFinished: ((URL?) -> Void)?

    init(selection: RegionSelection, settings: SettingsStore, url: URL, blurRects: [CGRect] = []) {
        self.selection = selection
        self.settings = settings
        self.url = url
        self.blurRects = blurRects
        super.init()
        recorder.onFinish = { [weak self] finishedURL in
            self?.handleFinish(finishedURL)   // recorder already delivers on main
        }
    }

    // MARK: - Flow

    @MainActor
    func start() async {
        // Resolve the microphone FIRST (the permission dialog belongs before the
        // countdown, not after it; denied permission just drops voice).
        var micDevice: AVCaptureDevice?
        if settings.recordMic {
            if await AVCaptureDevice.requestAccess(for: .audio) {
                micDevice = MicCapture.device(forID: settings.micDeviceID)
            } else {
                Notifier.info("Microphone off",
                              "Allow SnapDesk under Privacy → Microphone to record your voice.")
            }
        }
        // Camera permission for the webcam bubble (denied → bubble skipped).
        var cameraOK = false
        if settings.recordCamera {
            cameraOK = await AVCaptureDevice.requestAccess(for: .video)
            if !cameraOK {
                Notifier.info("Camera off", "Allow SnapDesk under Privacy → Camera for the webcam bubble.")
            }
        }
        if cancelled { return }

        // Countdown (Esc or ⌃5 aborts). stop() already tore down and notified —
        // just bail, don't start recording.
        await runCountdown()
        if cancelled { return }

        showBorder()
        showControlBar()

        var decorator: FrameDecorator?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let displayID = selection.screen.displayID
            // NO first-display fallback: recording the wrong monitor is worse
            // than failing with a clear error (display just disconnected).
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID })
            else { throw ScreenRecorder.RecorderError.setup }
            // Exclude SnapDesk APP-WIDE (not a window snapshot) so windows opened
            // DURING the recording — capture editor, clipboard, pins — never
            // appear in the video either.
            let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
            let filter: SCContentFilter
            if let ourApp = content.applications.first(where: { $0.processID == pid }) {
                filter = SCContentFilter(display: scDisplay, excludingApplications: [ourApp],
                                         exceptingWindows: [])
            } else {
                let ours = content.windows.filter { $0.owningApplication?.processID == pid }
                filter = SCContentFilter(display: scDisplay, excludingWindows: ours)
            }
            // Screen-Studio-style burned-in effects (cursor/clicks/keys/camera).
            let wantsEffects = settings.recordCursorBoost || settings.recordClickHighlight
                || settings.recordKeystrokes || (settings.recordCamera && cameraOK)
            if wantsEffects {
                let cfg = FrameDecorator.Config(
                    cursorBoost: settings.recordCursorBoost,
                    clickHighlight: settings.recordClickHighlight,
                    keystrokes: settings.recordKeystrokes,
                    camera: settings.recordCamera && cameraOK)
                let deco = FrameDecorator(config: cfg,
                                          displayID: selection.screen.displayID,
                                          sourceRect: selection.rectInScreenPoints,
                                          scale: selection.screen.backingScaleFactor)
                deco.start()
                decorator = deco
            }

            // Cancel/Stop pressed DURING the async content fetch above → the UI
            // is already torn down and our recordingSession ref is gone. Bail
            // before spinning up a recording nobody can stop (writes to disk
            // until app quit otherwise).
            if cancelled {
                decorator?.stop()
                decorator = nil
                teardownWindows()
                return
            }

            // Boosted cursor replaces the real one (avoid double cursors).
            let showCursor = settings.recordShowCursor && !settings.recordCursorBoost
            try recorder.start(display: scDisplay, filter: filter,
                               sourceRect: selection.rectInScreenPoints,
                               scale: selection.screen.backingScaleFactor,
                               captureAudio: settings.recordSystemAudio,
                               micDevice: micDevice,
                               fps: settings.recordFPS,
                               codec: settings.recordHEVC ? .hevc : .h264,
                               bitsPerPixel: settings.recordQuality.bitsPerPixel,
                               showCursor: showCursor,
                               blurRectsPx: blurRectsPx(),
                               decorator: decorator,
                               url: url)
            startedRecording = true
            startDate = Date()
            pausedAccum = 0
            startTimer()
            onStateChange?()
        } catch {
            // The decorator started BEFORE the recorder — stop it or its event
            // monitors + camera session (webcam light!) leak until app quit.
            decorator?.stop()
            decorator = nil
            teardownWindows()
            Notifier.error("Recording failed", error.localizedDescription)
            onFinished?(nil)
        }
    }

    func togglePause() {
        guard recorder.isRecording else { return }
        if isPaused {
            recorder.resume()
            if let began = pauseBegan { pausedAccum += Date().timeIntervalSince(began) }
            pauseBegan = nil
            isPaused = false
        } else {
            recorder.pause()
            pauseBegan = Date()
            isPaused = true
        }
        pauseButton?.image = Self.symbol(isPaused ? "play.fill" : "pause.fill")
        pauseButton?.toolTip = isPaused ? "Resume" : "Pause"
        onStateChange?()
    }

    func stop() {
        if recorder.isRecording {
            recorder.stop()
        } else if !startedRecording {
            // Not recording yet (countdown / setup) → abort the pending start
            // so it can't spin up an orphan recording after we finish.
            cancelled = true
            handleFinish(nil)
        }
        // else: already finalizing — ignore the extra press; the writer's
        // completion will deliver the real URL exactly once.
    }

    /// Stop and throw the file away (nothing saved, no preview).
    func cancel() {
        discardOnFinish = true
        stop()
    }

    private func handleFinish(_ finishedURL: URL?) {
        // Fires from user-stop AND the writer's async completion — only once.
        guard !finishedOnce else { return }
        finishedOnce = true
        timer?.invalidate(); timer = nil
        teardownWindows()
        if discardOnFinish {
            if let u = finishedURL { try? FileManager.default.removeItem(at: u) }
            onFinished?(nil)
        } else {
            onFinished?(finishedURL)
        }
    }

    private func teardownWindows() {
        [borderWindow, barWindow, countdownWindow].forEach { $0?.orderOut(nil) }
        borderWindow = nil; barWindow = nil; countdownWindow = nil
        timeLabel = nil; pauseButton = nil
    }

    /// Blur regions → pixel coords (top-left origin) relative to the output frame.
    private func blurRectsPx() -> [CGRect] {
        let s = selection.rectInScreenPoints
        let k = selection.screen.backingScaleFactor
        return blurRects.compactMap { b in
            let r = CGRect(x: (b.minX - s.minX) * k, y: (b.minY - s.minY) * k,
                           width: b.width * k, height: b.height * k).integral
            return r.width > 2 && r.height > 2 ? r : nil
        }
    }

    // MARK: - Geometry

    /// Selection rect in global AppKit (bottom-left origin) coords.
    private var globalRect: NSRect {
        let s = selection.screen.frame
        let r = selection.rectInScreenPoints
        return NSRect(x: s.minX + r.minX, y: s.minY + s.height - r.maxY,
                      width: r.width, height: r.height)
    }

    // MARK: - Countdown

    /// Countdown window that can become key so Esc cancels (human instinct).
    private final class CountdownWindow: NSWindow {
        var onEsc: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEsc?() } else { super.keyDown(with: event) }
        }
    }

    @MainActor
    private func runCountdown() async {
        let secs = settings.recordCountdown
        guard secs > 0 else { return }   // "Off" → start instantly
        let g = globalRect
        let size: CGFloat = 120
        let win = CountdownWindow(contentRect: NSRect(x: g.midX - size / 2, y: g.midY - size / 2,
                                                      width: size, height: size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.onEsc = { [weak self] in self?.stop() }   // aborts via the countdown-phase path
        let label = NSTextField(labelWithString: "\(secs)")
        label.font = .systemFont(ofSize: 84, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 8, width: size, height: size - 16)
        let bg = NSView(frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        bg.layer?.cornerRadius = 24
        bg.addSubview(label)
        win.contentView = bg
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        countdownWindow = win

        for n in stride(from: secs, through: 1, by: -1) {
            if cancelled { break }
            label.stringValue = "\(n)"
            try? await Task.sleep(nanoseconds: 1_000_000_000)   // a real second per tick
        }
        win.orderOut(nil)
        countdownWindow = nil
    }

    // MARK: - Border

    private func showBorder() {
        // Spotlight: everything OUTSIDE the recorded area dims (premium tint),
        // the area itself stays live with a red recording border. Click-through,
        // and excluded from the capture filter — never appears in the video.
        let win = SpotlightOverlay.window(around: globalRect,
                                          on: selection.screen, border: .systemRed)
        win.orderFront(nil)
        borderWindow = win
    }


    // MARK: - Control bar

    private func showControlBar() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 10)

        // Red dot + timer.
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let label = NSTextField(labelWithString: "0:00")
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        timeLabel = label

        let pause = glassButton("pause.fill", "Pause", #selector(pauseTapped))
        pauseButton = pause
        let stopB = glassButton("stop.fill", "Stop & save", #selector(stopTapped))
        stopB.contentTintColor = .systemRed
        let cancelB = glassButton("xmark", "Cancel (discard)", #selector(cancelTapped))

        [dot, label, separator(), pause, stopB, cancelB].forEach { stack.addArrangedSubview($0) }

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .vibrantDark)
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1
        fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        let size = stack.fittingSize

        // Below the region; above it if there's no room. Full-screen recording:
        // neither fits → float INSIDE near the bottom, else Stop/Pause would sit
        // offscreen and the user can't end the recording from the UI.
        let g = globalRect
        var origin = NSPoint(x: g.midX - size.width / 2, y: g.minY - size.height - 12)
        let screenF = selection.screen.visibleFrame
        if origin.y < screenF.minY { origin.y = g.maxY + 12 }
        if origin.y + size.height > screenF.maxY { origin.y = screenF.minY + 24 }
        origin.x = min(max(origin.x, screenF.minX + 8), screenF.maxX - size.width - 8)

        let win = NSWindow(contentRect: NSRect(origin: origin, size: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        fx.frame = NSRect(origin: .zero, size: size)
        win.contentView = fx
        win.orderFront(nil)
        barWindow = win
    }

    private func glassButton(_ symbol: String, _ help: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: Self.symbol(symbol), target: self, action: action)
        b.isBordered = false
        b.setButtonType(.momentaryChange)
        b.contentTintColor = .white
        b.toolTip = help
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    private func separator() -> NSView {
        let v = NSBox(); v.boxType = .separator
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    private static func symbol(_ name: String) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 13, height: 13))
        return img.withSymbolConfiguration(cfg) ?? img
    }

    @objc private func pauseTapped() { togglePause() }
    @objc private func stopTapped() { stop() }
    @objc private func cancelTapped() { cancel() }

    // MARK: - Windows / timer helpers

    /// Borderless, click-through, all-spaces overlay window.

    private func startTimer() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common: keep the elapsed display ticking while a menu is open or the
        // control bar is being dragged (default mode stalls during tracking).
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        var elapsed = Date().timeIntervalSince(startDate) - pausedAccum
        if let began = pauseBegan { elapsed -= Date().timeIntervalSince(began) }
        elapsed = max(0, elapsed)
        let m = Int(elapsed) / 60, s = Int(elapsed) % 60
        let text = String(format: "%d:%02d", m, s)
        timeLabel?.stringValue = text
        onTick?(text)
    }
}
