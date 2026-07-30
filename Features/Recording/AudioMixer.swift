import AVFoundation
import CoreMedia

/// Sums microphone and system audio into ONE track.
///
/// Two audio tracks in a .mov play fine in QuickTime and almost nowhere else:
/// web players (YouTube, Vimeo, Slack, Discord) and most editors take only the
/// FIRST audio track, so a tutorial recorded with narration shipped with either
/// the voice or the app audio missing — silently, with the recorder finding out
/// from a viewer. Everything therefore lands in a single track, mixed here.
///
/// The two sources are independent: different sample rates, different channel
/// counts, their own jitter, and either may be absent for a whole recording or
/// go quiet mid-way. So:
///
///  * Both are converted to **48 kHz Float32 non-interleaved**. 48 kHz because
///    that is what ScreenCaptureKit delivers and what the voice-processing mic
///    path already targets, so the usual case resamples nothing. Float32 because
///    the sum of two full-scale sources needs headroom Int16 does not have — the
///    sum is limited once, at the end, instead of wrapping mid-pipeline.
///    Channel counts are left alone by the converter and folded to stereo while
///    summing: AVAudioConverter's channel-count behaviour varies by format, and
///    a fold we own is a fold we can test.
///  * Samples are summed into a one-second ring keyed by absolute frame index on
///    ONE clock — the first sample's PTS is the epoch. A source's jitter then
///    moves only WHERE its audio lands, never when the mix advances. Within ONE
///    source, though, consecutive buffers are butt-spliced instead (see
///    `nextIndex`): summing is right for two DIFFERENT sources and wrong for two
///    buffers of the same one, where a PTS a sample off would double or zero
///    samples that are actually contiguous.
///  * Chunks leave on a fixed cadence, `latencyFrames` behind the furthest-ahead
///    source. A source that is silent, absent, or late contributes zeros and
///    cannot stall the other one or shift its timing.
///
/// Confined to ONE serial queue (the recorder's): every `append`, and the
/// `onChunk` / `onLevel` callbacks, run there. No locks, because by construction
/// there is no second thread.
final class AudioMixer {
    enum Source: CaseIterable { case systemAudio, microphone }

