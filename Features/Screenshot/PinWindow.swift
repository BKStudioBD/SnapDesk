import AppKit

/// A captured image "pinned" as a floating, always-on-top window on the desktop
/// — handy for reference while you work. Drag to move, scroll
/// or ⌘±/⌘0 to zoom, ⌘C to copy, Esc / double-click / ⌘W to close.
final class PinWindow: NSWindowController {
    private static var pins: Set<PinWindow> = []
    private let cg: CGImage
    private let playSoundOnCopy: Bool
    private let soundName: String

    /// Cascade origin so multiple pins don't stack exactly on top of each other.
    private static var cascade = 0

    static func pin(_ cg: CGImage, scale sourceScale: CGFloat? = nil,
                    playSound: Bool = false, soundName: String = "Pop") {
        let controller = PinWindow(cg: cg, scale: sourceScale, playSound: playSound, soundName: soundName)
        pins.insert(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(cg: CGImage, scale sourceScale: CGFloat?, playSound: Bool, soundName: String) {
        self.cg = cg
        self.playSoundOnCopy = playSound
        self.soundName = soundName
        // The SOURCE screen's scale — sizing by NSScreen.main halves/doubles
        // pins that came from a display with a different DPI.
        let scale = sourceScale ?? NSScreen.main?.backingScaleFactor ?? 2
        var w = CGFloat(cg.width) / scale, h = CGFloat(cg.height) / scale
        // Fit a comfortable default size.
        let maxDim: CGFloat = 520
        if max(w, h) > maxDim { let f = maxDim / max(w, h); w *= f; h *= f }

        let window = PinPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.level = .floating
        // ARC + close() + the default releasedWhenClosed=YES double-releases
        // the window → random crash when a pin is closed. Must be false.
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let off = CGFloat(Self.cascade % 8) * 28   // stagger stacked pins
            Self.cascade += 1
            window.setFrameTopLeftPoint(NSPoint(x: f.maxX - w - 30 - off, y: f.maxY - 30 - off))
        }
        super.init(window: window)

        let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        iv.image = NSImage(cgImage: cg, size: NSSize(width: w, height: h))
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 8
        iv.layer?.masksToBounds = true
        iv.layer?.borderWidth = 1
        iv.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        window.contentView = iv
        window.onCopy = { [weak self] in self?.copy() }
        window.onClose = { [weak self] in self?.close() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func copy() {
        let s = NSScreen.main?.backingScaleFactor ?? 2
        let pb = NSPasteboard.general; pb.clearContents()
        pb.writeObjects([NSImage(cgImage: cg,
            size: NSSize(width: CGFloat(cg.width) / s, height: CGFloat(cg.height) / s))])
        if playSoundOnCopy { Sounds.play(soundName) }
        Notifier.info("Copied", "Pinned image copied.")
    }

    override func close() {
        Self.pins.remove(self)
        super.close()
    }
}

/// Borderless panel that can become key (so it receives ⌘C / Esc) and carries
/// a couple of action hooks.
private final class PinPanel: NSWindow {
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onClose?()                                   // Esc
        case 8 where event.modifierFlags.contains(.command):  // ⌘C
            onCopy?()
        case 13 where event.modifierFlags.contains(.command): // ⌘W
            onClose?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onClose?(); return }       // double-click closes
        super.mouseDown(with: event)
    }
}
