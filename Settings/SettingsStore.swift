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

/// One-click recording setups. Five toggles set by hand every time was the real
/// friction; these name the three combinations people actually use.
enum RecordingPreset: String, CaseIterable, Identifiable {
    case tutorial = "Tutorial", meeting = "Meeting", silentDemo = "Silent demo"
    var id: String { rawValue }
    var summary: String {
        switch self {
        case .tutorial:   "60 fps · mic + system audio · big cursor · click rings · keystrokes"
        case .meeting:    "30 fps · mic + camera bubble · captions · plain cursor"
        case .silentDemo: "60 fps · no audio · big cursor · click rings"
        }
    }
}

/// Which corner the webcam bubble sits in, in the video AND the live preview.
enum CameraCorner: String, CaseIterable, Identifiable {
    case topLeft = "Top left", topRight = "Top right"
    case bottomLeft = "Bottom left", bottomRight = "Bottom right"
    var id: String { rawValue }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeading: Bool { self == .topLeft || self == .bottomLeft }
}

/// Webcam bubble diameter as a fraction of the recorded region's height.
enum CameraSize: String, CaseIterable, Identifiable {
    case small = "Small", medium = "Medium", large = "Large"
    var id: String { rawValue }
    var fraction: CGFloat {
        switch self {
        case .small: 0.15
        case .medium: 0.22
        case .large: 0.30
        }
    }
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
/// on change (`didSet`). Hotkey changes fire `onHotkeysChanged` — updates live.
final class SettingsStore: ObservableObject {
    private let d = UserDefaults.standard

    /// Called whenever any hotkey changes (set by AppCoordinator).
    var onHotkeysChanged: (() -> Void)?
    /// Actions that used to be menu-bar items and now live in Settings. They are
    /// closures rather than `NSApp.sendAction` because the coordinator is not in
    /// the responder chain — a selector sent to nil never reaches it.
    var onCheckForUpdates: (() -> Void)?
    var onShowWelcome: (() -> Void)?
    /// When true, hotkey `didSet` skips the re-register callback — used to
    /// batch a multi-key change (e.g. reset-to-defaults) into one re-register
    /// instead of six.
    private var suppressHotkeyCallback = false
    /// Transient nav state — which Settings section to show (deep-links Help).
    @Published var selectedSection: String = "General"

    // MARK: Hotkeys (rebindable)
    @Published var screenshotHotkey: Hotkey { didSet { saveHotkey(screenshotHotkey, "hk.shot"); fireHotkeysChanged() } }
    @Published var ocrHotkey: Hotkey        { didSet { saveHotkey(ocrHotkey, "hk.ocr"); fireHotkeysChanged() } }
    @Published var colorHotkey: Hotkey      { didSet { saveHotkey(colorHotkey, "hk.color"); fireHotkeysChanged() } }
    @Published var clipboardHotkey: Hotkey  { didSet { saveHotkey(clipboardHotkey, "hk.clip"); fireHotkeysChanged() } }
    @Published var recordHotkey: Hotkey     { didSet { saveHotkey(recordHotkey, "hk.record"); fireHotkeysChanged() } }
    @Published var scrollHotkey: Hotkey     { didSet { saveHotkey(scrollHotkey, "hk.scroll"); fireHotkeysChanged() } }
    /// Re-run OCR on the last area, with no selection drag.
    @Published var ocrRepeatHotkey: Hotkey  { didSet { saveHotkey(ocrRepeatHotkey, "hk.ocrRepeat"); fireHotkeysChanged() } }
    /// Turn the text stack (multiple grabs → one clipboard) on/off.
    @Published var ocrStackHotkey: Hotkey   { didSet { saveHotkey(ocrStackHotkey, "hk.ocrStack"); fireHotkeysChanged() } }

    /// Every rebindable shortcut, for conflict checks and re-registration.
    var allHotkeys: [Hotkey] {
        [screenshotHotkey, ocrHotkey, colorHotkey, clipboardHotkey,
         recordHotkey, scrollHotkey, ocrRepeatHotkey, ocrStackHotkey]
    }

