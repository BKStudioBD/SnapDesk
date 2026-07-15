import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore

    // Single source of truth = settings.selectedSection, so deep-links (Help
    // button, pre-record gear) work every time — a mirrored @State missed
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
    case ocr = "OCR", color = "Color", clipboard = "Clipboard", help = "Help", about = "About"
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
            }
            Section("Menu bar") {
                Picker("Icon style", selection: $settings.menuBarIconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Section("Capture") {
                Picker("Delay before capture", selection: $settings.captureDelaySeconds) {
                    Text("None").tag(0); Text("1 second").tag(1)
                    Text("2 seconds").tag(2); Text("3 seconds").tag(3); Text("5 seconds").tag(5)
                }
                Toggle("Play sound on action", isOn: $settings.playSound)
                HStack {
                    Picker("Sound", selection: $settings.soundName) {
                        ForEach(SettingsStore.soundNames, id: \.self) { Text($0).tag($0) }
                    }
                    Button { Sounds.play(settings.soundName) } label: {
                        Image(systemName: "play.circle.fill")
                    }
                    .buttonStyle(.borderless).help("Test sound")
                }
                .disabled(!settings.playSound)
            }
        }
        .glassForm()
    }
}

// MARK: - Recording

private struct RecordingTab: View {
    @EnvironmentObject var settings: SettingsStore
    // Cached once — MicCapture.devices() is an AVCaptureDevice hardware scan and
    // DriveUpload.isAvailable is disk IO; evaluating them in the body would run
    // on every re-render while Settings is open.
    @State private var micDevices: [AVCaptureDevice] = []
    @State private var driveAvailable = false
    var body: some View {
        Form {
            Section("Video") {
                Picker("Frame rate", selection: $settings.recordFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps — smoothest").tag(60)
                }
                Picker("Quality", selection: $settings.recordQuality) {
                    ForEach(RecordingQuality.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Format", selection: $settings.recordHEVC) {
                    Text("H.264 — plays everywhere").tag(false)
                    Text("HEVC — smaller files").tag(true)
                }
                Toggle("Show mouse cursor", isOn: $settings.recordShowCursor)
            }
            Section("Starting") {
                Picker("Countdown", selection: $settings.recordCountdown) {
                    Text("Off — start instantly").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
            }
            Section("Effects (burned into the video)") {
                Toggle("Big cursor (2×)", isOn: $settings.recordCursorBoost)
                Toggle("Highlight clicks", isOn: $settings.recordClickHighlight)
                Toggle("Show keystrokes", isOn: $settings.recordKeystrokes)
                Toggle("Webcam bubble", isOn: $settings.recordCamera)
            }
            Section("Privacy") {
                Toggle("Blur a region in the video", isOn: $settings.recordBlurEnabled)
                if settings.recordBlurEnabled {
                    Text("After choosing the recording area you'll drag a second area — it stays pixelated in the whole video (Esc skips it).")
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
                }
            }
            Section {
                Toggle("Auto captions — burned into the video", isOn: $settings.recordSubtitles)
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
                             : "Google Drive app not detected — install/sign in to Google Drive first.")
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
                Text("Press \(settings.recordHotkey.displayString), drag a region → record. Press again (or Stop on the bar) to finish; pause/resume from the floating bar. Captions are transcribed on-device (language of your choice) and written straight into the video — one file, nothing separate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .glassForm()
        .onAppear {
            micDevices = MicCapture.devices()
            driveAvailable = DriveUpload.isAvailable
        }
    }

    /// "~/Movies/Recordings" style short path for display.
    private func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
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
                row("Capture & Annotate", $settings.screenshotHotkey)
                row("OCR — Grab Text", $settings.ocrHotkey)
                row("Pick a Color", $settings.colorHotkey)
                row("Clipboard History", $settings.clipboardHotkey)
                row("Record Screen", $settings.recordHotkey)
                row("Scrolling Capture", $settings.scrollHotkey)
            } footer: {
                HStack {
                    Text("Click a shortcut, then press a new combo. Esc cancels.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to defaults") { settings.resetHotkeysToDefault() }
                }
            }
        }
        .glassForm()
    }

    private func row(_ label: String, _ binding: Binding<Hotkey>) -> some View {
        HStack {
            Text(label); Spacer()
            HotkeyRecorder(hotkey: binding, isConflict: { [weak settings] hk in
                guard let s = settings else { return false }
                // Taken by any OTHER action (comparing against current values).
                return [s.screenshotHotkey, s.ocrHotkey, s.colorHotkey,
                        s.clipboardHotkey, s.recordHotkey, s.scrollHotkey]
                    .filter { $0 != binding.wrappedValue }
                    .contains(hk)
            })
            .frame(width: 140, height: 24)
        }
    }
}

// MARK: - Screenshot

private struct ScreenshotTab: View {
    @EnvironmentObject var settings: SettingsStore
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
                    Slider(value: $settings.defaultLineWidth, in: 1...14)
                    Text("\(Int(settings.defaultLineWidth))").monospacedDigit().foregroundStyle(.secondary)
                }
                ColorPicker("Default color", selection: Binding(
                    get: { Color(hex: settings.defaultAnnotationColorHex) },
                    set: { settings.defaultAnnotationColorHex = NSColor($0).hexString() }))
            }
            Section("Saving") {
                Picker("Format", selection: $settings.saveFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                if settings.saveFormat == .jpeg {
                    HStack {
                        Text("JPEG quality")
                        Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                        Text("\(Int(settings.jpegQuality * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Toggle("Auto-save every capture to a folder", isOn: $settings.autoSaveEnabled)
                if settings.autoSaveEnabled {
                    HStack {
                        Text(settings.autoSaveFolder).lineLimit(1).truncationMode(.middle)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
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
    var body: some View {
        Form {
            Section {
                Picker("Copy style", selection: $settings.ocrKeepLineBreaks) {
                    Text("Outline — keep line breaks").tag(true)
                    Text("Inline — one line").tag(false)
                }.pickerStyle(.radioGroup)
            } footer: {
                Text("Inline joins everything into a single line; Outline preserves the on-screen layout.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recognition") {
                Picker("Language", selection: $settings.ocrLanguage) {
                    ForEach(SettingsStore.ocrLanguages, id: \.1) { Text($0.0).tag($0.1) }
                }
                Toggle("Trim surrounding whitespace", isOn: $settings.ocrTrimWhitespace)
                Toggle("Append to existing clipboard text", isOn: $settings.ocrAppend)
                Toggle("Show notification with copied text", isOn: $settings.ocrNotify)
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
                Toggle("Keep sampling (pick multiple)", isOn: $settings.colorContinuous)
                Toggle("Show notification", isOn: $settings.colorNotify)
            }
            Section("Recent colors") {
                if settings.recentColors.isEmpty {
                    Text("No colors picked yet").foregroundStyle(.secondary).font(.caption)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(28)), count: 8), spacing: 8) {
                        ForEach(settings.recentColors, id: \.self) { hex in
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(hex: hex))
                                .frame(width: 26, height: 26)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                                .help(hex)
                                .onTapGesture {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(hex, forType: .string)
                                }
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
            Section("Pasting") {
                Toggle("Click to paste — one click pastes into the previous app", isOn: $settings.doubleClickToPaste)
                Toggle("Activate target app after paste", isOn: $settings.activateAfterPaste)
                    .disabled(!settings.doubleClickToPaste)
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
                    HStack {
                        Text(appLabel(bundleID))
                        Spacer()
                        Button { settings.ignoreApps.removeAll { $0 == bundleID } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.borderless)
                    }
                }
                Button("Add App…", action: chooseApp)
            }
        }
        .glassForm()
    }

    private func appLabel(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url,
           let id = Bundle(url: url)?.bundleIdentifier, !settings.ignoreApps.contains(id) {
            settings.ignoreApps.append(id)
        }
    }
}

// MARK: - Help

private struct HelpTab: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        Form {
            Section("Global shortcuts") {
                key("camera.viewfinder", "Capture & Annotate", settings.screenshotHotkey.displayString)
                key("text.viewfinder", "OCR — Grab Text", settings.ocrHotkey.displayString)
                key("eyedropper", "Pick a Color", settings.colorHotkey.displayString)
                key("doc.on.clipboard", "Clipboard History", settings.clipboardHotkey.displayString)
                key("record.circle", "Record Screen", settings.recordHotkey.displayString)
                key("arrow.up.and.down.text.horizontal", "Scrolling Capture", settings.scrollHotkey.displayString)
            }
            Section("Screen recording") {
                row("Start/Stop", "Press the shortcut, drag a region → 3-2-1 countdown → records. Press again (or Stop on the bar) to finish.")
                row("Full screen", "While selecting, click “Create a full screen recording” — or just press F.")
                row("Control bar", "Timer · pause/resume · stop · ✕ cancel (discard). Pauses are cut from the video.")
                row("Audio", "System audio and/or your microphone (Settings → General).")
                row("Captions", "Optional: captions (English / Spanish / German) transcribed on-device and burned straight into the video.")
                row("Blur", "Optional privacy blur: drag a second area after the recording area — it stays pixelated in the video.")
                row("Preview", "A review window opens when done — Reveal, Delete or Done.")
                row("Saved", "To your chosen video folder — Settings → General → “Save videos to”.")
            }
            Section("Scrolling capture") {
                row("Start", "Menu bar → Scrolling Capture… → select the area.")
                row("Scroll", "Scroll the content slowly; the counter shows captured frames.")
                row("Done", "Stitches everything into one tall image — copied + saved.")
            }
            Section("Cleaner") {
                row("Clean", "One click: force-frees inactive RAM + clears the ticked junk — user caches, temp files, logs, Trash.")
                row("Trash", "“Empty Trash” is permanent — it's never pre-checked.")
                row("Uninstall", "Removes an app AND its leftover files — everything goes to Trash (reversible).")
            }
            Section("Screenshot editor") {
                row("Select", "Drag a region — or click a window to snap to it.")
                row("Tools", "A arrow · L line · R rectangle · O ellipse · P pen · H marker · B blur · N step · T text · S spotlight")
                row("Copy", "⌘C or ↵")
                row("Save", "⌘S    ·    Undo  ⌘Z    ·    Close  Esc")
                row("Color", "Pick a swatch; slider sets stroke width.")
                row("Resize", "Drag the handles around the selection.")
                row("Beautify", "✨ adds a gradient background + shadow, then copies.")
                row("Pin", "📌 floats the shot on your desktop (drag · ⌘C · Esc).")
                row("Loupe", "Magnifier with pixel grid + hex while you drag.")
            }
            Section("Clipboard  (\(settings.clipboardHotkey.displayString))") {
                row("Copy", "Single-click an item → copies it (sound + flash). The window stays open — copy several in a row.")
                row("Paste", "One click → copies AND pastes into the app you came from.")
                row("Star", "⭐ pins an item; pinned survive Clear All.")
                row("Find", "Search box + chips: All / Text / Links / Images / Pinned.")
                row("Types", "Links, colors (swatch), code, images auto-detected.")
                row("More", "Right-click for Copy / Paste / Star / Delete.")
            }
            Section("Color  (\(settings.colorHotkey.displayString))") {
                row("Pick", "Magnified eyedropper; copies in your chosen format.")
                row("Formats", "HEX · RGB · RGBA · HSL · CSS var · SwiftUI · NSColor")
                row("Loop", "“Keep sampling” picks several colors in a row.")
            }
            Section("OCR  (\(settings.ocrHotkey.displayString))") {
                row("Grab", "Drag over text → copied to the clipboard.")
                row("Style", "Inline (one line) or Outline (keep line breaks).")
                row("Language", "Auto-detect or pick a specific language.")
            }
            Section("Good to know") {
                row("Startup", "Launch-at-login keeps SnapDesk ready after a restart.")
                row("Sounds", "Soft custom sound on each action (toggle in General).")
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
            Text(k).font(.callout.weight(.semibold)).frame(width: 70, alignment: .leading)
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
            Text("Version 1.1").foregroundStyle(.secondary)
            Text("Capture · Annotate · OCR · Color · Clipboard\nOne lightweight, on-device menu-bar app.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            Text("No network. Everything stays on your Mac.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(40)
    }
}
