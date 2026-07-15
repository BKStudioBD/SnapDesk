import AppKit
import Combine
import Carbon.HIToolbox
import ServiceManagement

/// Output image format for saved/exported screenshots.
enum ImageFormat: String, CaseIterable, Identifiable {
    case png = "PNG"
    case jpeg = "JPEG"
    var id: String { rawValue }
}

/// Recording quality preset → bits-per-pixel budget (nil = encoder default).
enum RecordingQuality: String, CaseIterable, Identifiable {
    case high = "High", medium = "Medium", low = "Low"
    var id: String { rawValue }
    /// Bits per pixel per frame; bitrate = w × h × fps × bpp.
    var bitsPerPixel: Double? {
        switch self {
        case .high: nil          // let the encoder pick (best quality)
        case .medium: 0.10
        case .low: 0.05
        }
    }
}

/// All user preferences, persisted to UserDefaults. Each property writes itself
/// on change (`didSet`). Hotkey changes fire `onHotkeysChanged`; the menu-bar
/// icon style fires `onMenuBarStyleChanged` — both update live, no relaunch.
final class SettingsStore: ObservableObject {
    private let d = UserDefaults.standard

    /// Called whenever any hotkey changes (set by AppCoordinator).
    var onHotkeysChanged: (() -> Void)?
    /// When true, hotkey `didSet` skips the re-register callback — used to
    /// batch a multi-key change (e.g. reset-to-defaults) into one re-register
    /// instead of six.
    private var suppressHotkeyCallback = false
    /// Called when the menu-bar icon style changes.
    var onMenuBarStyleChanged: (() -> Void)?
    /// Transient nav state — which Settings section to show (deep-links Help).
    @Published var selectedSection: String = "General"

    // MARK: Hotkeys (rebindable)
    @Published var screenshotHotkey: Hotkey { didSet { saveHotkey(screenshotHotkey, "hk.shot"); fireHotkeysChanged() } }
    @Published var ocrHotkey: Hotkey        { didSet { saveHotkey(ocrHotkey, "hk.ocr"); fireHotkeysChanged() } }
    @Published var colorHotkey: Hotkey      { didSet { saveHotkey(colorHotkey, "hk.color"); fireHotkeysChanged() } }
    @Published var clipboardHotkey: Hotkey  { didSet { saveHotkey(clipboardHotkey, "hk.clip"); fireHotkeysChanged() } }
    @Published var recordHotkey: Hotkey     { didSet { saveHotkey(recordHotkey, "hk.record"); fireHotkeysChanged() } }
    @Published var scrollHotkey: Hotkey     { didSet { saveHotkey(scrollHotkey, "hk.scroll"); fireHotkeysChanged() } }

    private func fireHotkeysChanged() {
        guard !suppressHotkeyCallback else { return }
        onHotkeysChanged?()
    }

    // MARK: Recording
    @Published var recordSystemAudio: Bool  { didSet { d.set(recordSystemAudio, forKey: "rec.audio") } }
    @Published var recordMic: Bool          { didSet { d.set(recordMic, forKey: "rec.mic") } }
    /// AVCaptureDevice.uniqueID; "" = system default microphone.
    @Published var micDeviceID: String      { didSet { d.set(micDeviceID, forKey: "rec.micID") } }
    @Published var recordSubtitles: Bool    { didSet { d.set(recordSubtitles, forKey: "rec.subs") } }
    @Published var uploadToDrive: Bool      { didSet { d.set(uploadToDrive, forKey: "rec.gdrive") } }
    /// Speech-recognition locale for burned-in captions (the language you SPEAK).
    @Published var captionLanguage: String  { didSet { d.set(captionLanguage, forKey: "rec.capLang") } }