    private func fireHotkeysChanged() {
        guard !suppressHotkeyCallback else { return }
        onHotkeysChanged?()
    }

    // MARK: Recording
    @Published var recordSystemAudio: Bool  { didSet { d.set(recordSystemAudio, forKey: "rec.audio") } }
    @Published var recordMic: Bool          { didSet { d.set(recordMic, forKey: "rec.mic") } }
    /// Apple Voice Processing on the mic: noise suppression + echo cancellation
    /// + automatic gain. ON by default — a screen recording is a voice recording.
    @Published var recordNoiseCancellation: Bool { didSet { d.set(recordNoiseCancellation, forKey: "rec.nc") } }
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
    @Published var cameraCorner: CameraCorner { didSet { d.set(cameraCorner.rawValue, forKey: "rec.camCorner") } }
    @Published var cameraSize: CameraSize     { didSet { d.set(cameraSize.rawValue, forKey: "rec.camSize") } }
    @Published var cameraMirrored: Bool       { didSet { d.set(cameraMirrored, forKey: "rec.camMirror") } }

    // MARK: General
    @Published var launchAtLogin: Bool { didSet { applyLaunchAtLogin(launchAtLogin) } }
    @Published var playSound: Bool { didSet { d.set(playSound, forKey: "shot.sound") } }
    // Retired setting: SnapDesk ships exactly two sounds now — in (capture/copy)
    // and out (paste) — so there is no sound to pick. Key dropped in `init`.
    // Retired setting: the menu bar shows SnapDesk's one custom mark now, so
    // there is no style to pick. The old key is dropped in `init`.
    @Published var captureDelaySeconds: Int { didSet { d.set(captureDelaySeconds, forKey: "gen.delay") } }
    /// Check GitHub Releases for a newer build on launch. **OFF by default** —
    /// it is the only thing in SnapDesk that touches the network, so it stays a
    /// deliberate choice rather than something that happens to you.
    @Published var autoCheckUpdates: Bool { didSet { d.set(autoCheckUpdates, forKey: "gen.autoUpdate") } }
    /// When the last check ran (nil = never).
    @Published var lastUpdateCheck: Date? { didSet { d.set(lastUpdateCheck, forKey: "gen.lastUpdateCheck") } }

    // MARK: Screenshot
    @Published var defaultAnnotationColorHex: String { didSet { d.set(defaultAnnotationColorHex, forKey: "shot.color") } }
    @Published var defaultTool: Int             { didSet { d.set(defaultTool, forKey: "shot.tool") } }
    @Published var defaultLineWidth: Double     { didSet { d.set(defaultLineWidth, forKey: "shot.width") } }
    @Published var saveFormat: ImageFormat      { didSet { d.set(saveFormat.rawValue, forKey: "shot.format") } }
    @Published var jpegQuality: Double          { didSet { d.set(jpegQuality, forKey: "shot.jpegq") } }
    @Published var autoSaveEnabled: Bool        { didSet { d.set(autoSaveEnabled, forKey: "shot.autosave") } }
    @Published var autoSaveFolder: String       { didSet { d.set(autoSaveFolder, forKey: "shot.autodir") } }
    /// Cover the desktop icons with the wallpaper for the length of a capture.
    /// Key is owned by `DesktopCover.settingKey` — it is read from there on the
    /// capture path, where there is no store instance to reach for.
    @Published var hideDesktopDuringCapture: Bool {
        didSet { d.set(hideDesktopDuringCapture, forKey: DesktopCover.settingKey) }
    }

