import Testing
import AVFoundation
@testable import SnapDeskCore

/// The pre-record meter answers "is my mic actually hearing me" before the
/// countdown instead of after the upload, so the numbers behind it have to be
/// right: a meter that reads low on a working mic sends people hunting for a
/// problem they don't have, and one that never reports clipping lets them narrate
/// a whole tutorial into distortion.
///
/// Pure value logic — synthetic samples, no device, no timer.
struct AudioLevelMeterTests {

    @Test("Nothing is published until a full window has arrived")
    func publishesOncePerWindow() {
        // One message per window, not one per audio buffer: the consumer hops to
        // the main thread on every reading.
        // `accumulate` is mutating, so every call is made on its own line: inside a
        // #expect or #require the macro's closure receives it immutably.
        var meter = AudioLevelMeter(windowFrames: 100)
        let short = meter.accumulate([Float](repeating: 0.5, count: 99))
        #expect(short == nil)
        let completing = meter.accumulate([Float](repeating: 0.5, count: 1))
        #expect(completing != nil)
        let afterReset = meter.accumulate([Float](repeating: 0.5, count: 50))
        #expect(afterReset == nil, "the window starts over, it does not keep firing")
    }

    @Test("RMS of a constant signal is that constant")
    func measuresRMS() throws {
        var meter = AudioLevelMeter(windowFrames: 64)
        let reading = meter.accumulate([Float](repeating: 0.5, count: 64))
        let level = try #require(reading)
        #expect(abs(level.rms - 0.5) < 0.0001)
        #expect(abs(level.peak - 0.5) < 0.0001)
        #expect(level.isClipping == false)
    }

    @Test("RMS covers the WHOLE window, not just the buffer that completed it",
          .tags(.regression))
    func measuresRMSAcrossEveryBufferInTheWindow() throws {
        // The bug: the sum of squares was read from the last buffer's parameter
        // (which shadowed the accumulator) while the frame count was the whole
        // window's, so a window built from three 1024-frame mic buffers — the size
        // both capture paths deliver — reported sqrt(1/3) of the real level. That is
        // a constant 4.8 dB under-read on a perfectly good microphone.
        var meter = AudioLevelMeter(windowFrames: 300)
        let third = [Float](repeating: 0.1, count: 100)
        // Each call on its own line: `accumulate` is mutating and a #expect closure
        // would receive the meter immutably.
        let first = meter.accumulate(third)
        #expect(first == nil)
        let second = meter.accumulate(third)
        #expect(second == nil)
        let completing = meter.accumulate(third)
        let level = try #require(completing)
        #expect(abs(level.rms - 0.1) < 0.0001, "got \(level.rms), expected 0.1")
    }

    @Test("A quiet run of buffers cannot be hidden by a loud one that closes the window")
    func averagesUnequalBuffersOverTheWindow() throws {
        // Half the window silent, half at 0.4 → RMS 0.4·sqrt(0.5) ≈ 0.2828. Reading
        // only the closing buffer would have reported 0.4·sqrt(50/100) by accident
        // here, so the asymmetric case below is the one that actually discriminates.
        var meter = AudioLevelMeter(windowFrames: 100)
        let loud = meter.accumulate([Float](repeating: 0.4, count: 90))
        #expect(loud == nil)
        let reading = meter.accumulate([Float](repeating: 0, count: 10))
        let level = try #require(reading)
        // Nine tenths at 0.4: 0.4·sqrt(0.9) ≈ 0.3795. The shadowed-parameter bug
        // reported 0 here — the window closed on a silent buffer.
        #expect(abs(level.rms - 0.3795) < 0.001, "got \(level.rms)")
    }

    @Test("A clip keeps being reported for about a second", .tags(.regression))
    func holdsTheClipFlag() throws {
        // A clip that only lit the indicator for the 50 ms it happened in is a clip
        // nobody sees — and clipping is the one input problem that cannot be
        // repaired after the recording.
        var meter = AudioLevelMeter(windowFrames: 10, clipHoldWindows: 3)
        var window = [Float](repeating: 0.1, count: 10)
        window[4] = 1.0
        let atTheClip = meter.accumulate(window)
        #expect(try #require(atTheClip).isClipping)
        let quiet = [Float](repeating: 0.1, count: 10)
        for windowIndex in 1...2 {
            let later = meter.accumulate(quiet)
            #expect(try #require(later).isClipping,
                    "still held \(windowIndex) window(s) later")
        }
        let afterHold = meter.accumulate(quiet)
        #expect(try #require(afterHold).isClipping == false, "released")
    }

    @Test("The held peak decays instead of sticking where a transient left it")
    func decaysTheHeldPeak() throws {
        var meter = AudioLevelMeter(windowFrames: 10, clipHoldWindows: 0)
        var loud = [Float](repeating: 0, count: 10)
        loud[0] = 0.8
        let firstReading = meter.accumulate(loud)
        let first = try #require(firstReading)
        #expect(abs(first.peak - 0.8) < 0.0001)
        let secondReading = meter.accumulate([Float](repeating: 0, count: 10))
        let second = try #require(secondReading)
        #expect(second.peak < first.peak)
        #expect(second.peak > 0, "but it must not snap straight to nothing either")
    }

    @Test("Levels are drawn on a dB scale — linear amplitude barely moves the bar")
    func mapsToADBScale() {
        #expect(AudioLevel.fraction(of: 0) == 0)
        #expect(AudioLevel.fraction(of: 1) == 1)
        #expect(AudioLevel.fraction(of: 0.001) < 0.001, "-60 dBFS is the floor")
        let half = AudioLevel.fraction(of: 0.5)          // -6 dBFS
        #expect(half > 0.85 && half < 0.95, "got \(half)")
        // Normal speech sits near -26 dBFS. On a linear scale that is a 5% sliver
        // and the mic looks dead; here it has to be plainly visible.
        let speech = AudioLevel.fraction(of: 0.05)
        #expect(speech > 0.4 && speech < 0.7, "got \(speech)")
    }

    @Test("A stereo buffer does not read louder than the same signal in mono")
    func averagesChannelsRatherThanSumming() throws {
        // Summing channels instead of averaging made a stereo interface measure
        // ~3 dB hotter than a mono one on identical audio, so the meter disagreed
        // with itself depending on which mic was picked.
        var monoMeter = AudioLevelMeter(windowFrames: 32)
        var stereoMeter = AudioLevelMeter(windowFrames: 32)
        let mono = try pcm(0.4, frames: 32, channels: 1)
        let stereo = try pcm(0.4, frames: 32, channels: 2)
        let monoReading = monoMeter.accumulate(mono)
        let stereoReading = stereoMeter.accumulate(stereo)
        let monoLevel = try #require(monoReading)
        let stereoLevel = try #require(stereoReading)
        #expect(abs(monoLevel.rms - stereoLevel.rms) < 0.0001,
                "mono \(monoLevel.rms) vs stereo \(stereoLevel.rms)")
        #expect(abs(monoLevel.rms - 0.4) < 0.0001)
    }

    private func pcm(_ amplitude: Float, frames: AVAudioFrameCount,
                     channels: AVAudioChannelCount) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 48_000,
                                                channels: channels, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) { data[channel][i] = amplitude }
        }
        return buffer
    }
}