    /// Caption languages offered in Recording settings.
    static let captionLanguages: [(String, String)] = [
        ("English", "en-US"), ("Spanish", "es-ES"), ("German", "de-DE"),
    ]
    /// Where finished recordings (.mov) are saved.
    @Published var recordingFolder: String  { didSet { d.set(recordingFolder, forKey: "rec.dir") } }
    @Published var recordFPS: Int           { didSet { d.set(recordFPS, forKey: "rec.fps") } }
    @Published var recordQuality: RecordingQuality { didSet { d.set(recordQuality.rawValue, forKey: "rec.quality") } }
    /// true = HEVC/H.265 (smaller files), false = H.264 (max compatibility).
    @Published var recordHEVC: Bool         { didSet { d.set(recordHEVC, forKey: "rec.hevc") } }
    @Published var recordShowCursor: Bool   { didSet { d.set(recordShowCursor, forKey: "rec.cursor") } }
    /// Countdown seconds before recording starts (0 = start instantly).
    @Published var recordCountdown: Int     { didSet { d.set(recordCountdown, forKey: "rec.countdown") } }
    /// Ask for a blur region after selecting the recording area; that region
    /// stays pixelated in the whole video (privacy).
    @Published var recordBlurEnabled: Bool  { didSet { d.set(recordBlurEnabled, forKey: "rec.blur") } }
    @Published var recordCursorBoost: Bool  { didSet { d.set(recordCursorBoost, forKey: "rec.cursorBoost") } }
    @Published var recordClickHighlight: Bool { didSet { d.set(recordClickHighlight, forKey: "rec.clicks") } }
    @Published var recordKeystrokes: Bool   { didSet { d.set(recordKeystrokes, forKey: "rec.keys") } }
    @Published var recordCamera: Bool       { didSet { d.set(recordCamera, forKey: "rec.camera") } }

    // MARK: General
    @Published var launchAtLogin: Bool { didSet { applyLaunchAtLogin(launchAtLogin) } }
    @Published var playSound: Bool { didSet { d.set(playSound, forKey: "shot.sound") } }
    @Published var soundName: String { didSet { d.set(soundName, forKey: "gen.soundName") } }
    @Published var menuBarIconStyle: MenuBarIconStyle { didSet { d.set(menuBarIconStyle.rawValue, forKey: "gen.iconStyle"); onMenuBarStyleChanged?() } }
    @Published var captureDelaySeconds: Int { didSet { d.set(captureDelaySeconds, forKey: "gen.delay") } }

    // MARK: Screenshot
    @Published var defaultAnnotationColorHex: String { didSet { d.set(defaultAnnotationColorHex, forKey: "shot.color") } }
    @Published var defaultTool: Int             { didSet { d.set(defaultTool, forKey: "shot.tool") } }
    @Published var defaultLineWidth: Double     { didSet { d.set(defaultLineWidth, forKey: "shot.width") } }
    @Published var saveFormat: ImageFormat      { didSet { d.set(saveFormat.rawValue, forKey: "shot.format") } }
    @Published var jpegQuality: Double          { didSet { d.set(jpegQuality, forKey: "shot.jpegq") } }
    @Published var autoSaveEnabled: Bool        { didSet { d.set(autoSaveEnabled, forKey: "shot.autosave") } }
    @Published var autoSaveFolder: String       { didSet { d.set(autoSaveFolder, forKey: "shot.autodir") } }

    // MARK: OCR
    /// true = keep line breaks (outline / layout). false = one line (inline).
    @Published var ocrKeepLineBreaks: Bool { didSet { d.set(ocrKeepLineBreaks, forKey: "ocr.lines") } }
    @Published var ocrTrimWhitespace: Bool { didSet { d.set(ocrTrimWhitespace, forKey: "ocr.trim") } }
    @Published var ocrNotify: Bool         { didSet { d.set(ocrNotify, forKey: "ocr.notify") } }
    /// "auto" or a BCP-47 code like "en-US".
    @Published var ocrLanguage: String     { didSet { d.set(ocrLanguage, forKey: "ocr.lang") } }
    @Published var ocrAppend: Bool         { didSet { d.set(ocrAppend, forKey: "ocr.append") } }

