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
        // First OCR by a freshly installed build pays a one-time ~32s model
        // compile. Spend it now, in the background, while nobody's waiting.
        OCRService.warmModelCacheAfterUpdate(options: settings.ocrOptions)

        // Re-register hotkeys whenever the user rebinds one.
        settings.onHotkeysChanged = { [weak self] in self?.registerHotkeys() }
        // Update check and the welcome/permissions window are Settings buttons
        // now, not menu items — the menu stays the capture actions plus Settings.
        settings.onCheckForUpdates = { [weak self] in self?.checkForUpdates() }
        settings.onShowWelcome = { [weak self] in self?.showWelcome() }
        // Text stack lives in the settings object so Settings can switch it; the
        // menu-bar state and the notification are this object's job either way.
        settings.onOCRStackModeChanged = { [weak self] on, carried in
            self?.reportStackMode(on: on, carried: carried)
        }
        settings.onOCRStackChanged = { [weak self] in self?.refreshStatusTitle() }
        registerHotkeys()

        // While the Settings shortcut-recorder is armed, suspend global hotkeys
        // so the combo being pressed is captured instead of firing an action.
        NotificationCenter.default.addObserver(forName: .hotkeyRecordingBegan, object: nil, queue: .main) {
            [weak self] _ in self?.hotkeys.unregisterAll()
        }
        NotificationCenter.default.addObserver(forName: .hotkeyRecordingEnded, object: nil, queue: .main) {
            [weak self] _ in self?.registerHotkeys()
        }

        // Just updated? Say what changed, once.
        showWhatsNewIfUpdated()
        // Opt-in only, and quietly: a launch-time check must never interrupt.
        if settings.autoCheckUpdates { runUpdateCheck(silent: true) }

        // First launch → show the welcome / setup window.
        if !UserDefaults.standard.bool(forKey: "welcomeShown") {
            UserDefaults.standard.set(true, forKey: "welcomeShown")
            DispatchQueue.main.async { [weak self] in self?.showWelcome() }
        }
    }

    func stop() {
        clipboard.stop()
        hotkeys.unregisterAll()
        updateCheck?.cancel()
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.image()
        item.button?.toolTip = "SnapDesk"
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(featureItem("Capture & Annotate", #selector(captureAndAnnotate), settings.screenshotHotkey, "camera.viewfinder"))
        menu.addItem(featureItem("Grab Text (OCR)", #selector(ocrCapture), settings.ocrHotkey, "text.viewfinder"))
        // "Grab again" and the text stack are NOT here on purpose — they live in
        // Settings → OCR with their own switch and shortcuts. Their shortcuts
        // still work globally, and an active stack shows in the menu-bar title
        // (see `refreshStatusTitle`), so a collect mode is never invisible.
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
        // The shortcut TOGGLES: mid-capture it finishes and stitches. Say so,
        // instead of offering "Scrolling Capture…" as if it would start a new one.
        let scrolling = ScrollCapture.isActive
        menu.addItem(featureItem(scrolling ? "Finish Scrolling Capture" : "Scrolling Capture…",
                                 #selector(scrollingCapture), settings.scrollHotkey,
                                 scrolling ? "stop.circle.fill" : "arrow.up.and.down.text.horizontal"))
        menu.addItem(.separator())
        // Everything that isn't a capture action lives in Settings: shortcuts,
        // the update check, and the welcome/permissions window each have a home
        // there. The menu stays what you reach for mid-task.
        menu.addItem(plainItem("Cleaner…", #selector(openCleaner), "sparkles"))
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

    /// Text shown next to the menu-bar icon while a recording runs (nil = none).
    private var recordingTick: String?

    /// The ONE writer of the menu-bar title, so two features can't fight over it.
    /// A running recording's timer wins; otherwise an active text stack shows a
    /// count in the accent colour — the stack has no menu item any more, and a
    /// collect mode you can't see is a collect mode you forget is on. A bullet
    /// stands in until the first grab, so "on but empty" still reads as on.
    private func refreshStatusTitle() {
        guard let button = statusItem?.button else { return }
        if let recordingTick {
            button.attributedTitle = NSAttributedString(string: " \(recordingTick)")
        } else if settings.ocrStackActive {
            let count = settings.ocrStack.count
            button.attributedTitle = NSAttributedString(
                string: count == 0 ? " •" : " \(count)",
                attributes: [.foregroundColor: NSColor.controlAccentColor,
                             .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize,
                                                      weight: .semibold)])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
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
        hotkeys.bind(settings.ocrRepeatHotkey)  { [weak self] in self?.ocrRepeatCapture() }
        hotkeys.bind(settings.ocrStackHotkey)   { [weak self] in self?.ocrToggleStack() }
        statusItem?.menu = buildMenu()
    }

    // MARK: - Actions

    /// True while a freeze-capture is queued/in flight — spamming ⌃1 must not
    /// launch five full multi-display captures.
    private var screenshotInFlight = false
    private var ocrInFlight = false
    private var colorPickInFlight = false
    /// The running update check, so two can't overlap and quit can cancel it.
    private var updateCheck: Task<Void, Never>?

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
                // "Hide desktop icons while capturing" was advertised for THIS flow
                // and never reached it: the cover was raised only by
                // `RegionSelector`, which this flow doesn't use — it freezes every
                // display and the user crops the frozen frame. So the icons (and
                // every filename on the desktop) were baked into the saved and
                // copied image while the switch said they wouldn't be. The hold
                // spans the whole freeze loop: each grab lowers the cover as soon as
                // it has pixels, which would otherwise uncover screens 2..n.
                DesktopCover.raise()
                DesktopCover.hold()
                defer { DesktopCover.release() }
                // `raise()` only orders the windows in. A capture that beats the
                // window server to compositing them contains the very icons the
                // cover exists to hide, so give it a frame or two — and only when
                // there is actually a cover to wait for.
                if DesktopCover.isRaised {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
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

    /// The last area OCR read, kept as a display ID + rect rather than an
    /// NSScreen — those go stale across a display reconfiguration, and re-reading
    /// a stale screen would grab the wrong monitor silently.
    private var lastOCRArea: (displayID: CGDirectDisplayID, rect: CGRect)?

    @objc func ocrCapture() {
        // One OCR at a time — overlapping tasks race on the clipboard and the
        // slower, OLDER selection can overwrite the newer result. Beep rather
        // than swallow: a dead-feeling hotkey reads as a broken app.
        guard !ocrInFlight else { NSSound.beep(); return }
        guard Permissions.ensureScreenRecording() else { return }
        // Spend the user's drag on the work that would otherwise be their wait:
        // loading the recognizer's models (~0.1s once per launch, and the whole
        // ~32s compile if `warmModelCacheAfterUpdate` hasn't run yet) and the
        // shareable-content IPC the capture needs the moment they let go.
        prewarmOCR()
        CaptureService.warmShareableContent()
        // OCR: no full-screen dim — only the dragged area tints dark.
        RegionSelector.selectRegion(dim: .selectionOnly) { [weak self] selection in
            guard let self, let selection else { return }
            // Remember it BEFORE recognizing, so "again" works even on a miss —
            // a bad first read is the most likely reason to want a retry.
            if let displayID = selection.screen.displayID {
                self.lastOCRArea = (displayID, selection.rectInScreenPoints)
            }
            self.runOCR(on: selection)
        }
    }

    /// Re-read the last area with no drag. The winning move for a live-updating
    /// panel — a log line, a build number, a total that just changed.
    @objc func ocrRepeatCapture() {
        guard !ocrInFlight else { NSSound.beep(); return }
        guard let area = lastOCRArea else {
            Notifier.info("No previous area",
                          "Grab text once with \(settings.ocrHotkey.displayString) first — then this repeats it.")
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == area.displayID }) else {
            Notifier.info("That display is gone",
                          "The last area was on a monitor that's no longer connected — grab a new one.")
            return
        }
        guard Permissions.ensureScreenRecording() else { return }
        prewarmOCR()
        runOCR(on: RegionSelection(screen: screen, rectInScreenPoints: area.rect))
    }

    /// The hotkey and the Settings switch both just flip the setting; the
    /// feedback below runs from its callback, so they can never disagree.
    @objc func ocrToggleStack() { settings.ocrStackActive.toggle() }

    // Clearing is a Settings → OCR button now. It needs no notification: the
    // count right beside it drops to "Nothing yet", which is better feedback
    // than a banner for an action taken in a visible panel.

    private func reportStackMode(on: Bool, carried: Int) {
        if on {
            Notifier.info("Text stack on",
                          "Every grab is added to the clipboard instead of replacing it. \(settings.ocrStackHotkey.displayString) turns it off.")
        } else if carried == 0 {
            Notifier.info("Text stack off", "Each grab replaces the clipboard again.")
        } else {
            Notifier.info("Text stack off",
                          "\(carried) grab\(carried == 1 ? "" : "s") stay on the clipboard.")
        }
        refreshStatusTitle()
    }

    private func prewarmOCR() {
        let options = settings.ocrOptions
        Task.detached(priority: .userInitiated) { await OCRService.prewarm(options: options) }
    }

    /// Capture → recognize → clipboard, shared by the drag path and the
    /// repeat-last-area path so both report misses the same way.
    private func runOCR(on selection: RegionSelection) {
        ocrInFlight = true
        Task { @MainActor in
            defer { self.ocrInFlight = false }
            do {
                let image = try await CaptureService.capture(selection)
                let text = try await OCRService.recognizeText(in: image,
                                                             options: self.settings.ocrOptions)
                // Whitespace-only counts as a miss too (with trim off, Vision
                // fragments can join to pure whitespace — "copied nothing").
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.reportOCRMiss(selection: selection, image: image)
                } else {
                    self.deliverOCR(text)
                }
            } catch {
                // localizedDescription here is Vision/ScreenCaptureKit
                // developer text; the log keeps it, the user gets an
                // instruction like every other message in this flow.
                NSLog("SnapDesk: OCR failed — \(error)")
                Notifier.error("OCR failed", "Couldn't read that area — try again.")
            }
        }
    }

    /// Clipboard write + feedback. In stack mode the payload is every grab so
    /// far, so a single paste lands the whole collection in order.
    private func deliverOCR(_ text: String) {
        let stacking = settings.ocrStackActive
        let payload = stacking ? (settings.ocrStack + [text]).joined(separator: "\n") : text
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(payload, forType: .string) {
            // Rare pasteboard-server hiccup: retry once, then be honest
            // instead of showing "Text copied" for a failed copy.
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(payload, forType: .string) else {
                Notifier.error("Copy failed", "Couldn't write to the clipboard — try again.")
                return
            }
        }
        // Only commit to the stack once the clipboard actually took it, so a
        // failed copy can't leave the count ahead of what's pasteable.
        if stacking { settings.ocrStackAppend(text) }
        if settings.ocrNotify {
            // Notification bodies are shown on the LOCK SCREEN and kept in
            // Notification Center, so don't put the recognized text there — an
            // OCR'd password or private message would outlive the copy. A count
            // confirms the grab worked; the text itself is on the clipboard.
            let chars = text.count
            if stacking {
                Notifier.info("Added to text stack (\(settings.ocrStack.count))",
                              "\(chars) character\(chars == 1 ? "" : "s") added.")
            } else {
                Notifier.info("Text copied", "\(chars) character\(chars == 1 ? "" : "s") on the clipboard.")
            }
        }
        playSoundIfEnabled()
    }

    private func reportOCRMiss(selection: RegionSelection, image: CGImage) {
        // A frame with no contrast at all didn't come from the screen the user
        // is looking at — macOS hands out a window-less frame, with NO error,
        // when the Screen Recording grant has lapsed (it re-confirms
        // periodically). Saying "no text found" there blames the user for an
        // OS-side problem they can actually fix.
        let blank = CaptureService.looksBlank(image)
        MissLog.record([
            "rect": "\(Int(selection.rectInScreenPoints.width))x\(Int(selection.rectInScreenPoints.height))pt",
            "px": "\(image.width)x\(image.height)",
            "blankFrame": "\(blank)",
            "preflight": "\(Permissions.hasScreenRecording)",
            "lang": settings.ocrLanguage,
            "engine": settings.ocrEngine.rawValue,
            "customWords": "\(settings.ocrCustomWords.count)",
        ], image: blank ? nil : image)   // blank frames aren't worth saving
        if blank {
            Notifier.error("Nothing on that frame",
                           "macOS handed SnapDesk an empty screen — its Screen Recording access likely lapsed. Quit and reopen SnapDesk, then try again.")
        } else {
            // Notifier beeps by itself when notifications are denied, so a miss
            // is never fully silent. Advise a ROOMIER selection, not a tighter
            // one — the #1 empty result is a strip so thin it clips the glyph
            // tops and bottoms, and "tighter" makes that worse.
            Notifier.info("No text found", "Select a little more around the text — give the line some room top and bottom.")
        }
    }

    @objc func pickColor() {
        // In-flight guard, like the screenshot and OCR paths: the menu item and
        // the global hotkey share a key equivalent, so a press with the status
        // menu open can arrive twice and open two eyedroppers.
        guard !colorPickInFlight else { return }
        colorPickInFlight = true
        ColorPickerService.pick { [weak self] color in
            self?.colorPickInFlight = false
            // nil = user pressed Esc → stop (also ends continuous mode).
            guard let self, let color else { return }
            let value = color.formatted(as: self.settings.colorFormat,
                                        uppercaseHex: self.settings.uppercaseHex)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            self.settings.addRecentColor(color.hexString(uppercase: self.settings.uppercaseHex))
            if self.settings.colorNotify { Notifier.info("Color copied", value) }
            self.playSoundIfEnabled()
        }
    }

    @objc func showClipboard() {
        // Remember the app the user was in so a click-to-paste can target it —
        // but never record SnapDesk itself (⌃4 pressed twice would otherwise
        // paste into our own panel).
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

    @objc func openCleaner() {
        CleanerWindow.show { [weak self] in self?.playSoundIfEnabled() }
    }

    /// Manual check. `silent` is the launch-time path: say nothing when already
    /// up to date or when GitHub is unreachable, because nobody asked.
    @objc func checkForUpdates() { runUpdateCheck(silent: false) }

    private func runUpdateCheck(silent: Bool) {
        guard updateCheck == nil else { return }   // one at a time
        updateCheck = Task { @MainActor in
            defer { self.updateCheck = nil }
            do {
                let release = try await Updater.checkForUpdate()
                self.settings.lastUpdateCheck = Date()
                guard let release else {
                    if !silent {
                        Notifier.info("SnapDesk is up to date", "You're on \(Updater.currentVersion).")
                    }
                    return
                }
                guard self.confirmUpdate(release) else { return }
                Notifier.info("Downloading SnapDesk \(release.version)…", "SnapDesk restarts when it's ready.")
                try await Updater.install(release)
            } catch {
                guard !silent else { return }
                Notifier.error("Update check failed",
                               error.localizedDescription)
            }
        }
    }

    /// Ask before downloading anything. An update replaces the app on disk, so it
    /// is never silent — even with automatic checks on.
    @MainActor
    private func confirmUpdate(_ release: Updater.Release) -> Bool {
        let alert = NSAlert()
        alert.messageText = "SnapDesk \(release.version) is available"
        alert.informativeText = release.notes.isEmpty
            ? "You're on \(Updater.currentVersion). Download and install it now?"
            : String(release.notes.prefix(600))
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.orderFrontRegardless()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// After an update installs and the new build starts, show what changed once.
    private func showWhatsNewIfUpdated() {
        let d = UserDefaults.standard
        guard let installed = d.string(forKey: "update.installedVersion"),
              installed == Updater.currentVersion else { return }
        let notes = d.string(forKey: "update.notes") ?? ""
        d.removeObject(forKey: "update.installedVersion")
        d.removeObject(forKey: "update.notes")
        guard !notes.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "What's new in SnapDesk \(installed)"
        alert.informativeText = String(notes.prefix(1500))
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.orderFrontRegardless()
        alert.runModal()
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
                self?.recordingTick = text
                self?.refreshStatusTitle()
            }
            session.onStateChange = { [weak self] in self?.updateRecordingUI() }
            session.onFinished = { [weak self, weak session] url in
                guard let self else { return }
                // A late callback from an old, already-replaced session must not
                // touch the current one (could kill a NEW recording mid-flight).
                guard self.recordingSession === session else { return }
                self.recordingSession = nil
                self.recordingTick = nil
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
    /// video itself (one file — no separate copy), THEN the Drive copy and the
    /// preview. Captions rewrite the file in place, so uploading must wait for
    /// them — otherwise Drive gets the caption-less version.
    private func presentRecording(_ url: URL) {
        guard settings.recordSubtitles else {
            uploadToDriveIfEnabled(url)
            RecordingPreviewWindow.show(url)
            return
        }
        let langLabel = SettingsStore.captionLanguages.first { $0.1 == settings.captionLanguage }?.0 ?? "English"
        Notifier.info("Adding captions…",
                      "Transcribing on-device (\(langLabel)). The preview opens when ready.")
        Task { @MainActor in
            do {
                let added = try await SubtitleBurner.process(url: url, language: self.settings.captionLanguage)
                if !added { Notifier.info("No speech detected", "Saved without captions.") }
            } catch let e as SubtitleBurner.Err where e == .unavailable {
                Notifier.info("Captions unavailable",
                              "On-device speech for \(langLabel) isn't installed — saved without captions.")
            } catch {
                Notifier.error("Captions failed",
                               "Couldn't transcribe — the recording is saved without captions.")
            }
            // Upload the FINAL file (captioned if it worked), after captions run.
            self.uploadToDriveIfEnabled(url)
            RecordingPreviewWindow.show(url)
        }
    }

    /// Copy the finished recording into the Google Drive desktop app's sync
    /// folder — Google's own app does the uploading, SnapDesk stays offline.
    private func uploadToDriveIfEnabled(_ url: URL) {
        guard settings.uploadToDrive else { return }
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
            : MenuBarIcon.image()
        statusItem?.button?.imagePosition = .imageLeft
        if !recording { recordingTick = nil }
        // Never clear the title directly — the text stack may still own it.
        refreshStatusTitle()
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


    /// Everything this coordinator confirms is content ARRIVING (an OCR grab, a
    /// color, a finished recording, a clean) — so it is always the in-sound.
    private func playSoundIfEnabled() {
        guard settings.playSound else { return }
        Sounds.playIn()
    }
}
