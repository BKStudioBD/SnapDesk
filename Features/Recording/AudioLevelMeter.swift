import AVFoundation

/// One published reading of an audio stream: how loud it is, how loud it just
/// was, and whether it reached full scale.
struct AudioLevel: Equatable {
    /// Linear 0…1 root-mean-square over the window.
    var rms: Float = 0
    /// Linear 0…1 peak, held and decayed across windows so a transient stays
    /// visible for longer than the 50 ms it existed.
    var peak: Float = 0
    /// A sample reached full scale recently. Worth its own flag: a meter pinned at
    /// the top could just be loud, and the difference matters — a clipped mic
    /// cannot be fixed afterwards.
    var isClipping = false

    static let silent = AudioLevel()

    /// Bar length, 0…1.
    var displayFraction: Float { Self.fraction(of: rms) }
    /// Where to draw the peak tick, 0…1.
    var peakFraction: Float { Self.fraction(of: peak) }

    /// Amplitude → bar length on a dB scale: -60 dBFS reads as empty, 0 dBFS as
    /// full. Linear amplitude looks broken on a meter — normal speech sits around
    /// 0.05 linear and would barely move the bar.
    static func fraction(of amplitude: Float) -> Float {
        guard amplitude > 0 else { return 0 }
        let db = 20 * log10f(min(amplitude, 1))
        return max(0, min(1, (db + 60) / 60))
    }
}

/// Accumulates samples and publishes an `AudioLevel` once per window. Pure value
/// logic on purpose: no timer, no clock, no thread of its own — a caller on an
/// audio queue feeds it and gets a reading back exactly when one is due, which is
/// also what makes it testable without a microphone.
struct AudioLevelMeter {
    /// Frames per published reading. 2400 at 48 kHz = 50 ms → about 20 Hz, which
    /// is as fast as a meter needs to move and slow enough that the main thread
    /// gets one message per window instead of one per audio buffer.
    let windowFrames: Int
    /// How many windows a clip keeps being reported for. 20 ≈ 1 second: a clip
    /// that only lit the indicator for 50 ms is a clip nobody saw.
    let clipHoldWindows: Int

    private var frames = 0
    private var sumOfSquares: Double = 0
    private var windowPeak: Float = 0
    private var heldPeak: Float = 0
    private var clipWindowsLeft = 0

    init(windowFrames: Int = 2400, clipHoldWindows: Int = 20) {
        self.windowFrames = max(1, windowFrames)
        self.clipHoldWindows = max(0, clipHoldWindows)
    }

    /// Feed pre-summarised numbers — used by callers that already walked the
    /// samples and know the channel layout. Returns a reading only when a window
    /// completed.
    /// The parameter is deliberately NOT named `sumOfSquares`: under that name it
    /// shadowed the accumulator property, so the RMS divided the LAST buffer's sum
    /// by the WHOLE window's frame count. Every earlier buffer in the window was
    /// thrown away from the numerator while still counting in the denominator, and
    /// the meter under-read by sqrt(lastBufferFrames / windowFrames) — a steady
    /// 4.8 dB low with the 1024-frame buffers the mic paths deliver, which is
    /// exactly the "working mic reads low" failure this type exists to avoid.
    mutating func accumulate(frames: Int, sumOfSquares squares: Double, peak: Float) -> AudioLevel? {
        guard frames > 0 else { return nil }
        self.frames += frames
        self.sumOfSquares += squares
        windowPeak = max(windowPeak, peak)
        // A buffer longer than the window folds into it rather than queueing a
        // second reading: a meter needs a CURRENT value, not every value.
        guard self.frames >= windowFrames else { return nil }

        let rms = Float((self.sumOfSquares / Double(self.frames)).squareRoot())
        // 0.999 rather than 1.0: Int16 full scale and Float 1.0 don't meet exactly,
        // and a signal that reached -0.01 dBFS is clipping for every purpose that
        // matters here.
        if windowPeak >= 0.999 {
            clipWindowsLeft = clipHoldWindows
        } else if clipWindowsLeft > 0 {
            clipWindowsLeft -= 1
        }
        heldPeak = max(windowPeak, heldPeak * 0.85)
        let level = AudioLevel(rms: min(rms, 1), peak: min(heldPeak, 1),
                               isClipping: clipWindowsLeft > 0)
        self.frames = 0
        self.sumOfSquares = 0
        windowPeak = 0
        return level
    }

    /// One channel of plain samples, one per frame — the shape a test builds.
    mutating func accumulate(_ samples: [Float]) -> AudioLevel? {
        var squares = 0.0
        var peak: Float = 0
        for value in samples {
            squares += Double(value) * Double(value)
            peak = max(peak, abs(value))
        }
        return accumulate(frames: samples.count, sumOfSquares: squares, peak: peak)
    }

    /// A whole PCM buffer. Per frame the channels are averaged for loudness and
    /// maxed for peak, so a stereo source doesn't read half as loud as a mono one.
    mutating func accumulate(_ buffer: AVAudioPCMBuffer) -> AudioLevel? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData else { return nil }
        var squares = 0.0
        var peak: Float = 0
        for i in 0..<frames {
            var frameSquares = 0.0
            for channel in 0..<channels {
                let value = data[channel][i]
                frameSquares += Double(value) * Double(value)
                peak = max(peak, abs(value))
            }
            squares += frameSquares / Double(channels)
        }
        return accumulate(frames: frames, sumOfSquares: squares, peak: peak)
    }
}
