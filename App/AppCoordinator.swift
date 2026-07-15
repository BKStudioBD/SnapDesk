import AppKit
import SwiftUI
import ScreenCaptureKit

/// Central object that owns every feature manager, the menu-bar item, and the
/// global hotkey bindings. One instance lives for the whole app session.
///
/// Subclasses NSObject so NSMenu target/action validation (`respondsToSelector:`)
/// works — otherwise the menu-bar items get auto-disabled (greyed) and clicks
/// don't dispatch, even though the global hotkeys still fire.
final class AppCoordinator: NSObject {
    let settings = SettingsStore()
    let hotkeys = HotkeyCenter()
    let clipboard = ClipboardManager()
    private var recordingSession: RecordingSession?

    private var statusItem: NSStatusItem?
    private var clipboardWindow: ClipboardWindowController?
    private var settingsWindow: SettingsWindowController?
    private var welcomeWindow: WelcomeWindowController?

    // MARK: - Lifecycle

    func start() {
        Notifier.requestAuthorization()
        // Sandbox: re-earn access to the user-picked save folders.
        FolderAccess.restore(key: "recdir")
        FolderAccess.restore(key: "shotdir")
        // Register SnapDesk in the Accessibility list WITHOUT a launch-time
        // dialog — we only prompt when the user actually triggers paste.
        Permissions.ensureAccessibility(prompt: false)
        clipboard.attach(settings: settings)
        clipboard.start()
        setupStatusItem()

        // Re-register hotkeys whenever the user rebinds one.
        settings.onHotkeysChanged = { [weak self] in self?.registerHotkeys() }
        // Redraw the menu-bar icon live when its style changes.
        settings.onMenuBarStyleChanged = { [weak self] in
            guard let self else { return }
            if self.recordingSession != nil {
                self.updateRecordingUI()   // keep the recording indicator
            } else {
                self.statusItem?.button?.image = MenuBarIcon.image(style: self.settings.menuBarIconStyle)
            }
        }
        registerHotkeys()

        // While the Settings shortcut-recorder is armed, suspend global hotkeys
        // so the combo being pressed is captured instead of firing an action.
        NotificationCenter.default.addObserver(forName: .hotkeyRecordingBegan, object: nil, queue: .main) {
            [weak self] _ in self?.hotkeys.unregisterAll()
        }
        NotificationCenter.default.addObserver(forName: .hotkeyRecordingEnded, object: nil, queue: .main) {
            [weak self] _ in self?.registerHotkeys()
        }

        // First launch → show the welcome / setup window.
        if !UserDefaults.standard.bool(forKey: "welcomeShown") {
            UserDefaults.standard.set(true, forKey: "welcomeShown")
            DispatchQueue.main.async { [weak self] in self?.showWelcome() }
        }
    }

