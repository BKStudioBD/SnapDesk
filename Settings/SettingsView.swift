import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore

    // Single source of truth = settings.selectedSection, so deep-links (Help
    // button, pre-record gear) work every time: a mirrored @State missed
    // re-sets to the same value after the user navigated away.
    private var section: Binding<SettingsSection> {
        Binding(
            get: { SettingsSection(rawValue: settings.selectedSection) ?? .general },
            set: { settings.selectedSection = $0.rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: section) {
                item(.general); item(.shortcuts)
                Section("Capture") {
                    item(.screenshot); item(.recording); item(.ocr); item(.color)
                }
                Section("Data") {
                    item(.clipboard)
                }
                Section("About") {
                    item(.help); item(.about)
                }
            }
            .navigationSplitViewColumnWidth(190)
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                detail.padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 480)
        .environmentObject(settings)
    }

    private func item(_ s: SettingsSection) -> some View {
        Label(s.rawValue, systemImage: s.icon).tag(s)
    }

    @ViewBuilder private var detail: some View {
        switch section.wrappedValue {
        case .general:   GeneralTab()
        case .shortcuts: ShortcutsTab()
        case .screenshot: ScreenshotTab()
        case .recording: RecordingTab()
        case .ocr:       OCRTab()
        case .color:     ColorTab()
        case .clipboard: ClipboardTab()
        case .help:      HelpTab()
        case .about:     AboutTab()
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", shortcuts = "Shortcuts", screenshot = "Screenshot"
    case recording = "Recording"
    case ocr = "OCR", color = "Color Picker", clipboard = "Clipboard", help = "Help", about = "About"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .screenshot: "camera.viewfinder"
        case .recording: "record.circle"
        case .ocr: "text.viewfinder"
        case .color: "eyedropper"
        case .clipboard: "doc.on.clipboard"
        case .help: "questionmark.circle"
        case .about: "info.circle"
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch SnapDesk at login", isOn: $settings.launchAtLogin)
                Text("Keeps SnapDesk ready in the menu bar after every restart.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Setup") {
                    Button("Welcome & Permissions…") { settings.onShowWelcome?() }
                }
                Text("The first-run tour, plus live Screen Recording and Accessibility checks with a Grant button for each.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Check for updates on launch", isOn: $settings.autoCheckUpdates)
                LabeledContent("Version") {
                    HStack(spacing: 10) {
                        Text(Updater.currentVersion).monospacedDigit().foregroundStyle(.secondary)
                        Button("Check Now") { checkNow() }
                    }
                }
                if let last = settings.lastUpdateCheck {
                    LabeledContent("Last checked") {
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Reads the public releases list on GitHub. Nothing is sent, no identifiers, no telemetry. This is the ONLY thing in SnapDesk that touches the network, which is why it's off unless you turn it on. An update always asks before it downloads, and is installed only if it's signed by the same identity as the copy you're running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Capture") {
                Picker("Delay before Capture & Annotate", selection: $settings.captureDelaySeconds) {
                    Text("None").tag(0); Text("1 second").tag(1)
                    Text("2 seconds").tag(2); Text("3 seconds").tag(3); Text("5 seconds").tag(5)
                }
                Text("Time to arrange windows after pressing \(settings.screenshotHotkey.displayString). Only Capture & Annotate waits. OCR, scrolling capture and recording start right away.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Play sound on action", isOn: $settings.playSound)
                LabeledContent("Sounds") {
                    HStack(spacing: 12) {
                        Button("In", systemImage: "play.circle.fill") { Sounds.playIn() }
                            .help("Plays when something is captured or copied")
                        Button("Out", systemImage: "play.circle") { Sounds.playOut() }
                            .help("Plays when something is pasted into another app")
                    }
                    .buttonStyle(.borderless)
                }
                .disabled(!settings.playSound)
                Text("Two sounds, two meanings: a rising pair when content comes in (capture, copy, save), its falling mirror when it goes out (paste).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .glassForm()
    }

    /// The coordinator owns the check (it shows the alert and the notification).
    /// It hands Settings a closure at launch: `NSApp.sendAction(to: nil)` would
    /// walk a responder chain the coordinator isn't part of and quietly do
    /// nothing.
    private func checkNow() {
        settings.onCheckForUpdates?()
    }
}

/// "~/Movies/Recordings" style short path: shared by every folder row.
private func displayPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

// MARK: - Recording

private struct RecordingTab: View {
    @EnvironmentObject var settings: SettingsStore
    // Cached once: MicCapture.devices() is an AVCaptureDevice hardware scan and
    // DriveUpload.isAvailable is disk IO; evaluating them in the body would run
    // on every re-render while Settings is open.
    @State private var micDevices: [AVCaptureDevice] = []
    @State private var driveAvailable = false
    var body: some View {
        Form {
            Section {
                LabeledContent("Preset") {
                    HStack(spacing: 8) {
                        ForEach(RecordingPreset.allCases) { preset in
                            Button(preset.rawValue) { settings.apply(preset) }
                                .help(preset.summary)
                        }
                    }
                }
            } footer: {
                Text("Sets frame rate, audio, camera, captions and the presenter effects in one click. Your output folder, codec, quality, countdown, blur and noise cancellation are left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Video") {
                Picker("Frame rate", selection: $settings.recordFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps (smoothest)").tag(60)
                }
                Picker("Quality", selection: $settings.recordQuality) {
                    ForEach(RecordingQuality.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Format", selection: $settings.recordHEVC) {
                    Text("H.264 (plays everywhere)").tag(false)
                    Text("HEVC (smaller files)").tag(true)
                }
                Toggle("Show mouse cursor", isOn: $settings.recordShowCursor)
            }
            Section("Starting") {
                Picker("Countdown", selection: $settings.recordCountdown) {
                    Text("Off (start instantly)").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
            }
            Section("Effects (burned into the video)") {
                Toggle("Big cursor (2×)", isOn: $settings.recordCursorBoost)
                Toggle("Highlight clicks", isOn: $settings.recordClickHighlight)
                Toggle("Show keystrokes", isOn: $settings.recordKeystrokes)
                Toggle("Webcam bubble", isOn: $settings.recordCamera)
                if settings.recordCamera {
                    Picker("Bubble corner", selection: $settings.cameraCorner) {
                        ForEach(CameraCorner.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Bubble size", selection: $settings.cameraSize) {
                        ForEach(CameraSize.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Mirror me (like a mirror)", isOn: $settings.cameraMirrored)
                    Text("The live bubble on screen and the one burned into the video always match. Same corner, same size, same mirroring.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Privacy") {
                Toggle("Blur a region in the video", isOn: $settings.recordBlurEnabled)
                if settings.recordBlurEnabled {
                    Text("After choosing the recording area you'll drag a second area. It stays pixelated in the whole video (Esc skips it).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Audio") {
                Toggle("Capture system audio", isOn: $settings.recordSystemAudio)
                Toggle("Record microphone (your voice)", isOn: $settings.recordMic)
                if settings.recordMic {
                    Picker("Microphone", selection: $settings.micDeviceID) {
                        Text("System default").tag("")
                        ForEach(micDevices, id: \.uniqueID) { d in
                            Text(d.localizedName).tag(d.uniqueID)
                        }
                    }
                    Toggle("Noise cancellation", isOn: $settings.recordNoiseCancellation)
                    Text("Apple's voice processing. Suppresses room noise, keyboard clatter and echo, and evens out your level. Same processing FaceTime uses, entirely on-device. Turn it off for music or to capture the room as-is.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Auto captions (burned into the video)", isOn: $settings.recordSubtitles)
                if settings.recordSubtitles {
                    Picker("Caption language (what you speak)", selection: $settings.captionLanguage) {
                        ForEach(SettingsStore.captionLanguages, id: \.1) { Text($0.0).tag($0.1) }
                    }
                }
                Toggle(isOn: $settings.uploadToDrive) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-upload to Google Drive")
                        Text(driveAvailable
                             ? "Copies finished recordings into My Drive → SnapDesk Recordings; the Google Drive app syncs them."
                             : "Google Drive app not detected. Install/sign in to Google Drive first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!driveAvailable && !settings.uploadToDrive)
                HStack {
                    Text("Save videos to")
                    Spacer()
                    Text(displayPath(settings.recordingFolder))
                        .lineLimit(1).truncationMode(.middle)
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Choose…", action: chooseRecordingFolder)
                }
            } header: {
                Text("After recording")
            } footer: {
                Text("Press \(settings.recordHotkey.displayString), drag a region → record. Press again (or Stop on the bar) to finish; pause/resume from the floating bar. Captions are transcribed on-device (language of your choice) and written straight into the video. One file, nothing separate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .glassForm()
        // Both off the main thread. `DriveUpload.isAvailable` enumerates
        // ~/Library/CloudStorage, and those are FileProvider mounts: when Google
        // Drive isn't running, or is still signing in, that `stat` blocks for
        // SECONDS, which froze the whole Settings window the moment this tab
        // opened. The mic scan is hardware discovery and belongs off main for the
        // same reason. `.task` also cancels itself if the tab goes away first.
        .task {
            micDevices = await BackgroundWork.run { MicCapture.devices() }
            driveAvailable = await BackgroundWork.run { DriveUpload.isAvailable }
        }
    }

    private func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.recordingFolder)
        if panel.runModal() == .OK, let url = panel.url {
            FolderAccess.remember(url, key: "recdir")   // sandbox: keep access
            settings.recordingFolder = url.path
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsTab: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        Form {
            Section {
                HotkeyRow("Capture & Annotate", $settings.screenshotHotkey)
                HotkeyRow("Grab Text (OCR)", $settings.ocrHotkey)
                HotkeyRow("Grab Text Again (OCR)", $settings.ocrRepeatHotkey)
                HotkeyRow("Text Stack On/Off (OCR)", $settings.ocrStackHotkey)
                HotkeyRow("Pick a Color", $settings.colorHotkey)
                HotkeyRow("Clipboard History", $settings.clipboardHotkey)
                HotkeyRow("Record Screen", $settings.recordHotkey)
                HotkeyRow("Scrolling Capture", $settings.scrollHotkey)
            } footer: {
                HStack {
                    Text("Click a shortcut, then press a new combo. Esc cancels. Every shortcut also appears in the pane for the feature it belongs to.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to defaults") { settings.resetHotkeysToDefault() }
                }
            }
        }
        .glassForm()
    }
}

/// One rebindable shortcut: label + recorder, sharing the conflict rule with
/// every pane that shows a shortcut. So a feature's own pane can offer its
/// binding without the Shortcuts list and the feature pane drifting apart.
private struct HotkeyRow: View {
    @EnvironmentObject var settings: SettingsStore
    private let label: String
    @Binding private var hotkey: Hotkey

    init(_ label: String, _ hotkey: Binding<Hotkey>) {
        self.label = label
        self._hotkey = hotkey
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            HotkeyRecorder(hotkey: $hotkey, isConflict: { [weak settings] hk in
                guard let s = settings else { return false }
                // Taken by any OTHER action (comparing against current values).
                return s.allHotkeys.filter { $0 != hotkey }.contains(hk)
            })
            .frame(width: 140, height: 24)
        }
    }
}

// MARK: - Screenshot

private struct ScreenshotTab: View {
    @EnvironmentObject var settings: SettingsStore
    /// Local while the colour panel is being dragged; written to the store once
    /// the drag settles.
    @State private var defaultColor: Color = .red
    @State private var colorWrite: Task<Void, Never>?
    private let tools: [(Int, String)] = [
        (0, "Arrow"), (1, "Rectangle"), (2, "Ellipse"), (3, "Line"),
        (4, "Pen"), (5, "Highlighter"), (6, "Blur"), (7, "Step"), (8, "Text"), (9, "Spotlight"),
    ]
    var body: some View {
        Form {
            Section("Annotation defaults") {
                Picker("Default tool", selection: $settings.defaultTool) {
                    ForEach(tools, id: \.0) { Text($0.1).tag($0.0) }
                }
                HStack {
                    Text("Stroke width")
                    // The Text beside it is not the slider's label as far as
                    // VoiceOver is concerned: unlabelled, it announced a bare
                    // percentage with no clue what it controlled.
                    Slider(value: $settings.defaultLineWidth, in: 1...14)
                        .accessibilityLabel("Stroke width")
                        .accessibilityValue("\(Int(settings.defaultLineWidth)) points")
                    Text("\(Int(settings.defaultLineWidth))").monospacedDigit().foregroundStyle(.secondary)
                }
                // The live drag stays local. Bound straight to the store, every
                // frame of a drag in the colour panel wrote UserDefaults and
                // fired objectWillChange, re-rendering the whole Settings
                // window, sidebar included, while the pointer moved.
                ColorPicker("Default color", selection: $defaultColor)
                    .onAppear { defaultColor = Color(hex: settings.defaultAnnotationColorHex) }
                    .onChange(of: defaultColor) {
                        // Debounced: the store's didSet writes UserDefaults and
                        // publishes, so an undebounced write re-rendered the
                        // whole window on every frame of the drag.
                        colorWrite?.cancel()
                        colorWrite = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            guard !Task.isCancelled else { return }
                            let hex = NSColor(defaultColor).hexString()
                            if hex != settings.defaultAnnotationColorHex {
                                settings.defaultAnnotationColorHex = hex
                            }
                        }
                    }
            }
            Section("Saving") {
                Picker("Format", selection: $settings.saveFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                if settings.saveFormat == .jpeg {
                    HStack {
                        Text("JPEG quality")
                        Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                            .accessibilityLabel("JPEG quality")
                            .accessibilityValue("\(Int(settings.jpegQuality * 100)) percent")
                        Text("\(Int(settings.jpegQuality * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Toggle("Auto-save every capture to a folder", isOn: $settings.autoSaveEnabled)
                // The folder row stays VISIBLE with the toggle off: scrolling
                // captures always save here, so hiding it left the user unable to
                // see or change where those files land.
                HStack {
                    Text(displayPath(settings.autoSaveFolder)).lineLimit(1).truncationMode(.middle)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                }
                Text(settings.autoSaveEnabled
                     ? "Every capture and every scrolling capture is saved here."
                     : "Captures are copy-only, but scrolling captures still save to this folder.")
                    .font(.caption).foregroundStyle(.secondary)

                Divider()
                Toggle("Hide desktop icons while capturing", isOn: $settings.hideDesktopDuringCapture)
                // Says "most" on purpose. A wallpaper set to Center or Tile is left
                // alone: macOS reports both as the same scaling mode, so redrawing it
                // would risk putting pixels in the file that were never on screen.
                Text("Covers the desktop with your wallpaper for the length of the capture, so files on the desktop stay out of the shot. Works on most wallpaper styles. A centred or tiled desktop is left as it is.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .glassForm()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            FolderAccess.remember(url, key: "shotdir")  // sandbox: keep access
            settings.autoSaveFolder = url.path
        }
    }
}

// MARK: - OCR

private struct OCRTab: View {
    @EnvironmentObject var settings: SettingsStore

    /// Vision's own language list, plus the saved code if a system update
    /// dropped it. Otherwise the picker would render blank on that value.
    private var languages: [(String, String)] {
        let list = SettingsStore.ocrLanguages
        guard !list.contains(where: { $0.1 == settings.ocrLanguage }) else { return list }
        return list + [(settings.ocrLanguage, settings.ocrLanguage)]
    }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $settings.ocrEngine) {
                    ForEach(OCREngine.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Language", selection: $settings.ocrLanguage) {
                    ForEach(languages, id: \.1) { Text($0.0).tag($0.1) }
                }
                HotkeyRow("Grab text", $settings.ocrHotkey)
            } header: {
                Text("Recognition")
            } footer: {
                // Keep footers to ONE short line. A settings pane is 480pt tall;
                // a paragraph here pushes the next section below the fold, and a
                // control the user has to scroll to find reads as missing.
                // Long explanations belong in Settings → Help.
                Text("Automatic uses macOS Live Text, falling back to the detailed pass.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Code mode (don't autocorrect identifiers)", isOn: $settings.ocrCodeMode)
                Toggle("Table mode (tab-separate columns)", isOn: $settings.ocrTableMode)
            } header: {
                Text("Special layouts")
            } footer: {
                Text("Code mode turns the language model off, so getUserById() and --no-cache come back intact instead of being rewritten into English words. Table mode splits columns with tabs. It only triggers on a real grid (repeating column edges), so ordinary sentences are never turned into tabs. Both use the detailed engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HotkeyRow("Grab the last area again", $settings.ocrRepeatHotkey)
            } header: {
                Text("Grab again")
            } footer: {
                Text("Re-reads the last area with no drag.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Collect grabs into one clipboard", isOn: $settings.ocrStackActive)
                HotkeyRow("Turn the stack on or off", $settings.ocrStackHotkey)
                LabeledContent("Collected") {
                    HStack(spacing: 10) {
                        Text(settings.ocrStack.isEmpty ? "Nothing yet" : "\(settings.ocrStack.count) grabs")
                            .foregroundStyle(.secondary)
                        Button("Clear") { settings.ocrStackClear() }
                            .disabled(settings.ocrStack.isEmpty)
                    }
                }
            } header: {
                Text("Text stack")
            } footer: {
                Text("One paste lands the whole collection. Always starts off after a launch.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Copy style", selection: $settings.ocrKeepLineBreaks) {
                    Text("Outline (keep line breaks)").tag(true)
                    Text("Inline (one line)").tag(false)
                }.pickerStyle(.radioGroup)
                Toggle("Separate paragraphs with a blank line", isOn: $settings.ocrParagraphBreaks)
                    .disabled(!settings.ocrKeepLineBreaks)
                Toggle("Trim surrounding whitespace", isOn: $settings.ocrTrimWhitespace)
                Toggle("Show notification with copied text", isOn: $settings.ocrNotify)
            } header: {
                Text("Copy style")
            } footer: {
                Text("Paragraph spacing is measured from the real line gaps.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Words to favour", text: $settings.ocrCustomWordsText, axis: .vertical)
                    .lineLimit(2...4)
                LabeledContent("In the list") {
                    Text(settings.ocrCustomWords.isEmpty ? "None"
                         : "\(settings.ocrCustomWords.count) word\(settings.ocrCustomWords.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Custom words")
            } footer: {
                Text("One per line, or comma-separated. Forces the detailed engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .glassForm()
    }
}

// MARK: - Color

private struct ColorTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Copy") {
                Picker("Format", selection: $settings.colorFormat) {
                    ForEach(ColorFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Uppercase hex", isOn: $settings.uppercaseHex)
                    .disabled(settings.colorFormat != .hex)
                Toggle("Show notification", isOn: $settings.colorNotify)
            }
            Section("Recent colors") {
                if settings.recentColors.isEmpty {
                    Text("No colors picked yet").foregroundStyle(.secondary).font(.caption)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(28)), count: 8), spacing: 8) {
                        ForEach(settings.recentColors, id: \.self) { hex in
                            // A real Button, not onTapGesture: VoiceOver can reach
                            // and describe it, and it gives the same copy feedback
                            // every other copy action gives.
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(hex, forType: .string)
                                if settings.playSound { Sounds.playIn() }
                            } label: {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(hex: hex))
                                    .frame(width: 26, height: 26)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                            }
                            .buttonStyle(.plain)
                            .help("Copy \(hex)")
                            .accessibilityLabel("Copy color \(hex)")
                        }
                    }
                }
            }
        }
        .glassForm()
    }
}

// MARK: - Clipboard

private struct ClipboardTab: View {
    @EnvironmentObject var settings: SettingsStore
    /// bundle id → display name, resolved once per list change. Doing it in
    /// `body` meant a LaunchServices query plus a `displayName` disk read for
    /// every ignored app on every re-render. And this tab re-renders on ANY
    /// change published by the store, including a colour drag two panes away.
    @State private var appLabels: [String: String] = [:]
    var body: some View {
        Form {
            Section("History") {
                Toggle("Enable clipboard history", isOn: $settings.clipboardEnabled)
                Toggle("Store copied images", isOn: $settings.clipboardStoreImages)
                Toggle("Reject duplicates", isOn: $settings.rejectDuplicates)
                Stepper("Keep last \(settings.clipboardMaxItems) items",
                        value: $settings.clipboardMaxItems, in: 20...500, step: 10)
            }
            Section("Auto-clean") {
                Picker("Auto-delete unpinned items", selection: $settings.autoDeleteHours) {
                    Text("Never").tag(0); Text("After 1 hour").tag(1)
                    Text("After 1 day").tag(24); Text("After 1 week").tag(168)
                }
                Toggle("Lock starred (pinned) items", isOn: $settings.lockPinned)
                Toggle("Clear history when SnapDesk quits", isOn: $settings.clearOnQuit)
            }
            Section {
                Toggle("Activate target app after paste", isOn: $settings.activateAfterPaste)
            } header: {
                Text("Pasting")
            } footer: {
                Text("In the history window: one click pastes into the app you came from, a double-click only copies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Ignore passwords & secrets", isOn: $settings.ignoreSecrets)
                Toggle("Ignore Universal Clipboard (Handoff)", isOn: $settings.ignoreUniversalClipboard)
            } footer: {
                Text("When ON, items apps mark as concealed (passwords, OTP codes, and other secrets) never enter the history. Keep this on for safety.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignored applications") {
                if settings.ignoreApps.isEmpty {
                    Text("Copies from these apps are never saved.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(settings.ignoreApps, id: \.self) { bundleID in
                    let label = appLabels[bundleID] ?? bundleID
                    HStack {
                        Text(label)
                        Spacer()
                        Button { settings.ignoreApps.removeAll { $0 == bundleID } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(label) from the ignore list")
                        .help("Remove from list")
                    }
                }
                Button("Add App…", action: chooseApp)
            }
        }
        .glassForm()
        // Off the main thread, and only when the list actually changes: same
        // reason the Recording pane moved its mic scan and Drive check off it.
        .task(id: settings.ignoreApps) {
            let ids = settings.ignoreApps
            appLabels = await BackgroundWork.run { Self.resolveLabels(ids) }
        }
    }

    private static func resolveLabels(_ bundleIDs: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for id in bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            else { continue }   // app uninstalled → the bundle id itself is the label
            out[id] = FileManager.default.displayName(atPath: url.path)
        }
        return out
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A bundle with no identifier (a wrapped script, a broken .app) can't be
        // matched against a copy's source, so it can't be ignored. Saying so
        // beats an Add button that silently does nothing.
        guard let id = Bundle(url: url)?.bundleIdentifier else {
            Notifier.error("Can't ignore that app",
                           "\(url.deletingPathExtension().lastPathComponent) has no bundle identifier, so SnapDesk can't tell its copies apart.")
            return
        }
        guard !settings.ignoreApps.contains(id) else { return }   // already listed, visibly
        settings.ignoreApps.append(id)
    }
}

// MARK: - Help

private struct HelpTab: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        Form {
            Section("Global shortcuts") {
                key("camera.viewfinder", "Capture & Annotate", settings.screenshotHotkey.displayString)
                key("text.viewfinder", "Grab Text (OCR)", settings.ocrHotkey.displayString)
                key("arrow.clockwise.circle", "Grab Text Again (OCR)", settings.ocrRepeatHotkey.displayString)
                key("square.stack.3d.up", "Text Stack On/Off (OCR)", settings.ocrStackHotkey.displayString)
                key("eyedropper", "Pick a Color", settings.colorHotkey.displayString)
                key("doc.on.clipboard", "Clipboard History", settings.clipboardHotkey.displayString)
                key("record.circle", "Record Screen", settings.recordHotkey.displayString)
                key("arrow.up.and.down.text.horizontal", "Scrolling Capture", settings.scrollHotkey.displayString)
            }
            Section("Screen recording") {
                row("Start/Stop", "Press the shortcut, drag a region → 3-2-1 countdown → records. Press again (or Stop on the bar) to finish.")
                row("Full screen", "While selecting, click “Create a full screen recording”. Or just press F.")
                row("Control bar", "Timer · pause/resume · stop · ✕ cancel (discard). Pauses are cut from the video.")
                row("Preset", "Tutorial / Meeting / Silent demo set frame rate, audio, camera, captions and effects in one click (Settings → Recording).")
                row("Audio", "System audio and/or your microphone, with Apple noise cancellation on your voice (Settings → Recording).")
                row("Captions", "Optional: captions (English / Spanish / German) transcribed on-device and burned straight into the video.")
                row("Webcam", "Bubble corner, size and mirroring are configurable; the live preview always matches the video.")
                row("Blur", "Optional privacy blur: drag a second area after the recording area. It stays pixelated in the video.")
                row("Preview", "A review window opens when done. Reveal, Delete or Done.")
                row("Saved", "To your chosen video folder. Settings → Recording → “Save videos to”.")
            }
            Section("Scrolling capture") {
                row("Start", "Menu bar → Scrolling Capture… → select the area.")
                row("Scroll", "Scroll the content slowly; the counter shows captured frames.")
                row("Done", "Stitches everything into one tall image. Copied + saved.")
            }
            Section("Screenshot editor") {
                row("Select", "Drag a region, or click a window to snap to it.")
                row("Tools", "A arrow · L line · R rectangle · O ellipse · P pen · H marker · B blur · N step · T text · S spotlight")
                row("Copy", "⌘C or ↵")
                row("Grab text", "⌘⇧T (or the text button) reads the TEXT out of the shot instead of copying pixels.")
                row("Repeat", "⌘⇧R re-arms the last annotation's tool, colour and width. Five arrows in a row without re-picking.")
                row("Save", "⌘S    ·    Undo  ⌘Z    ·    Close  Esc")
                row("Color", "Pick a swatch; slider sets stroke width.")
                row("Resize", "Drag the handles around the selection.")
                row("Beautify", "✨ adds a gradient background + shadow, then copies.")
                row("Pin", "📌 floats the shot on your desktop (drag · ⌘C · Esc).")
                row("Loupe", "Magnifier with pixel grid + hex while you drag.")
            }
            Section("Clipboard  (\(settings.clipboardHotkey.displayString))") {
                row("Paste", "ONE click on an item → copies it AND pastes it into the app you came from; the window closes. The list keeps its order, so the row you just used stays where it was.")
                row("Copy", "DOUBLE-click → copies only, no paste, and moves the item to the top as the newest copy. The window stays open, so you can collect several in a row.")
                row("Keyboard", "↑ ↓ move the selection · ↵ pastes it · ⌘1–⌘9 paste that numbered row directly · ⌘⌫ deletes. Just type to filter. Esc closes.")
                row("Line breaks", "A trailing line break is stripped on the way out, so a paste lands where your cursor is instead of dropping to the next line. Line breaks INSIDE the text are kept.")
                row("Star", "⭐ pins an item; pinned survive Clear All.")
                row("Find", "Search box + chips: All / Text / Links / Images / Pinned.")
                row("Types", "Links, colors (swatch), code, images auto-detected.")
                row("Copy as", "Right-click → Copy as: strip line breaks, trim lines, case changes, slug, URL-decode, pretty-print JSON. The stored item is never rewritten. Only what you paste this once.")
                row("More", "Right-click for Copy / Paste / Star / Delete.")
            }
            Section("Color Picker  (\(settings.colorHotkey.displayString))") {
                row("Pick", "Magnified eyedropper; copies in your chosen format.")
                row("Formats", "HEX or RGB, set in Settings → Color.")
                row("Recent", "Settings → Color keeps the last 16 picks. Click a swatch to copy it again.")
            }
            Section("OCR  (\(settings.ocrHotkey.displayString))") {
                row("Grab", "Drag over text → copied to the clipboard.")
                row("Again", "\(settings.ocrRepeatHotkey.displayString) re-reads the LAST area with no drag. Good for a value that keeps changing. Settings → OCR → Grab again.")
                row("Stack", "\(settings.ocrStackHotkey.displayString). Or the switch in Settings → OCR → Text stack. Collects several grabs into one clipboard payload. It starts off every launch, and while it's on the menu bar shows a count beside the icon.")
                row("Style", "Inline (one line) or Outline (keep line breaks, optional blank line between paragraphs).")
                row("Engine", "Automatic reads with macOS Live Text first. It follows columns and wrapped paragraphs in the right order, and falls back to the detailed word-by-word pass when Live Text finds nothing. Detailed always uses that pass: small text, thin strips and busy regions get an upscale, a bigger retry, then overlapping tiles before SnapDesk gives up.")
                row("Language", "Auto-detect or pick any language this macOS can recognize.")
                row("Code mode", "Turns the language model off so getUserById() and --no-cache survive instead of being rewritten.")
                row("Table mode", "Tab-separates real columns so a table pastes into a spreadsheet as cells. Only fires on a genuine grid. Sentences are never turned into tabs.")
                row("Custom words", "Names, jargon and identifiers the recognizer would otherwise autocorrect into something else (Settings → OCR). While the list has entries, recognition uses the detailed engine. Live Text can't be given custom words.")
            }
            Section("Cleaner  (menu bar → Cleaner…)") {
                row("Dashboard", "Live processor, memory, disk and network, a 0–100 health score, and one button that frees inactive memory.")
                row("Clean", "Caches grouped by Browsers / Apps / System, each sized. Tick a group from its header; the button says how much it will free. Anything written in the last 10 minutes is skipped. That file is still in use.")
                row("Safety", "Everything goes to the Trash, so a wrong tick is undoable. Emptying the Trash is the one permanent action, and it is never pre-ticked.")
            }
            Section("Good to know") {
                row("Startup", "Launch-at-login keeps SnapDesk ready after a restart.")
                row("Sounds", "Two custom sounds: a rising pair when content comes IN (capture, copy, save), a falling one when it goes OUT (paste). Toggle in General.")
                row("Privacy", "100% on-device. Passwords & secrets are never saved.")
            }
        }
        .glassForm()
    }

    private func key(_ icon: String, _ title: String, _ combo: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(combo).font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.08)))
        }
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // minWidth, not a fixed 70: "Control bar", "Custom words" and
            // "Table mode" all wrapped onto two lines against a single-line
            // value, and a fixed point width ignores the system text size.
            Text(k).font(.callout.weight(.semibold))
                .frame(minWidth: 96, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(v).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "viewfinder")
                .font(.system(size: 46)).foregroundStyle(.tint)
            Text("SnapDesk").font(.title.bold())
            // Read from the bundle, like the Updates section does: a hardcoded
            // string here goes stale on the next version bump and disagrees
            // with what the updater reports.
            Text("Version \(Updater.currentVersion)").foregroundStyle(.secondary)
            Text("Capture · Annotate · OCR · Color · Clipboard\nOne lightweight, on-device menu-bar app.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            Text("No network. Everything stays on your Mac.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(40)
    }
}
