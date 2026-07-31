import AppKit

/// Segmented input-level meter for the pre-record panel. Twelve segments, green
/// through amber to red, with a held peak tick and a distinct clip state: a bar
/// pinned at the top could just be loud, and only the clip state tells the user
/// their voice is being destroyed before it reaches the file.
///
/// Main thread only.
final class AudioLevelMeterView: NSView {
    /// Off = the mic is switched off, so the meter shows an empty track instead of
    /// vanishing. It keeps its place in the stack on purpose: the panel window is
    /// sized once from `fittingSize`, and a view that comes and going would leave a
    /// hole or clip the buttons.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if !isActive { level = .silent; shownLevel = 0; shownPeak = 0 }
            needsDisplay = true
        }
    }

    private var level: AudioLevel = .silent
    /// Smoothed bar/tick positions, so the meter reads as a level rather than a
    /// strobe. Under Reduce Motion these track the raw values exactly.
    private var shownLevel: Float = 0
    private var shownPeak: Float = 0

    private static let segmentCount = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Microphone level")
    }

    required init?(coder: NSCoder) { return nil }

    /// System-wide Reduce Motion. Read per update rather than cached: the user can
    /// flip it in System Settings while the panel is open.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func update(_ level: AudioLevel) {
        self.level = level
        let target = level.displayFraction
        let peak = level.peakFraction
        if reduceMotion {
            shownLevel = target
            shownPeak = peak
        } else {
            // Fast attack, slow release: standard meter ballistics, so a syllable
            // registers but the bar doesn't flicker between them.
            shownLevel += (target - shownLevel) * (target > shownLevel ? 0.6 : 0.25)
            shownPeak = max(peak, shownPeak - 0.04)
        }
        setAccessibilityValue(NSNumber(value: Int((shownLevel * 100).rounded())))
        setAccessibilityLabel(level.isClipping ? "Microphone level, clipping" : "Microphone level")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 1, dy: 2)
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: inset, xRadius: 3, yRadius: 3).fill()
        guard isActive else { return }

        let gap: CGFloat = 1.5
        let count = CGFloat(Self.segmentCount)
        let width = (inset.width - gap * (count - 1)) / count
        guard width > 0 else { return }
        let lit = Int((shownLevel * Float(Self.segmentCount)).rounded())

        for i in 0..<Self.segmentCount {
            let x = inset.minX + CGFloat(i) * (width + gap)
            let rect = NSRect(x: x, y: inset.minY, width: width, height: inset.height)
            let on = i < lit
            Self.color(forSegment: i).withAlphaComponent(on ? 1 : 0.16).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Held peak: a thin white tick, so a transient that already decayed is
        // still readable.
        if shownPeak > 0.01 {
            let x = inset.minX + min(inset.width - 1, CGFloat(shownPeak) * inset.width)
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSRect(x: x - 0.5, y: inset.minY, width: 1, height: inset.height).fill()
        }

        // Clipping reads as its own thing: a red frame around the whole meter,
        // not merely "the bar is at the end".
        if level.isClipping {
            NSColor.systemRed.setStroke()
            let outline = NSBezierPath(roundedRect: inset.insetBy(dx: -0.5, dy: -0.5),
                                       xRadius: 3.5, yRadius: 3.5)
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }

    private static func color(forSegment index: Int) -> NSColor {
        switch index {
        case (segmentCount - 2)...: .systemRed
        case (segmentCount - 4)...: .systemYellow
        default: .systemGreen
        }
    }
}