    func stop() {
        clipboard.stop()
        hotkeys.unregisterAll()
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.image(style: settings.menuBarIconStyle)
        item.button?.toolTip = "SnapDesk"
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(featureItem("Capture & Annotate", #selector(captureAndAnnotate), settings.screenshotHotkey, "camera.viewfinder"))
        menu.addItem(featureItem("Grab Text (OCR)", #selector(ocrCapture), settings.ocrHotkey, "text.viewfinder"))
        menu.addItem(featureItem("Pick a Color", #selector(pickColor), settings.colorHotkey, "eyedropper"))
        menu.addItem(featureItem("Clipboard History…", #selector(showClipboard), settings.clipboardHotkey, "doc.on.clipboard"))
        let recording = recordingSession != nil
        menu.addItem(featureItem(recording ? "Stop Recording" : "Record Screen…",
                                 #selector(recordScreen), settings.recordHotkey,
                                 recording ? "stop.circle.fill" : "record.circle"))
        if recording {
            let pause = plainItem(recordingSession?.isPaused == true ? "Resume Recording" : "Pause Recording",
                                  #selector(togglePauseRecording),
                                  recordingSession?.isPaused == true ? "play.circle" : "pause.circle")
            menu.addItem(pause)
        }
        menu.addItem(featureItem("Scrolling Capture…", #selector(scrollingCapture), settings.scrollHotkey, "arrow.up.and.down.text.horizontal"))
        menu.addItem(plainItem("Cleaner (RAM · Cache · Temp · Trash)…", #selector(cleanRAM), "sparkles"))
        menu.addItem(.separator())
        menu.addItem(plainItem("Welcome & Setup…", #selector(showWelcome), "hand.wave"))
        menu.addItem(plainItem("Shortcuts & Help…", #selector(openHelp), "questionmark.circle"))
        menu.addItem(plainItem("Settings…", #selector(openSettings), "gearshape"))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SnapDesk", action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)
        return menu
    }

    /// Menu item that shows its global shortcut (e.g. ⌃1) and an icon.
    private func featureItem(_ title: String, _ action: Selector, _ hotkey: Hotkey, _ symbol: String) -> NSMenuItem {
        let (keyEq, mask) = hotkey.menuKeyEquivalent
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEq)
        item.keyEquivalentModifierMask = mask
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func plainItem(_ title: String, _ action: Selector, _ symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        hotkeys.unregisterAll()
        hotkeys.bind(settings.screenshotHotkey) { [weak self] in self?.captureAndAnnotate() }
        hotkeys.bind(settings.ocrHotkey)        { [weak self] in self?.ocrCapture() }
        hotkeys.bind(settings.colorHotkey)      { [weak self] in self?.pickColor() }
        hotkeys.bind(settings.clipboardHotkey)  { [weak self] in self?.showClipboard() }
        hotkeys.bind(settings.recordHotkey)     { [weak self] in self?.recordScreen() }
        hotkeys.bind(settings.scrollHotkey)     { [weak self] in self?.scrollingCapture() }
        statusItem?.menu = buildMenu()
    }

    // MARK: - Actions

    /// True while a freeze-capture is queued/in flight — spamming ⌃1 must not
    /// launch five full multi-display captures.
    private var screenshotInFlight = false

    @objc func captureAndAnnotate() {
        guard !screenshotInFlight else { return }
        guard Permissions.ensureScreenRecording() else { return }
        screenshotInFlight = true
        // Count captures so the editor's first-run hint can fade out after a few.
        let d = UserDefaults.standard
        d.set(d.integer(forKey: "editorHintCount") + 1, forKey: "editorHintCount")
        // Freeze every display, then show the in-place editor
        // (select → annotate on the dimmed overlay → Copy/Save). Optional delay
        // first so the user can arrange windows.
        afterCaptureDelay { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                defer { self.screenshotInFlight = false }
                do {
                    var shots: [(NSScreen, CGImage)] = []
                    for screen in NSScreen.screens {
                        shots.append((screen, try await CaptureService.captureScreen(screen)))
                    }
                    guard !shots.isEmpty else { return }
                    let windowRects = CaptureService.onScreenWindowRects()
                    CaptureEditor.begin(shots: shots, windowRects: windowRects, settings: self.settings)
                } catch {
                    Notifier.error("Screenshot failed", error.localizedDescription)
                }
            }
        }
    }

    /// Runs `body` after the user's configured capture delay (0 = immediate).
    private func afterCaptureDelay(_ body: @escaping () -> Void) {
        let secs = settings.captureDelaySeconds
        guard secs > 0 else { body(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(secs), execute: body)
    }

    @objc func ocrCapture() {
        guard Permissions.ensureScreenRecording() else { return }
        // OCR: no full-screen dim — only the dragged area tints dark.
        RegionSelector.selectRegion(dim: .selectionOnly) { [weak self] selection in
            guard let self, let selection else { return }
            Task { @MainActor in
                do {
                    let image = try await CaptureService.capture(selection)
                    let text = try await OCRService.recognizeText(
                        in: image,
                        keepLineBreaks: self.settings.ocrKeepLineBreaks,
                        trim: self.settings.ocrTrimWhitespace,
                        languages: self.settings.ocrRecognitionLanguages,
                        autoDetectLanguage: self.settings.ocrAutoDetect)
                    if text.isEmpty {
                        // Always tell the user — a silent miss looks like a broken app.
                        Notifier.info("No text found", "Try a tighter selection around the text.")
                    } else {
                        // Append mode adds to existing clipboard text instead of replacing.
                        var out = text
                        if self.settings.ocrAppend,
                           let existing = NSPasteboard.general.string(forType: .string), !existing.isEmpty {
                            out = existing + "\n" + text
                        }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(out, forType: .string)
                        if self.settings.ocrNotify {
                            Notifier.info("Text copied", text.prefix(80) + (text.count > 80 ? "…" : ""))
                        }
                        self.playSoundIfEnabled()
                    }
                } catch {
                    Notifier.error("OCR failed", error.localizedDescription)
                }
            }
        }
    }

    @objc func pickColor() {
        ColorPickerService.pick { [weak self] color in
            // nil = user pressed Esc → stop (also ends continuous mode).
            guard let self, let color else { return }
            let value = color.formatted(as: self.settings.colorFormat,
                                        uppercaseHex: self.settings.uppercaseHex)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            self.settings.addRecentColor(color.hexString(uppercase: self.settings.uppercaseHex))
            if self.settings.colorNotify { Notifier.info("Color copied", value) }
            self.playSoundIfEnabled()
            // Continuous mode: reopen the eyedropper for rapid sampling.
            if self.settings.colorContinuous {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.pickColor() }
            }
        }
    }

    @objc func showClipboard() {
        // Remember the app the user was in so "double-click to paste" can target
        // it — but never record SnapDesk itself (⌃4 pressed twice would
        // otherwise paste into our own panel).
        var prev = NSWorkspace.shared.frontmostApplication
        if prev?.processIdentifier == NSRunningApplication.current.processIdentifier {
            prev = clipboardWindow?.previousApp
        }
        if clipboardWindow == nil {
            clipboardWindow = ClipboardWindowController(manager: clipboard, settings: settings)
        }
        clipboardWindow?.willShow(prev: prev)
        clipboardWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings)
        }
        settingsWindow?.show()
    }

    @objc func openHelp() {
        settings.selectedSection = "Help"
        openSettings()
    }

    @objc func showWelcome() {
        if welcomeWindow == nil { welcomeWindow = WelcomeWindowController(settings: settings) }
        welcomeWindow?.show()
    }

    // MARK: - Screen recording

    @objc func recordScreen() {
        // Toggle: pressing the hotkey while recording stops & saves.
        if let session = recordingSession { session.stop(); return }
        guard Permissions.ensureScreenRecording() else { return }
        // Drag a region to record (Esc cancels, F or the button = full screen),
        // then show the pre-record options bar (audio/mic/camera/captions/blur).
        RegionSelector.selectRegion(prompt: .init(
            title: "Click and drag",
            subtitle: "to select recording area",
            buttonTitle: "Create a full screen recording")) { [weak self] selection in
            guard let selection else { return }
            self?.presentPreRecord(selection: selection)
        }
    }

    /// Shared pre-record options bar → recording launch (region + full-screen paths).
    private func presentPreRecord(selection: RegionSelection) {
        Task { @MainActor in
            PreRecordPanel.present(selection: selection, settings: self.settings,
                                   onGear: { [weak self] in
                self?.settings.selectedSection = "Recording"
                self?.openSettings()
            }) { [weak self] proceed, blurRects in
                guard let self, proceed else { return }
                // Blur boxes were dragged directly on the panel's overlay.
                self.launchRecording(selection: selection, blurRects: blurRects)
            }
        }
    }

    private func launchRecording(selection: RegionSelection, blurRects: [CGRect]) {
            let session = RecordingSession(selection: selection, settings: self.settings,
                                           url: self.recordingURL(), blurRects: blurRects)
            session.onTick = { [weak self] text in
                self?.statusItem?.button?.title = " \(text)"
            }
            session.onStateChange = { [weak self] in self?.updateRecordingUI() }
            session.onFinished = { [weak self, weak session] url in
                guard let self else { return }
                // A late callback from an old, already-replaced session must not
                // touch the current one (could kill a NEW recording mid-flight).
                guard self.recordingSession === session else { return }
                self.recordingSession = nil
                self.statusItem?.button?.title = ""
                self.updateRecordingUI()
                if let url {
                    self.playSoundIfEnabled()
                    self.presentRecording(url)
                } else if session?.wasDiscarded == false {
                    // Real failure (disk full / capture error) — never silent.
                    Notifier.error("Recording failed",
                                   "The video couldn't be saved (disk full or capture error).")
                }
            }
            self.recordingSession = session
            Task { @MainActor in await session.start() }
    }

    /// Post-recording pipeline: optional on-device captions burned INTO the
    /// video itself (one file — no separate copy), then the preview.
    private func presentRecording(_ url: URL) {
        // Auto-upload: copy into the Google Drive desktop app's sync folder —
        // Google's own app does the actual uploading (SnapDesk stays offline).
        if settings.uploadToDrive {
            DriveUpload.upload(url) { ok in
                if ok {
                    Notifier.info("Uploading to Google Drive",
                                  "Copied to My Drive → SnapDesk Recordings — Drive syncs it now.")
                } else {
                    Notifier.error("Drive upload failed",
                                   "Google Drive folder not found — is the Google Drive app set up?")
                }
            }
        }
        guard settings.recordSubtitles else { RecordingPreviewWindow.show(url); return }
        let langLabel = SettingsStore.captionLanguages.first { $0.1 == settings.captionLanguage }?.0 ?? "English"
        Notifier.info("Adding captions…",
                      "Transcribing on-device (\(langLabel)). The preview opens when ready.")
        Task { @MainActor in
            do {
                let added = try await SubtitleBurner.process(url: url, language: self.settings.captionLanguage)
                if !added { Notifier.info("No speech detected", "Saved without captions.") }
                RecordingPreviewWindow.show(url)
            } catch {
                Notifier.error("Captions failed",
                               "Couldn't transcribe — the recording is saved without captions.")
                RecordingPreviewWindow.show(url)
            }
        }
    }

    /// Called by the app delegate before quitting. Returns true (and later runs
    /// `completion`) when a recording needs to finish writing first.
    func finishActiveRecording(then completion: @escaping () -> Void) -> Bool {
        guard let session = recordingSession else { return false }
        let previous = session.onFinished
        session.onFinished = { url in
            previous?(url)
            completion()
        }
        session.stop()
        return true
    }

    @objc func togglePauseRecording() { recordingSession?.togglePause() }

    @objc func cleanRAM() {
        DeepCleanWindow.show { [weak self] in self?.playSoundIfEnabled() }
    }

    @objc func scrollingCapture() {
        // Toggle: pressing the hotkey mid-capture finishes and stitches.
        if ScrollCapture.isActive {
            Task { @MainActor in ScrollCapture.finishActive() }
            return
        }
        guard Permissions.ensureScreenRecording() else { return }
        RegionSelector.selectRegion { [weak self] selection in
            guard let self, let selection else { return }
            Task { @MainActor in ScrollCapture.begin(selection: selection, settings: self.settings) }
        }
    }

    /// Red dot while recording, normal icon otherwise; rebuild menu for the label.
    private func updateRecordingUI() {
        let recording = recordingSession != nil
        statusItem?.button?.image = recording
            ? MenuBarIcon.recordingImage()
            : MenuBarIcon.image(style: settings.menuBarIconStyle)
        statusItem?.button?.imagePosition = .imageLeft
        if !recording { statusItem?.button?.title = "" }
        statusItem?.menu = buildMenu()
    }

    private func recordingURL() -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // stable digits/format in every locale
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var dir = settings.recordingFolder
        var isDir: ObjCBool = false
        if !(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue) {
            dir = NSHomeDirectory() + "/Desktop"   // chosen folder gone → Desktop
        }
        let base = "SnapDesk Recording \(f.string(from: Date()))"
        var url = URL(fileURLWithPath: dir).appendingPathComponent("\(base).mov")
        var n = 2   // same-second collision → " 2", " 3", … (never overwrite)
        while FileManager.default.fileExists(atPath: url.path) {
            url = URL(fileURLWithPath: dir).appendingPathComponent("\(base) \(n).mov"); n += 1
        }
        return url
    }

    @objc func quit() {
        // applicationShouldTerminate waits for an active recording to finalize.
        NSApp.terminate(nil)
    }

    // MARK: - Feedback


    private func playSoundIfEnabled() {
        guard settings.playSound else { return }
        Sounds.play(settings.soundName)
    }
}