    // MARK: OCR
    /// true = keep line breaks (outline / layout). false = one line (inline).
    @Published var ocrKeepLineBreaks: Bool { didSet { d.set(ocrKeepLineBreaks, forKey: "ocr.lines") } }
    @Published var ocrTrimWhitespace: Bool { didSet { d.set(ocrTrimWhitespace, forKey: "ocr.trim") } }
    @Published var ocrNotify: Bool         { didSet { d.set(ocrNotify, forKey: "ocr.notify") } }
    /// "auto" or a BCP-47 code like "en-US".
    @Published var ocrLanguage: String     { didSet { d.set(ocrLanguage, forKey: "ocr.lang") } }
    /// Which recognizer runs first — see `OCREngine`.
    @Published var ocrEngine: OCREngine    { didSet { d.set(ocrEngine.rawValue, forKey: "ocr.engine") } }
    /// Blank line between blocks the layout separates.
    @Published var ocrParagraphBreaks: Bool { didSet { d.set(ocrParagraphBreaks, forKey: "ocr.paras") } }
    /// Raw text the user typed: words to favour, one per line or comma-separated.
    /// Stored verbatim so the field round-trips exactly what they wrote.
    @Published var ocrCustomWordsText: String { didSet { d.set(ocrCustomWordsText, forKey: "ocr.words") } }
    /// Language model off — identifiers survive instead of being "corrected".
    @Published var ocrCodeMode: Bool       { didSet { d.set(ocrCodeMode, forKey: "ocr.code") } }
    /// Tab-separate columns when the layout really is a table.
    @Published var ocrTableMode: Bool      { didSet { d.set(ocrTableMode, forKey: "ocr.table") } }

    // MARK: OCR text stack — session state, deliberately NOT persisted
    //
    // Several grabs collected into one clipboard payload. It lives here (not in
    // the coordinator) so Settings can own a real switch for it instead of a
    // paragraph of text describing a hotkey.
    //
    // OFF at every launch, on purpose: a PERSISTED append preference is exactly
    // how a grab silently ends up glued to whatever was copied an hour ago. The
    // mode has to be something the user just switched on and can still see.

    /// Fires when the mode flips, with (isOn, how many grabs it was carrying).
    /// One callback for both the hotkey and the Settings switch, so they can't
    /// drift into reporting the same change two different ways.
    var onOCRStackModeChanged: ((Bool, Int) -> Void)?
    /// Fires when the collected grabs change (added or cleared).
    var onOCRStackChanged: (() -> Void)?

    @Published var ocrStackActive: Bool = false {
        didSet {
            guard ocrStackActive != oldValue else { return }
            // Starting fresh either way: resuming a stack the user had stopped
            // using is the surprising behaviour, not the helpful one.
            let carried = ocrStack.count
            ocrStack.removeAll()
            onOCRStackModeChanged?(ocrStackActive, carried)
        }
    }
    @Published private(set) var ocrStack: [String] = []

    func ocrStackAppend(_ text: String) {
        ocrStack.append(text)
        onOCRStackChanged?()
    }

    /// Empties the stack WITHOUT touching the clipboard — the collected text is
    /// the user's now, and wiping their clipboard from a "start over" control
    /// would be its own bug.
    func ocrStackClear() {
        guard !ocrStack.isEmpty else { return }
        ocrStack.removeAll()
        onOCRStackChanged?()
    }

    // MARK: Color
    @Published var colorFormat: ColorFormat { didSet { d.set(colorFormat.rawValue, forKey: "color.format") } }
    @Published var uppercaseHex: Bool       { didSet { d.set(uppercaseHex, forKey: "color.upper") } }
    @Published var recentColors: [String]   { didSet { d.set(recentColors, forKey: "color.recents") } }
    @Published var colorNotify: Bool        { didSet { d.set(colorNotify, forKey: "color.notify") } }

