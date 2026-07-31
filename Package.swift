// swift-tools-version: 6.0
import PackageDescription

// TEST-ONLY package. The shipping app is built by ./build.sh (plain swiftc over
// every source file). This manifest exists so `swift test` can run Swift Testing
// against the app's dependency-light, pure-logic types.
//
// `SnapDeskCore` deliberately lists its sources one by one instead of pulling in a
// whole folder: most of the app's files reach into RegionSelection, SettingsStore
// or the SwiftUI scene graph, which a library target can't build in isolation. Add
// a file here only once it compiles on its own.
let package = Package(
    name: "SnapDesk",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SnapDeskCore",
            path: ".",
            exclude: [
                "App",
                // Listed file-by-file rather than as whole directories: the pure
                // geometry and image helpers that live beside them ARE tested, and
                // a file may not appear in both `sources` and `exclude`.
                "Capture/CaptureService.swift",
                "Capture/RegionSelector.swift",
                "Casks",
                "Features/Clipboard/ClipboardRows.swift",
                "Features/Clipboard/PasteEditView.swift",
                "Features/Clipboard/SnippetEditorView.swift",
                "Features/Clipboard/ClipboardWindow.swift",
                "Features/Recording/AudioLevelMeterView.swift",
                "Features/Recording/CameraBubbleWindow.swift",
                "Features/Recording/PreRecordPanel.swift",
                "Features/Recording/RecordingPreview.swift",
                "Features/Recording/RecordingSession.swift",
                "Features/Recording/ScreenRecorder.swift",
                "Features/Recording/SubtitleBurner.swift",
                "Features/Recording/TimelineStrip.swift",
                "Features/Screenshot/CaptureEditor.swift",
                "Features/Screenshot/EditorEdit.swift",
                "Features/Screenshot/EditorImageState.swift",
                "Features/Screenshot/PinWindow.swift",
                "Features/Screenshot/ScrollCapture.swift",
                "LICENSE",
                "README.md",
                "Resources",
                "Settings/SettingsView.swift",
                "Settings/SettingsWindowController.swift",
                "SnapDesk-MAS.entitlements",
                "SnapDesk.entitlements",
                "Support/DriveUpload.swift",
                "Support/FolderAccess.swift",
                "Support/Paster.swift",
                "Support/Sounds.swift",
                "Support/Theme.swift",
                "Support/VisualEffect.swift",
                "Tests",
                "build",
                "build.sh",
                "docs",
                "install.sh",
                "make-signing-cert.sh",
                "test-tools.sh",
                "test.sh",
                "tools",
            ],
            sources: [
                // Compiled here only because SettingsStore owns the toggle whose
                // key this declares; its window work is untested.
                "Capture/DesktopCover.swift",
                "Capture/SelectionGeometry.swift",
                "Capture/WallpaperFill.swift",
                "Features/Clipboard/ClipboardItem.swift",
                "Features/Clipboard/ClipboardEdit.swift",
                "Features/Clipboard/ClipboardImageStore.swift",
                "Features/Clipboard/ClipboardManager.swift",
                "Features/Clipboard/ClipboardMerge.swift",
                "Features/Clipboard/ClipboardSelection.swift",
                "Features/Clipboard/Snippet.swift",
                "Features/Clipboard/SnippetStore.swift",
                "Features/Clipboard/TextTransform.swift",
                "Features/ColorPicker/ColorPickerService.swift",
                "Features/ColorPicker/ColorHex.swift",
                "Features/OCR/OCRService.swift",
                "Features/Recording/AudioLevelMeter.swift",
                "Features/Recording/AudioMixer.swift",
                "Features/Recording/CameraProblem.swift",
                // Testable without a camera: the bubble's geometry, circle mask
                // and mirroring are checked against a synthetic frame.
                "Features/Recording/FrameDecorator.swift",
                "Features/Recording/MicCapture.swift",
                "Features/Recording/MicLevelMonitor.swift",
                "Features/Screenshot/AnnotationRenderer.swift",
                "Features/Screenshot/CropBox.swift",
                "Features/Screenshot/ScrollStitcher.swift",
                "Features/Screenshot/EditorImageTransform.swift",
                "Features/Screenshot/ImageTransformer.swift",
                "Hotkeys/HotkeyCenter.swift",
                "Settings/HotkeyRecorder.swift",
                "Settings/SettingsStore.swift",
                "Support/AppUninstaller.swift",
                "Support/BackgroundWork.swift",
                "Support/CacheCleaner.swift",
                "Support/InstallHelper.swift",
                "Support/MissLog.swift",
                "Support/Notifier.swift",
                // Pulled in by FrameDecorator's keystroke overlay, which checks
                // the Accessibility grant before installing its monitor.
                "Support/Permissions.swift",
                "Support/ProjectJunkScanner.swift",
                "Support/SystemStats.swift",
                "Support/Updater.swift",
            ],
            // Swift 5 mode ON PURPOSE: ./build.sh ships the app in Swift 5 mode,
            // and a test must exercise the code as SHIPPED. Building the same
            // sources under Swift 6 strict concurrency here would fail on
            // pre-existing global state and, worse, would be testing a
            // configuration that never reaches a user.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SnapDeskCoreTests",
            dependencies: ["SnapDeskCore"],
            path: "Tests/SnapDeskCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