    // MARK: Color
    @Published var colorFormat: ColorFormat { didSet { d.set(colorFormat.rawValue, forKey: "color.format") } }
    @Published var uppercaseHex: Bool       { didSet { d.set(uppercaseHex, forKey: "color.upper") } }
    @Published var recentColors: [String]   { didSet { d.set(recentColors, forKey: "color.recents") } }
    @Published var colorContinuous: Bool    { didSet { d.set(colorContinuous, forKey: "color.loop") } }
    @Published var colorNotify: Bool        { didSet { d.set(colorNotify, forKey: "color.notify") } }

    // MARK: Clipboard
    @Published var clipboardEnabled: Bool     { didSet { d.set(clipboardEnabled, forKey: "clip.enabled") } }
    @Published var clipboardMaxItems: Int     { didSet { d.set(clipboardMaxItems, forKey: "clip.max") } }
    @Published var clipboardStoreImages: Bool { didSet { d.set(clipboardStoreImages, forKey: "clip.images") } }
    /// Skip items apps mark concealed/transient (passwords, OTPs). ON by default.
    @Published var ignoreSecrets: Bool        { didSet { d.set(ignoreSecrets, forKey: "clip.ignoreSecrets") } }
    @Published var clearOnQuit: Bool          { didSet { d.set(clearOnQuit, forKey: "clip.clearquit") } }
    // Clipboard history additions:
    @Published var rejectDuplicates: Bool     { didSet { d.set(rejectDuplicates, forKey: "clip.reject") } }
    @Published var lockPinned: Bool           { didSet { d.set(lockPinned, forKey: "clip.lockpin") } }
    /// 0 = never; otherwise auto-delete unpinned items older than N hours.
    @Published var autoDeleteHours: Int       { didSet { d.set(autoDeleteHours, forKey: "clip.autodel") } }
    @Published var ignoreUniversalClipboard: Bool { didSet { d.set(ignoreUniversalClipboard, forKey: "clip.ignoreUC") } }
    /// Bundle identifiers whose copies are never captured.
    @Published var ignoreApps: [String]       { didSet { d.set(ignoreApps, forKey: "clip.ignoreApps") } }
    @Published var doubleClickToPaste: Bool   { didSet { d.set(doubleClickToPaste, forKey: "clip.dblpaste") } }
    @Published var activateAfterPaste: Bool   { didSet { d.set(activateAfterPaste, forKey: "clip.actpaste") } }

    /// Available OCR languages (label, code). "auto" lets Vision detect.
    static let ocrLanguages: [(String, String)] = [
        ("Automatic", "auto"), ("English", "en-US"), ("Spanish", "es-ES"),
        ("French", "fr-FR"), ("German", "de-DE"), ("Italian", "it-IT"),
        ("Portuguese", "pt-BR"), ("Chinese", "zh-Hans"), ("Japanese", "ja-JP"),
        ("Korean", "ko-KR"),
    ]
    /// Feedback sounds — SnapDesk's own soft custom sounds first, then system.
    static let soundNames = ["SnapBlip", "SnapPop", "SnapChime", "SnapClick",
                             "Pop", "Tink", "Glass", "Funk", "Submarine", "Morse", "Ping"]