    // MARK: Clipboard
    @Published var clipboardEnabled: Bool     { didSet { d.set(clipboardEnabled, forKey: "clip.enabled") } }
    @Published var clipboardMaxItems: Int     { didSet { d.set(clipboardMaxItems, forKey: "clip.max") } }
    @Published var clipboardStoreImages: Bool { didSet { d.set(clipboardStoreImages, forKey: "clip.images") } }
    /// Skip items apps mark concealed/transient (passwords, OTPs). ON by default.
    @Published var ignoreSecrets: Bool        { didSet { d.set(ignoreSecrets, forKey: "clip.ignoreSecrets") } }
    @Published var clearOnQuit: Bool {
        didSet {
            d.set(clearOnQuit, forKey: "clip.clearquit")
            guard clearOnQuit != oldValue else { return }
            onClearOnQuitChanged?(clearOnQuit)
        }
    }
    /// Fires when "clear history when SnapDesk quits" is switched, with the new
    /// value. The clipboard has to act on the TRANSITION and not just consult the
    /// flag on its next write: switching this ON has to purge what is ALREADY on
    /// disk, or a force-quit or crash before the next incidental write leaves exactly
    /// the bytes the person just asked to stop keeping.
    var onClearOnQuitChanged: ((Bool) -> Void)?
    // Clipboard history additions:
    @Published var rejectDuplicates: Bool     { didSet { d.set(rejectDuplicates, forKey: "clip.reject") } }
    @Published var lockPinned: Bool           { didSet { d.set(lockPinned, forKey: "clip.lockpin") } }
    /// 0 = never; otherwise auto-delete unpinned items older than N hours.
    @Published var autoDeleteHours: Int       { didSet { d.set(autoDeleteHours, forKey: "clip.autodel") } }
    @Published var ignoreUniversalClipboard: Bool { didSet { d.set(ignoreUniversalClipboard, forKey: "clip.ignoreUC") } }
    /// Bundle identifiers whose copies are never captured.
    @Published var ignoreApps: [String]       { didSet { d.set(ignoreApps, forKey: "clip.ignoreApps") } }
    // Retired setting: the two clicks now mean two different things, so there is
    // nothing left to switch. One click pastes, two copy — see `ClipboardRow`.
    // The old key is dropped in `init` so it can't linger in the plist.
    @Published var activateAfterPaste: Bool   { didSet { d.set(activateAfterPaste, forKey: "clip.actpaste") } }

    /// Available OCR languages (label, code), asked of Vision itself rather than
    /// hardcoded — a newer macOS gains languages, and an older one must not be
    /// offered ones it can't load. "auto" lets Vision detect the script.
    ///
    /// Lazy `static let`: the first read builds it once, when Settings opens.
    /// Names come from the user's own locale, so a Bangla system reads Bangla.
    static let ocrLanguages: [(String, String)] = {
        let locale = Locale.current
        let listed = OCRService.supportedLanguages().map { code -> (String, String) in
            let label = locale.localizedString(forIdentifier: code)
                ?? locale.localizedString(forLanguageCode: code)
                ?? code
            return (label, code)
        }
        // Vision returning nothing would leave a one-item picker; keep the
        // languages every supported macOS has so the UI still works.
        let fallback = [("English", "en-US"), ("Spanish", "es-ES"), ("French", "fr-FR"),
                        ("German", "de-DE"), ("Italian", "it-IT"), ("Portuguese", "pt-BR"),
                        ("Chinese", "zh-Hans"), ("Japanese", "ja-JP"), ("Korean", "ko-KR")]
        return [("Automatic", "auto")] + (listed.isEmpty ? fallback : listed)
    }()

    init() {
        // Defaults: Control+1/2/3/4 (capture / OCR / color / clipboard).
        let ctrl = UInt32(controlKey)
        screenshotHotkey = Self.loadHotkey("hk.shot", d)  ?? Hotkey(keyCode: UInt32(kVK_ANSI_1), modifiers: ctrl)
        ocrHotkey        = Self.loadHotkey("hk.ocr", d)   ?? Hotkey(keyCode: UInt32(kVK_ANSI_2), modifiers: ctrl)
        colorHotkey      = Self.loadHotkey("hk.color", d) ?? Hotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: ctrl)
        clipboardHotkey  = Self.loadHotkey("hk.clip", d)  ?? Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: ctrl)
        recordHotkey     = Self.loadHotkey("hk.record", d) ?? Hotkey(keyCode: UInt32(kVK_ANSI_5), modifiers: ctrl)
        scrollHotkey     = Self.loadHotkey("hk.scroll", d) ?? Hotkey(keyCode: UInt32(kVK_ANSI_6), modifiers: ctrl)
        ocrRepeatHotkey  = Self.loadHotkey("hk.ocrRepeat", d) ?? Hotkey(keyCode: UInt32(kVK_ANSI_7), modifiers: ctrl)
        ocrStackHotkey   = Self.loadHotkey("hk.ocrStack", d)  ?? Hotkey(keyCode: UInt32(kVK_ANSI_8), modifiers: ctrl)
        recordSystemAudio = d.object(forKey: "rec.audio") as? Bool ?? true
        recordMic = d.object(forKey: "rec.mic") as? Bool ?? false
        recordNoiseCancellation = d.object(forKey: "rec.nc") as? Bool ?? true
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
        cameraCorner = d.string(forKey: "rec.camCorner").flatMap(CameraCorner.init(rawValue:)) ?? .bottomRight
        cameraSize = d.string(forKey: "rec.camSize").flatMap(CameraSize.init(rawValue:)) ?? .medium
        cameraMirrored = d.object(forKey: "rec.camMirror") as? Bool ?? true