    /// Output format of a mixed chunk. Force-unwrapped on purpose: 48 kHz stereo
    /// Float32 is a format Core Audio has always been able to describe, and if it
    /// ever returned nil nothing downstream could run anyway.
    static let canonical = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 48_000, channels: 2,
                                         interleaved: false)!

    /// One mixed chunk and its presentation time, on the input clock (the caller
    /// applies any pause offset). Fires on the mixer's queue.
    var onChunk: ((AVAudioPCMBuffer, CMTime) -> Void)?
    /// Input level per source, about 20× a second. Fires on the mixer's queue —
    /// the consumer hops to the main thread itself.
    var onLevel: ((Source, AudioLevel) -> Void)?

    /// Frames per emitted chunk. 1024 ≈ 21 ms at 48 kHz: small enough that a stop
    /// loses almost nothing, large enough not to hand the AAC encoder crumbs.
    private let chunkFrames = 1024
    /// How far behind the furthest-ahead source a chunk is held before it counts
    /// as final. 2048 frames ≈ 43 ms — two chunks of slack, which covers the
    /// jitter between the ScreenCaptureKit audio callback and the voice-processing
    /// tap, so a late source still lands in its own slot instead of being dropped
    /// as history.
    private let latencyFrames = 2048
    /// One second of canonical audio. Anything arriving further ahead of the write
    /// cursor than this is a clock discontinuity, not jitter.
    private let capacityFrames = 48_000

    /// Summing ring, one array per output channel, indexed `frame % capacity`.
    private var leftRing: [Float]
    private var rightRing: [Float]

    /// Frame index 0 of the mix timeline. The first sample of the first source to
    /// arrive defines it, so both sources share one clock.
    private var epoch: CMTime?
    /// Next frame index to emit. Everything below it has already been written and
    /// can never be revised.
    private var writeCursor = 0
    /// Furthest frame index any source has delivered.
    private var maxFilled = 0
    /// True until the next `append` picks the write cursor: the start of a
    /// recording, and every resume (the paused span is not silence to write).
    private var needsAnchor = true
    /// The mixer's own monotonicity guard. One track now, so one clock and one
    /// last-PTS — a regressive PTS flips AVAssetWriter to `.failed` and loses the
    /// whole recording.
    private var lastEmittedPTS: CMTime?

    /// Where each source's previous buffer ENDED, so the next one from that source
    /// butts up against it.
    ///
    /// Placement from PTS alone plus an unconditional `+=` is right for two
    /// DIFFERENT sources — that is the mix — but it also makes two CONSECUTIVE
    /// buffers of the SAME source sum into each other whenever the PTS spacing
    /// disagrees with the frame counts. It always does: a PTS rounded to the 48 kHz
    /// grid is up to half a frame out, a device clock a routine 100 ppm off the host
    /// clock drifts ~5 frames a second, and a resampled 44.1 kHz buffer is 1114.29
    /// frames "wide" whichever integer the converter hands back. The overlapping
    /// samples were counted twice (+6 dB) and the missed slots drained as zeros —
    /// several single-sample ticks a second, heard as a faint continuous crackle on
    /// the drifting source while the other one stayed clean.
    private var nextIndex: [Source: Int] = [:]
    /// How far a buffer's PTS may sit from where its source's previous buffer ended
    /// before it counts as a real jump rather than rounding or clock drift. 96
    /// frames = 2 ms at 48 kHz: small enough that a genuine gap or seek still lands
    /// on its own timestamp, large enough to absorb every rounding artefact. Drift
    /// that eventually crosses it re-snaps to the true timeline once — one 2 ms
    /// artefact a minute or so instead of a tick every few buffers — which also
    /// stops the splice from letting a drifting source walk away from the picture.
    private let spliceTolerance = 96

    private var converters: [Source: Converter] = [:]
    private var meters: [Source: AudioLevelMeter] = [:]

    /// Samples that arrived after their slot had already been written out.
    private(set) var lateFrames = 0
    /// Times a source jumped more than a second and forced a re-anchor.
    private(set) var discontinuities = 0

    init() {
        leftRing = [Float](repeating: 0, count: capacityFrames)
        rightRing = [Float](repeating: 0, count: capacityFrames)
    }

    // MARK: - Input

    /// System audio arrives as CMSampleBuffers from ScreenCaptureKit; the PTS
    /// rides along inside.
    func append(_ sampleBuffer: CMSampleBuffer, from source: Source) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let pcm = converter(for: source).converted(sampleBuffer) else { return }
        add(pcm, from: source, at: pts)
    }

    /// The voice-processing mic path already holds PCM plus a host-clock time.
    func append(_ buffer: AVAudioPCMBuffer, from source: Source, at pts: CMTime) {
        guard let pcm = converter(for: source).converted(buffer) else { return }
        add(pcm, from: source, at: pts)
    }

    /// Emit everything whole that is buffered, without waiting for the jitter
    /// slack. Called when capture has ended: nothing more can arrive to fill those
    /// slots, so holding them back would just drop the last ~64 ms of audio — the
    /// end of the sentence the user was still speaking when they hit Stop.
    func flush() {
        guard let epoch else { return }
        while writeCursor + chunkFrames <= maxFilled {
            emitChunk(at: writeCursor, epoch: epoch)
            writeCursor += chunkFrames
        }
    }

    /// Throw away what is buffered and let the next sample pick a new write
    /// cursor. Called on resume: nothing was fed while paused, so that span is
    /// not silence the movie should carry — it is time the movie cuts out. The
    /// first source to arrive afterwards anchors, so the other one may lose the
    /// few milliseconds it was ahead by; that beats writing a wall of silence and
    /// then having every real chunk rejected as non-monotonic.
    func reanchorAfterGap() {
        leftRing = [Float](repeating: 0, count: capacityFrames)
        rightRing = [Float](repeating: 0, count: capacityFrames)
        needsAnchor = true
        // A new segment: no source has a previous buffer to butt against, and
        // splicing onto a cursor from before the gap would place the resumed audio
        // where the paused span used to be.
        nextIndex.removeAll()
    }

    // MARK: - Mixing

    private func add(_ pcm: AVAudioPCMBuffer, from source: Source, at pts: CMTime) {
        let frames = Int(pcm.frameLength)
        let channels = Int(pcm.format.channelCount)
        guard frames > 0, channels > 0, let data = pcm.floatChannelData,
              pts.isValid, pts.isNumeric else { return }

        measure(pcm, from: source)

        if epoch == nil { epoch = pts }
        guard let epoch else { return }
        var index = frameIndex(of: pts, since: epoch)

        if needsAnchor {
            writeCursor = index
            maxFilled = index
            needsAnchor = false
        }

        // A source whose clock jumped more than the ring holds cannot be placed
        // relative to the cursor at all. Start a fresh segment rather than
        // silently stalling on a cursor nothing will ever reach again.
        if index >= writeCursor + capacityFrames {
            discontinuities += 1
            reanchorAfterGap()
            writeCursor = index
            maxFilled = index
            needsAnchor = false
        }

        // Butt this buffer against its source's previous one when the PTS agrees to
        // within the tolerance — see `nextIndex`. Deliberately AFTER the
        // discontinuity check, which must judge the real timestamp, and before the
        // history/clamp arithmetic below, which is about the mix as a whole.
        if let expected = nextIndex[source], abs(index - expected) <= spliceTolerance {
            index = expected
        }
        // The buffer's own end, not the clamped write below: a buffer partly dropped
        // as history must not shift where this source's NEXT one is expected.
        nextIndex[source] = index + frames

        // Slots below the cursor are already in the file. Skip that part of the
        // buffer; if all of it is history, the whole buffer is late.
        let start = max(index, writeCursor)
        let skip = start - index
        guard skip < frames else {
            lateFrames += frames
            return
        }
        if skip > 0 { lateFrames += skip }
        let count = min(frames - skip, writeCursor + capacityFrames - start)
        guard count > 0 else { return }

        let gain = Self.sourceGain
        accumulate(data[0], offset: skip, into: &leftRing, at: start, count: count, gain: gain)
        // Mono source → the same signal in both channels, so a mono mic is
        // centred instead of arriving only in the left ear.
        accumulate(data[channels > 1 ? 1 : 0], offset: skip, into: &rightRing,
                   at: start, count: count, gain: gain)

        maxFilled = max(maxFilled, start + count)
        emitReadyChunks(epoch: epoch)
    }

    private func accumulate(_ source: UnsafePointer<Float>, offset: Int,
                            into ring: inout [Float], at start: Int, count: Int, gain: Float) {
        var done = 0
        while done < count {
            let slot = (start + done) % capacityFrames
            let run = min(count - done, capacityFrames - slot)
            for i in 0..<run { ring[slot + i] += source[offset + done + i] * gain }
            done += run
        }
    }

    /// Emit every whole chunk that no source can still write into. Bounded: a
    /// write is clamped to `writeCursor + capacityFrames`, so this can never run
    /// away even after a long stall.
    private func emitReadyChunks(epoch: CMTime) {
        let ready = maxFilled - latencyFrames
        while writeCursor + chunkFrames <= ready {
            emitChunk(at: writeCursor, epoch: epoch)
            writeCursor += chunkFrames
        }
    }

    private func emitChunk(at start: Int, epoch: CMTime) {
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.canonical,
                                         frameCapacity: AVAudioFrameCount(chunkFrames)),
              let destination = out.floatChannelData else { return }
        out.frameLength = AVAudioFrameCount(chunkFrames)
        drain(&leftRing, from: start, into: destination[0])
        drain(&rightRing, from: start, into: destination[1])

        let pts = CMTimeAdd(epoch, CMTime(value: Int64(start), timescale: 48_000))
        if let last = lastEmittedPTS, pts <= last { return }
        lastEmittedPTS = pts
        onChunk?(out, pts)
    }

    /// Copy one chunk out through the limiter, zeroing the slots as it goes —
    /// they are reused a ring-length later.
    private func drain(_ ring: inout [Float], from start: Int,
                       into destination: UnsafeMutablePointer<Float>) {
        var done = 0
        while done < chunkFrames {
            let slot = (start + done) % capacityFrames
            let run = min(chunkFrames - done, capacityFrames - slot)
            for i in 0..<run {
                destination[done + i] = Self.limited(ring[slot + i])
                ring[slot + i] = 0
            }
            done += run
        }
    }

    private func frameIndex(of pts: CMTime, since epoch: CMTime) -> Int {
        let delta = CMTimeConvertScale(CMTimeSubtract(pts, epoch), timescale: 48_000,
                                       method: .roundHalfAwayFromZero)
        return Int(delta.value)
    }

    // MARK: - Gain and limiting

    /// Headroom given to each source on the way in. Two full-scale signals summed
    /// raw reach 2.0 and, written as PCM, wrap into a square wave — the harshest
    /// artefact there is. At 0.8 a lone source loses about 1.9 dB and is otherwise
    /// bit-for-bit untouched, which is the trade worth making: nobody notices two
    /// decibels, everybody notices tearing.
    static let sourceGain: Float = 0.8
    /// Below the knee the limiter is the identity function, so ordinary speech
    /// over ordinary app audio passes through unshaped.
    private static let knee: Float = 0.8

    /// Soft-knee limiter: identity up to `knee`, then asymptotic to 1.0, so a loud
    /// moment saturates the way tape does instead of clipping flat. Stateless, so
    /// it cannot pump and can be checked sample by sample.
    static func limited(_ x: Float) -> Float {
        let magnitude = abs(x)
        guard magnitude > knee else { return x }
        let over = (magnitude - knee) / (1 - knee)
        let shaped = knee + (1 - knee) * tanhf(over)
        return x < 0 ? -shaped : shaped
    }

    // MARK: - Levels

    private func measure(_ pcm: AVAudioPCMBuffer, from source: Source) {
        guard onLevel != nil else { return }
        var meter = meters[source] ?? AudioLevelMeter()
        if let level = meter.accumulate(pcm) { onLevel?(source, level) }
        meters[source] = meter
    }

    // MARK: - Output conversion

    /// Mixed Float32 stereo → Int16 interleaved at the same rate, which is the
    /// shape `MicCapture.sampleBuffer(from:at:)` and the AAC writer input take.
    /// The limiter has already run, so this only scales and rounds; the clamp is
    /// belt-and-braces against a denormal or a NaN.
    static func int16Interleaved(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let source = buffer.floatChannelData,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: buffer.format.sampleRate,
                                         channels: buffer.format.channelCount,
                                         interleaved: true),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = out.int16ChannelData else { return nil }
        out.frameLength = buffer.frameLength
        let interleaved = destination[0]
        for channel in 0..<channels {
            let samples = source[channel]
            for i in 0..<frames {
                let clamped = max(-1, min(1, samples[i]))
                interleaved[i * channels + channel] = Int16((clamped * 32_767).rounded())
            }
        }
        return out
    }

    // MARK: - Input conversion

    private func converter(for source: Source) -> Converter {
        if let existing = converters[source] { return existing }
        let made = Converter()
        converters[source] = made
        return made
    }

    /// Brings one source to 48 kHz Float32 non-interleaved, leaving its channel
    /// count alone (see the type comment). Rebuilds itself when the source's
    /// format changes, which happens when the mic device is switched mid-run.
    final class Converter {
        private var converter: AVAudioConverter?
        private var inputFormat: AVAudioFormat?
        private var outputFormat: AVAudioFormat?

        /// CMSampleBuffer → PCM, then convert.
        func converted(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frames > 0,
                  let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let format = AVAudioFormat(streamDescription: asbd),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(frames))
            else { return nil }
            // frameLength FIRST: `mutableAudioBufferList` sizes mDataByteSize from
            // it, and a zero-length list makes the copy a silent no-op that yields
            // a buffer of pure silence.
            pcm.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames),
                into: pcm.mutableAudioBufferList) == noErr else { return nil }
            return converted(pcm)
        }

        func converted(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            let format = buffer.format
            // ScreenCaptureKit already delivers exactly this — don't pay for a
            // converter that would copy the samples unchanged.
            if format.sampleRate == AudioMixer.canonical.sampleRate,
               format.commonFormat == .pcmFormatFloat32, !format.isInterleaved {
                return buffer
            }
            if inputFormat != format || converter == nil {
                guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: AudioMixer.canonical.sampleRate,
                                                 channels: format.channelCount,
                                                 interleaved: false),
                      let made = AVAudioConverter(from: format, to: target) else { return nil }
                converter = made
                inputFormat = format
                outputFormat = target
            }
            guard let converter, let outputFormat else { return nil }
            let ratio = outputFormat.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                             frameCapacity: capacity) else { return nil }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0 else { return nil }
            return out
        }
    }
}