    init() {
        // Defaults: Control+1/2/3/4 (capture / OCR / color / clipboard).
        let ctrl = UInt32(controlKey)
        screenshotHotkey = Self.loadHotkey("hk.shot", d)  ?? Hotkey(keyCode: UInt32(kVK_ANSI_1), modifiers: ctrl)
        ocrHotkey        = Self.loadHotkey("hk.ocr", d)   ?? Hotkey(keyCode: UInt32(kVK_ANSI_2), modifiers: ctrl)
        colorHotkey      = Self.loadHotkey("hk.color", d) ?? Hotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: ctrl)
        clipboardHotkey  = Self.loadHotkey("hk.clip", d)  ?? Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: ctrl)
        recordHotkey     = Self.loadHotkey("hk.record", d) ?? Hotkey(keyCode: UInt32(kVK_ANSI_5), modifiers: ctrl)
        scrollHotkey     = Self.loadHotkey("hk.scroll", d) ?? Hotkey(keyCode: UInt32(kVK_ANSI_6), modifiers: ctrl)
        recordSystemAudio = d.object(forKey: "rec.audio") as? Bool ?? true
        recordMic = d.object(forKey: "rec.mic") as? Bool ?? false
        micDeviceID = d.string(forKey: "rec.micID") ?? ""
        recordSubtitles = d.object(forKey: "rec.subs") as? Bool ?? false
        uploadToDrive = d.object(forKey: "rec.gdrive") as? Bool ?? false
        recordingFolder = d.string(forKey: "rec.dir") ?? (NSHomeDirectory() + "/Desktop")
        recordFPS = d.object(forKey: "rec.fps") as? Int ?? 60
        recordQuality = d.string(forKey: "rec.quality").flatMap(RecordingQuality.init(rawValue:)) ?? .high
        recordHEVC = d.object(forKey: "rec.hevc") as? Bool ?? false
        recordShowCursor = d.object(forKey: "rec.cursor") as? Bool ?? true
        recordCountdown = d.object(forKey: "rec.countdown") as? Int ?? 3
        captionLanguage = d.string(forKey: "rec.capLang") ?? "en-US"
        recordBlurEnabled = d.object(forKey: "rec.blur") as? Bool ?? false
        recordCursorBoost = d.object(forKey: "rec.cursorBoost") as? Bool ?? false
        recordClickHighlight = d.object(forKey: "rec.clicks") as? Bool ?? false
        recordKeystrokes = d.object(forKey: "rec.keys") as? Bool ?? false
        recordCamera = d.object(forKey: "rec.camera") as? Bool ?? false

        playSound = d.object(forKey: "shot.sound") as? Bool ?? true
        soundName = d.string(forKey: "gen.soundName") ?? "SnapBlip"
        menuBarIconStyle = d.string(forKey: "gen.iconStyle").flatMap(MenuBarIconStyle.init(rawValue:)) ?? .snap
        captureDelaySeconds = d.object(forKey: "gen.delay") as? Int ?? 0

        defaultAnnotationColorHex = d.string(forKey: "shot.color") ?? "#FF3B30"
        defaultTool = d.object(forKey: "shot.tool") as? Int ?? 0
        defaultLineWidth = d.object(forKey: "shot.width") as? Double ?? 3
        saveFormat = d.string(forKey: "shot.format").flatMap(ImageFormat.init(rawValue:)) ?? .png
        jpegQuality = d.object(forKey: "shot.jpegq") as? Double ?? 0.9
        autoSaveEnabled = d.object(forKey: "shot.autosave") as? Bool ?? false
        autoSaveFolder = d.string(forKey: "shot.autodir") ?? (NSHomeDirectory() + "/Desktop")

        ocrKeepLineBreaks = d.object(forKey: "ocr.lines") as? Bool ?? true
        ocrTrimWhitespace = d.object(forKey: "ocr.trim") as? Bool ?? true
        ocrNotify = d.object(forKey: "ocr.notify") as? Bool ?? true
        ocrLanguage = d.string(forKey: "ocr.lang") ?? "auto"
        ocrAppend = d.object(forKey: "ocr.append") as? Bool ?? false

        colorFormat = d.string(forKey: "color.format").flatMap(ColorFormat.init(rawValue:)) ?? .hex
        uppercaseHex = d.object(forKey: "color.upper") as? Bool ?? true
        recentColors = d.stringArray(forKey: "color.recents") ?? []
        colorContinuous = d.object(forKey: "color.loop") as? Bool ?? false
        colorNotify = d.object(forKey: "color.notify") as? Bool ?? true

        clipboardEnabled = d.object(forKey: "clip.enabled") as? Bool ?? true
        clipboardMaxItems = (d.object(forKey: "clip.max") as? Int).map { max(20, min(500, $0)) } ?? 100
        clipboardStoreImages = d.object(forKey: "clip.images") as? Bool ?? true
        ignoreSecrets = d.object(forKey: "clip.ignoreSecrets") as? Bool ?? true
        clearOnQuit = d.object(forKey: "clip.clearquit") as? Bool ?? false
        rejectDuplicates = d.object(forKey: "clip.reject") as? Bool ?? true
        lockPinned = d.object(forKey: "clip.lockpin") as? Bool ?? true
        autoDeleteHours = d.object(forKey: "clip.autodel") as? Int ?? 0
        ignoreUniversalClipboard = d.object(forKey: "clip.ignoreUC") as? Bool ?? false
        ignoreApps = d.stringArray(forKey: "clip.ignoreApps") ?? []
        doubleClickToPaste = d.object(forKey: "clip.dblpaste") as? Bool ?? true
        activateAfterPaste = d.object(forKey: "clip.actpaste") as? Bool ?? true

        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } else {
            launchAtLogin = false
        }

        // First run: opt into launch-at-login so the app is ready after every
        // restart (user can turn it off in Settings → General).
        // NOTE: didSet does NOT fire during init, so register explicitly.
        if d.object(forKey: "firstRunDone") == nil {
            d.set(true, forKey: "firstRunDone")
            launchAtLogin = true
            applyLaunchAtLogin(true)
        }

        // One-time migration: move everyone to the new Control+1..4 defaults
        // (overwrites previously-saved Ctrl+Opt+letter bindings exactly once).
        if d.object(forKey: "hk.defaultsV2") == nil {
            d.set(true, forKey: "hk.defaultsV2")
            let ctrl = UInt32(controlKey)
            screenshotHotkey = Hotkey(keyCode: UInt32(kVK_ANSI_1), modifiers: ctrl)
            ocrHotkey        = Hotkey(keyCode: UInt32(kVK_ANSI_2), modifiers: ctrl)
            colorHotkey      = Hotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: ctrl)
            clipboardHotkey  = Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: ctrl)
            saveHotkey(screenshotHotkey, "hk.shot")
            saveHotkey(ocrHotkey, "hk.ocr")
            saveHotkey(colorHotkey, "hk.color")
            saveHotkey(clipboardHotkey, "hk.clip")
        }

        // One-time: move the old default capture sound to the new sweet one.
        if d.object(forKey: "snd.v1") == nil {
            d.set(true, forKey: "snd.v1")
            if soundName == "Pop" { soundName = "SnapBlip"; d.set(soundName, forKey: "gen.soundName") }
        }
    }

    // MARK: Derived

    /// Recognition languages array for the Vision request.
    var ocrRecognitionLanguages: [String] {
        // Empty = let Vision auto-detect unconstrained (don't bias to English).
        ocrLanguage == "auto" ? [] : [ocrLanguage]
    }
    var ocrAutoDetect: Bool { ocrLanguage == "auto" }

    // MARK: Recent colors

    func addRecentColor(_ hex: String) {
        var list = recentColors.filter { $0 != hex }
        list.insert(hex, at: 0)
        recentColors = Array(list.prefix(16))
    }

    // MARK: Reset

    func resetHotkeysToDefault() {
        let ctrl = UInt32(controlKey)
        // Suppress the per-key re-register; fire ONE re-register at the end
        // instead of six (each re-register rebuilds every Carbon hotkey).
        suppressHotkeyCallback = true
        screenshotHotkey = Hotkey(keyCode: UInt32(kVK_ANSI_1), modifiers: ctrl)
        ocrHotkey        = Hotkey(keyCode: UInt32(kVK_ANSI_2), modifiers: ctrl)
        colorHotkey      = Hotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: ctrl)
        clipboardHotkey  = Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: ctrl)
        recordHotkey     = Hotkey(keyCode: UInt32(kVK_ANSI_5), modifiers: ctrl)
        scrollHotkey     = Hotkey(keyCode: UInt32(kVK_ANSI_6), modifiers: ctrl)
        suppressHotkeyCallback = false
        onHotkeysChanged?()
    }

    // MARK: Persistence helpers

    private func saveHotkey(_ hk: Hotkey, _ key: String) {
        if let data = try? JSONEncoder().encode(hk) { d.set(data, forKey: key) }
    }

    private static func loadHotkey(_ key: String, _ d: UserDefaults) -> Hotkey? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Hotkey.self, from: data)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("SnapDesk: launch-at-login change failed: \(error)")
        }
    }
}