        playSound = d.object(forKey: "shot.sound") as? Bool ?? true
        d.removeObject(forKey: "gen.soundName")   // retired — fixed in/out pair now
        d.removeObject(forKey: "gen.iconStyle")   // retired — one custom mark now
        captureDelaySeconds = d.object(forKey: "gen.delay") as? Int ?? 0
        autoCheckUpdates = d.object(forKey: "gen.autoUpdate") as? Bool ?? false
        lastUpdateCheck = d.object(forKey: "gen.lastUpdateCheck") as? Date

        defaultAnnotationColorHex = d.string(forKey: "shot.color") ?? "#FF3B30"
        defaultTool = d.object(forKey: "shot.tool") as? Int ?? 0
        defaultLineWidth = d.object(forKey: "shot.width") as? Double ?? 3
        saveFormat = d.string(forKey: "shot.format").flatMap(ImageFormat.init(rawValue:)) ?? .png
        jpegQuality = d.object(forKey: "shot.jpegq") as? Double ?? 0.9
        autoSaveEnabled = d.object(forKey: "shot.autosave") as? Bool ?? false
        autoSaveFolder = d.string(forKey: "shot.autodir") ?? (NSHomeDirectory() + "/Desktop")
        hideDesktopDuringCapture = d.bool(forKey: DesktopCover.settingKey)

        ocrKeepLineBreaks = d.object(forKey: "ocr.lines") as? Bool ?? true
        ocrTrimWhitespace = d.object(forKey: "ocr.trim") as? Bool ?? true
        ocrNotify = d.object(forKey: "ocr.notify") as? Bool ?? true
        ocrLanguage = d.string(forKey: "ocr.lang") ?? "auto"
        ocrEngine = d.string(forKey: "ocr.engine").flatMap(OCREngine.init(rawValue:)) ?? .automatic
        ocrParagraphBreaks = d.object(forKey: "ocr.paras") as? Bool ?? true
        ocrCustomWordsText = d.string(forKey: "ocr.words") ?? ""
        ocrCodeMode = d.object(forKey: "ocr.code") as? Bool ?? false
        ocrTableMode = d.object(forKey: "ocr.table") as? Bool ?? false
        // Retired setting: appending is now an explicit, visible mode (the text
        // stack) that starts OFF every launch — never a silent preference that
        // glues a new grab onto whatever was on the clipboard before. Drop any
        // stored value so the old one can't linger in the plist.
        d.removeObject(forKey: "ocr.append")

        colorFormat = d.string(forKey: "color.format").flatMap(ColorFormat.init(rawValue:)) ?? .hex
        uppercaseHex = d.object(forKey: "color.upper") as? Bool ?? true
        recentColors = d.stringArray(forKey: "color.recents") ?? []
        colorNotify = d.object(forKey: "color.notify") as? Bool ?? true
        // Keep-sampling is gone; drop its stored value so an older plist can't
        // carry dead state forward. A stored format that no longer exists
        // (RGBA, HSL, …) already falls back to HEX above.
        d.removeObject(forKey: "color.loop")

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
        d.removeObject(forKey: "clip.dblpaste")   // retired — see the declaration above
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

