import Testing
import AVFoundation
@testable import SnapDeskCore

/// The mixer exists because the finished file used to carry TWO audio tracks,
/// one for system audio, one for the mic. QuickTime played both; web players and
/// almost every editor take only the FIRST, so a tutorial recorded with narration
/// shipped with either the voice or the app audio missing, silently, and the
/// person found out from a viewer.
///
/// Everything below is synthetic PCM: no microphone, no screen capture, no
/// permission prompt. Constant-amplitude (DC) input on purpose: after summing,
/// resampling and limiting, the expected value of every output sample is still
/// known exactly, which a sine wave could not give.
struct AudioMixerTests {

    private func buffer(_ amplitude: Float, frames: AVAudioFrameCount = 1024,
                        sampleRate: Double = 48_000,
                        channels: AVAudioChannelCount = 2) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: sampleRate,
                                                channels: channels, interleaved: false))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        pcm.frameLength = frames
        let data = try #require(pcm.floatChannelData)
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) { data[channel][i] = amplitude }
        }
        return pcm
    }

    private func time(frame: Int, sampleRate: Double = 48_000) -> CMTime {
        CMTime(value: Int64(frame), timescale: CMTimeScale(sampleRate))
    }

    /// Collects the left channel of every emitted chunk with its timestamp.
    private final class Sink {
        var chunks: [(samples: [Float], pts: CMTime)] = []
        func attach(to mixer: AudioMixer) {
            mixer.onChunk = { [self] pcm, pts in
                let frames = Int(pcm.frameLength)
                var left = [Float](repeating: 0, count: frames)
                if let data = pcm.floatChannelData {
                    for i in 0..<frames { left[i] = data[0][i] }
                }
                chunks.append((left, pts))
            }
        }
    }

    /// 0.25 in from one source, after the input headroom.
    private let oneSource: Float = 0.25 * AudioMixer.sourceGain      // 0.2
    /// 0.25 from both, summed. Still under the limiter's knee.
    private let bothSources: Float = 0.5 * AudioMixer.sourceGain     // 0.4

    // MARK: - Summing

    @Test("Both sources land in ONE track, summed", .tags(.regression))
    func sumsBothSources() throws {
        let mixer = AudioMixer()
        let sink = Sink()
        sink.attach(to: mixer)
        for i in 0..<12 {
            let t = time(frame: i * 1024)
            mixer.append(try buffer(0.25), from: .systemAudio, at: t)
            mixer.append(try buffer(0.25), from: .microphone, at: t)
        }
        #expect(sink.chunks.count == 10, "12 buffers in, two held back as jitter slack")
        let value = sink.chunks[3].samples[512]
        #expect(abs(value - bothSources) < 0.001, "got \(value)")
    }

    @Test("A recording with only one source still gets a continuous track")
    func oneSourceDoesNotStall() throws {
        // Mic off for the whole recording. The absent source has to contribute
        // silence, not block the source that is there.
        let mixer = AudioMixer()
        let sink = Sink()
        sink.attach(to: mixer)
        for i in 0..<12 {
            mixer.append(try buffer(0.25), from: .systemAudio, at: time(frame: i * 1024))
        }
        #expect(sink.chunks.count == 10)
        let value = sink.chunks[3].samples[10]
        #expect(abs(value - oneSource) < 0.001, "got \(value)")
    }

    @Test("A source that starts late does not rewrite what was already emitted")
    func lateJoiningSource() throws {
        // System audio from the first frame; the mic device takes ~85 ms to spin up.
        let mixer = AudioMixer()
        let sink = Sink()
        sink.attach(to: mixer)
        for i in 0..<20 {
            let frame = i * 1024
            mixer.append(try buffer(0.25), from: .systemAudio, at: time(frame: frame))
            if frame >= 4096 {
                mixer.append(try buffer(0.25), from: .microphone, at: time(frame: frame))
            }
        }
        #expect(abs(sink.chunks[0].samples[0] - oneSource) < 0.001,
                "the first chunks predate the mic")
        #expect(abs(sink.chunks[6].samples[0] - bothSources) < 0.001,
                "later chunks carry both")
    }

    @Test("A gap in one source is silence in that source alone. Nothing slips in time",
          .tags(.regression))
    func gapInOneSource() throws {
        // The mic drops out between 2048 and 6144 frames (a USB glitch, or the
        // engine restarting). The mix must keep its cadence throughout: a stalled
        // source that dragged the write cursor with it would desync the picture.
        let mixer = AudioMixer()
        let sink = Sink()
        sink.attach(to: mixer)
        for i in 0..<20 {
            let frame = i * 1024
            mixer.append(try buffer(0.25), from: .systemAudio, at: time(frame: frame))
            if frame < 2048 || frame >= 6144 {
                mixer.append(try buffer(0.25), from: .microphone, at: time(frame: frame))
            }
        }
        #expect(abs(sink.chunks[1].samples[0] - bothSources) < 0.001)
        #expect(abs(sink.chunks[3].samples[0] - oneSource) < 0.001, "mic away")
        #expect(abs(sink.chunks[7].samples[0] - bothSources) < 0.001, "mic back")
        for i in 1..<sink.chunks.count {
            let step = CMTimeSubtract(sink.chunks[i].pts, sink.chunks[i - 1].pts)
            #expect(step == CMTime(value: 1024, timescale: 48_000),
                    "chunk \(i) is not one chunk after its predecessor")
        }
    }

    @Test("Stopping flushes the tail instead of losing the end of the sentence")
    func flushEmitsTheHeldTail() throws {
        let mixer = AudioMixer()
        let sink = Sink()
        sink.attach(to: mixer)
        for i in 0..<12 {
            mixer.append(try buffer(0.25), from: .systemAudio, at: time(frame: i * 1024))
        }
        #expect(sink.chunks.count == 10)
        mixer.flush()
        #expect(sink.chunks.count == 12, "the jitter slack must still reach the file")
        for i in 1..<sink.chunks.count {
            #expect(sink.chunks[i].pts > sink.chunks[i - 1].pts)
        }
    }

    @Test("Re-anchoring wipes the held tail. A pause has to flush BEFORE it",
          .tags(.regression))
    func reanchorWipesWhatWasStillHeld() throws {
        // `ScreenRecorder.pause()` used to suspend capture and let `resume()` call
        // reanchorAfterGap(), which zeroes both rings. The 43–64 ms the mixer holds
        // back as jitter slack was therefore deleted at every pause, clipping the
        // word the person was in the middle of saying. This pins both halves: the
        // re-anchor really does destroy it, and flushing first really does save it.
        let mixer = AudioMixer()
        let sink = Sink()
        sink.attach(to: mixer)
        for i in 0..<12 {
            mixer.append(try buffer(0.25), from: .systemAudio, at: time(frame: i * 1024))
        }
        #expect(sink.chunks.count == 10, "two chunks held back as jitter slack")
        mixer.reanchorAfterGap()
        mixer.flush()
        #expect(sink.chunks.count == 12)
        #expect(abs(sink.chunks[10].samples[0]) < 0.0001,
                "got \(sink.chunks[10].samples[0]). The re-anchor zeroed the held audio")

        let flushedFirst = AudioMixer()
        let tail = Sink()
        tail.attach(to: flushedFirst)
        for i in 0..<12 {
            flushedFirst.append(try buffer(0.25), from: .systemAudio, at: time(frame: i * 1024))
        }
        flushedFirst.flush()
        flushedFirst.reanchorAfterGap()
        #expect(tail.chunks.count == 12)
        #expect(abs(tail.chunks[10].samples[0] - oneSource) < 0.001,
                "got \(tail.chunks[10].samples[0]). Flushing first keeps the end of the sentence")
    }

    /// Parameterised rather than looped inside one test: each spacing gets its
    /// own identity, so the 1025 case can be re-run alone instead of being
    /// buried under a failure flood from 1023.
    @Test("Consecutive buffers of ONE source butt together instead of summing into each other",
          .tags(.regression), arguments: [1023, 1025])
    func splicesConsecutiveBuffersOfOneSource(_ spacing: Int) throws {
        // Placement came purely from each buffer's PTS and the write was an
        // unconditional `+=`. Correct for two DIFFERENT sources; for two buffers of
        // the SAME source it meant that a PTS spacing disagreeing with the frame
        // count by a single sample, which every real device does, from rounding
        // onto the 48 kHz grid, from a clock a routine 100 ppm off the host's, and
        // from a resampled 44.1 kHz buffer being 1114.29 frames "wide": either
        // counted the overlap twice (+6 dB) or drained the missed slot as a zero.
        // Several ticks a second on the drifting source: a faint crackle in the mix.
        //
        // Both directions below feed contiguous DC, so ANY doubled or zeroed sample
        // shows up as a value that is not the one-source level.
        let mixer = AudioMixer()
        let sink = Sink()
        sink.attach(to: mixer)
        for i in 0..<12 {
            mixer.append(try buffer(0.25), from: .microphone,
                         at: time(frame: i * spacing))
        }
        #expect(sink.chunks.count >= 8, "spacing \(spacing)")
        for (chunkIndex, chunk) in sink.chunks.enumerated() {
            for (sampleIndex, value) in chunk.samples.enumerated() {
                #expect(abs(value - oneSource) < 0.001,
                        "spacing \(spacing), chunk \(chunkIndex) sample \(sampleIndex) is \(value)")
            }
        }
    }

    @Test("A real jump still lands on its own timestamp, not spliced onto the last buffer")
    func aRealJumpIsNotSpliced() throws {
        // The splice must not swallow a genuine gap: half a second of missing mic
        // has to stay half a second of silence in the mix, or the source walks
        // permanently forward of the picture.
        let mixer = AudioMixer()
        let sink = Sink()
        sink.attach(to: mixer)
        // Mic for the first two buffers, away for half a second, then back.
        for i in 0..<32 {
            let frame = i * 1024
            mixer.append(try buffer(0.25), from: .systemAudio, at: time(frame: frame))
            if frame < 2048 || frame >= 26_624 {
                mixer.append(try buffer(0.25), from: .microphone, at: time(frame: frame))
            }
        }
        #expect(abs(sink.chunks[0].samples[0] - bothSources) < 0.001, "mic present at the start")
        #expect(abs(sink.chunks[10].samples[0] - oneSource) < 0.001,
                "got \(sink.chunks[10].samples[0]). The mic's gap was spliced away")
        #expect(abs(sink.chunks[26].samples[0] - bothSources) < 0.001,
                "got \(sink.chunks[26].samples[0]). The mic has to return at its own time")
    }

    // MARK: - Sample rates

    @Test("A 44.1 kHz source is resampled onto the 48 kHz mix timeline")
    func resamplesAnUnequalRate() throws {
        // Plenty of USB interfaces run at 44.1 kHz while ScreenCaptureKit is at 48.
        let mixer = AudioMixer()
        let sink = Sink()
        sink.attach(to: mixer)
        for i in 0..<24 {
            mixer.append(try buffer(0.25, sampleRate: 44_100), from: .microphone,
                         at: time(frame: i * 1024, sampleRate: 44_100))
        }
        #expect(sink.chunks.count > 6)
        // Well past the resampler's startup ramp.
        let value = sink.chunks[5].samples[512]
        #expect(abs(value - oneSource) < 0.02, "got \(value)")
        let step = CMTimeSubtract(sink.chunks[3].pts, sink.chunks[2].pts)
        #expect(step == CMTime(value: 1024, timescale: 48_000),
                "the OUTPUT cadence is canonical whatever the input rate is")
    }

    @Test("Two sources at different rates both reach the one track")
    func mixesUnequalRates() throws {
        let mixer = AudioMixer()
        let sink = Sink()
        sink.attach(to: mixer)
        for i in 0..<24 {
            mixer.append(try buffer(0.25), from: .systemAudio, at: time(frame: i * 1024))
            mixer.append(try buffer(0.25, sampleRate: 44_100), from: .microphone,
                         at: time(frame: i * 1024, sampleRate: 44_100))
        }
        let value = sink.chunks[5].samples[512]
        #expect(value > 0.35 && value < 0.45,
                "got \(value) (that is one source, not two)")
    }

    @Test("A mono source arrives in BOTH output channels")
    func centresAMonoSource() throws {
        // A mono mic written into channel 0 only plays in one ear, which reads as
        // a broken recording rather than a mono recording.
        let mixer = AudioMixer()
        var rightChannel: [Float] = []
        mixer.onChunk = { pcm, _ in
            guard rightChannel.isEmpty, let data = pcm.floatChannelData else { return }
            rightChannel = (0..<Int(pcm.frameLength)).map { data[1][$0] }
        }
        for i in 0..<12 {
            mixer.append(try buffer(0.25, channels: 1), from: .microphone,
                         at: time(frame: i * 1024))
        }
        #expect(rightChannel.isEmpty == false)
        #expect(abs(rightChannel[10] - oneSource) < 0.001, "got \(rightChannel[10])")
    }

    // MARK: - Pause

    @Test("A pause emits no silence and never moves a timestamp backwards",
          .tags(.regression))
    func pauseKeepsTimestampsMonotonic() throws {
        // The paused wall clock is time the movie CUTS OUT, not silence it owes.
        // Emitting it would have produced ~25 silent chunks and then, once the
        // recorder subtracts the pause offset, every real chunk after it would be
        // rejected as non-monotonic, which is how a resumed recording ends up mute.
        let mixer = AudioMixer()
        let sink = Sink()
        sink.attach(to: mixer)
        for i in 0..<12 {
            mixer.append(try buffer(0.25), from: .systemAudio, at: time(frame: i * 1024))
        }
        let beforePause = sink.chunks.count
        #expect(beforePause == 10)

        mixer.reanchorAfterGap()
        let resumeFrame = 12_288 + 24_000        // half a second of paused clock
        for i in 0..<12 {
            mixer.append(try buffer(0.25), from: .systemAudio,
                         at: time(frame: resumeFrame + i * 1024))
        }
        let afterResume = sink.chunks.count - beforePause
        #expect(afterResume > 0, "audio has to come back")
        #expect(afterResume < 20,
                "got \(afterResume). The paused span was emitted as silence")
        #expect(sink.chunks[beforePause].pts >= time(frame: resumeFrame),
                "the first chunk after the pause belongs after the pause")
        for i in 1..<sink.chunks.count {
            #expect(sink.chunks[i].pts > sink.chunks[i - 1].pts,
                    "chunk \(i) went backwards, which fails the writer outright")
        }
    }

    // MARK: - Limiting

    @Test("Two full-scale sources saturate instead of clipping flat", .tags(.regression))
    func limitsInsteadOfClipping() throws {
        let mixer = AudioMixer()
        let sink = Sink()
        sink.attach(to: mixer)
        for i in 0..<12 {
            let t = time(frame: i * 1024)
            mixer.append(try buffer(1.0), from: .systemAudio, at: t)
            mixer.append(try buffer(1.0), from: .microphone, at: t)
        }
        let chunk = sink.chunks[3].samples
        for value in chunk {
            #expect(value < 1.0, "reached full scale: \(value)")
            #expect(value > 0.9, "a loud mix must stay loud: \(value)")
        }
        // 1.0 and 1.0 at 0.8 headroom each = 1.6 into the soft knee.
        #expect(abs(chunk[0] - AudioMixer.limited(1.6)) < 0.0001)
    }

    @Test("The limiter is the identity below the knee and asymptotic above it")
    func limiterShape() {
        #expect(AudioMixer.limited(0) == 0)
        #expect(AudioMixer.limited(0.5) == 0.5, "ordinary speech is not shaped at all")
        #expect(AudioMixer.limited(-0.5) == -0.5)
        #expect(AudioMixer.limited(0.8) == 0.8, "at the knee, still untouched")
        #expect(AudioMixer.limited(2.0) < 1.0, "nothing may leave above full scale")
        #expect(AudioMixer.limited(-2.0) > -1.0)
        #expect(AudioMixer.limited(1.0) > 0.8, "and it stays monotonic")
        #expect(AudioMixer.limited(1.5) > AudioMixer.limited(1.0))
        #expect(AudioMixer.limited(-1.5) == -AudioMixer.limited(1.5), "symmetric")
    }

    // MARK: - Writer handoff

    @Test("A mixed chunk converts to the interleaved Int16 the writer input takes")
    func convertsToInt16() throws {
        let pcm = try buffer(0.5, frames: 8)
        let out = try #require(AudioMixer.int16Interleaved(from: pcm))
        #expect(out.format.isInterleaved)
        #expect(out.format.channelCount == 2)
        #expect(out.format.sampleRate == 48_000)
        #expect(out.frameLength == 8)
        let data = try #require(out.int16ChannelData)[0]
        // 0.5 × 32767 in both channels, frame after interleaved frame.
        for i in 0..<16 { #expect(data[i] == 16_384, "sample \(i) is \(data[i])") }
    }

    @Test("A sample past full scale is clamped, not wrapped")
    func clampsOutOfRange() throws {
        // Wrapping would turn the loudest moment into the quietest. The classic
        // integer-overflow crackle.
        let pcm = try buffer(2.0, frames: 4, channels: 1)
        let out = try #require(AudioMixer.int16Interleaved(from: pcm))
        let data = try #require(out.int16ChannelData)[0]
        for i in 0..<4 { #expect(data[i] == 32_767) }
    }
}