        // One-time migration: move people OFF the old Ctrl+Opt+letter defaults
        // onto Control+1..4 — but ONLY where the binding is still that exact old
        // default. A binding the user changed themselves is theirs; overwriting
        // it (the old bug) silently threw away their choice.
        if d.object(forKey: "hk.defaultsV2") == nil {
            d.set(true, forKey: "hk.defaultsV2")
            let ctrl = UInt32(controlKey), ctrlOpt = UInt32(controlKey | optionKey)
            migrate(&screenshotHotkey, "hk.shot",
                    oldDefault: Hotkey(keyCode: UInt32(kVK_ANSI_1), modifiers: ctrlOpt),
                    newDefault: Hotkey(keyCode: UInt32(kVK_ANSI_1), modifiers: ctrl))
            migrate(&ocrHotkey, "hk.ocr",
                    oldDefault: Hotkey(keyCode: UInt32(kVK_ANSI_2), modifiers: ctrlOpt),
                    newDefault: Hotkey(keyCode: UInt32(kVK_ANSI_2), modifiers: ctrl))
            migrate(&colorHotkey, "hk.color",
                    oldDefault: Hotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: ctrlOpt),
                    newDefault: Hotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: ctrl))
            migrate(&clipboardHotkey, "hk.clip",
                    oldDefault: Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: ctrlOpt),
                    newDefault: Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: ctrl))
        }
    }

    /// Migrate one hotkey to a new default only if it still holds the old
    /// default — a user-customized binding is left untouched.
    private func migrate(_ hk: inout Hotkey, _ key: String, oldDefault: Hotkey, newDefault: Hotkey) {
        guard hk == oldDefault else { return }
        hk = newDefault
        saveHotkey(newDefault, key)
    }

    // MARK: Presets

    /// Apply a named setup. Deliberately does NOT touch the things that are the
    /// user's standing choice regardless of what they're recording — output
    /// folder, codec, quality, countdown, blur, noise cancellation.
    func apply(_ preset: RecordingPreset) {
        switch preset {
        case .tutorial:
            recordFPS = 60
            recordSystemAudio = true; recordMic = true; recordCamera = false
            recordSubtitles = false
            recordCursorBoost = true; recordClickHighlight = true; recordKeystrokes = true
            recordShowCursor = true
        case .meeting:
            recordFPS = 30
            recordSystemAudio = true; recordMic = true; recordCamera = true
            recordSubtitles = true
            recordCursorBoost = false; recordClickHighlight = false; recordKeystrokes = false
            recordShowCursor = true
        case .silentDemo:
            recordFPS = 60
            recordSystemAudio = false; recordMic = false; recordCamera = false
            recordSubtitles = false
            recordCursorBoost = true; recordClickHighlight = true; recordKeystrokes = false
            recordShowCursor = true
        }
    }

    // MARK: Derived

    /// Recognition languages array for the Vision request.
    var ocrRecognitionLanguages: [String] {
        // Empty = let Vision auto-detect unconstrained (don't bias to English).
        ocrLanguage == "auto" ? [] : [ocrLanguage]
    }
    var ocrAutoDetect: Bool { ocrLanguage == "auto" }

    /// Words to favour, parsed from the settings field. Split on newlines AND
    /// commas so either habit works; whitespace-only entries dropped.
    var ocrCustomWords: [String] {
        ocrCustomWordsText
            .components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// One value carrying every OCR preference into the recognizer.
    var ocrOptions: OCROptions {
        OCROptions(engine: ocrEngine,
                   languages: ocrRecognitionLanguages,
                   autoDetect: ocrAutoDetect,
                   customWords: ocrCustomWords,
                   keepLineBreaks: ocrKeepLineBreaks,
                   paragraphBreaks: ocrParagraphBreaks,
                   trim: ocrTrimWhitespace,
                   codeMode: ocrCodeMode,
                   tableMode: ocrTableMode)
    }

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
        ocrRepeatHotkey  = Hotkey(keyCode: UInt32(kVK_ANSI_7), modifiers: ctrl)
        ocrStackHotkey   = Hotkey(keyCode: UInt32(kVK_ANSI_8), modifiers: ctrl)
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
