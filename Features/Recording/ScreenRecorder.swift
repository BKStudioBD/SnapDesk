import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage

/// Records a display (or a region of it) to an H.264 .mov via ScreenCaptureKit +
/// AVAssetWriter. Optional system audio and microphone, mixed into ONE audio
/// track (see `AudioMixer`). Supports pause/resume by shifting presentation
/// timestamps, so the paused wall-clock time is cut out of the movie instead of
/// appearing as a frozen gap, and restart, which bins the partial file and begins
/// an identical run. SnapDesk's own windows (control bar, region border) are
/// excluded from the capture. Frame delivery + writing happen on a private serial
/// queue; control methods are main-thread.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var streamConfig: SCStreamConfiguration?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    /// The ONE audio track: system audio and mic summed by `mixer`. There used to
    /// be two inputs, and the resulting two-track file lost either the voice or
    /// the app audio in every player except QuickTime.
    private var audioInput: AVAssetWriterInput?
    private var mixer: AudioMixer?
    private var micCapture: MicCapture?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var outputURL: URL?
    private let queue = DispatchQueue(label: "com.snapdesk.recorder")

    // Pause bookkeeping (queue-confined).
    private var paused = false
    private var pauseOffset = CMTime.zero
    /// Host-clock time when the current pause began; nil when not paused. The
    /// pause DURATION is measured on the same clock SCStream/AVCapture timestamp
    /// their buffers on, so on resume we grow `pauseOffset` by exactly the paused
    /// wall-clock span — no need to wait for a video frame to recompute it (which
    /// left audio muted over a static slide) and no video-only gap math that
    /// could shove audio PTS backwards and fail the writer.
    private var pausedAtHost: CMTime?
    private var lastAppendedPTS: CMTime?
    private var lastAdjustedPTS: CMTime?      // last VIDEO PTS written (output timeline)
    private var lastAudioPTS: CMTime?         // last MIXED audio PTS written
    private var frameDuration = CMTime(value: 1, timescale: 60)
    private var fps = 60
    /// Queue-confined: guards against finalizing twice (stop() racing
    /// didStopWithError would otherwise call finishWriting twice → crash).
    private var finalized = false
    /// Queue-confined: a mid-recording writer failure is announced once, not once
    /// per dropped frame (that would be ~60 notifications a second).
    private var reportedFailure = false
    /// Frames ScreenCaptureKit delivered that the encoder wasn't ready for.
    /// Silent until now, so a struggling machine looked like a broken app.
    private var droppedFrames = 0
    private var appendedFrames = 0

    // Privacy blur: regions (pixel coords, top-left origin, relative to the
    // output frame) pixelated on every frame via GPU CoreImage.
    private var blurRectsPx: [CGRect] = []
    private var blurPool: CVPixelBufferPool?
    private var decorator: FrameDecorator?
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private(set) var isRecording = false
    /// Called on the main thread when writing finishes (URL = file, or nil on failure).
    var onFinish: ((URL?) -> Void)?
    /// Input level per source, on the MAIN thread at about 20 Hz. Nil callback =
    /// the mixer skips measuring entirely.
    var onLevel: ((AudioMixer.Source, AudioLevel) -> Void)?

    /// Everything `start` was handed, so `restart()` can begin an identical run
    /// without the caller having to keep it. The decorator is deliberately not in
    /// here: it is carried across a restart alive, because stopping it would drop
    /// its event monitors and kill the webcam session.
    private struct StartConfig {
        let display: SCDisplay
        let filter: SCContentFilter
        let sourceRect: CGRect?
        let scale: CGFloat
        let captureAudio: Bool
        let micDevice: AVCaptureDevice?
        let noiseCancellation: Bool
        let fps: Int
        let codec: AVVideoCodecType
        let bitsPerPixel: Double?
        let showCursor: Bool
        let blurRectsPx: [CGRect]
        let url: URL
    }
    /// Main-thread.
    private var startConfig: StartConfig?
    /// Main-thread: a restart has torn the old writer down and the fresh run has
    /// not begun yet. `stop()` in that window must cancel the restart rather than
    /// stop a recording that does not exist — otherwise the new run starts with
    /// nobody holding it and writes until the app quits.
    private var pendingRestart = false

    /// A `CMSampleBuffer` handed across a queue hop. `CMSampleBuffer` is not
    /// `Sendable`, and the mic callback has to hop because the voice-processing
    /// backend delivers on the audio engine's render thread. The buffer is only
    /// READ after the hop and the CF object stays retained across it, so the
    /// crossing is safe — stated here narrowly instead of widening `MicCapture`'s
    /// own contract.
    private struct SampleBox: @unchecked Sendable { let sb: CMSampleBuffer }

    // MARK: - Control

    @MainActor
    func start(display: SCDisplay, filter: SCContentFilter, sourceRect: CGRect?, scale: CGFloat,
               captureAudio: Bool, micDevice: AVCaptureDevice?, noiseCancellation: Bool = true,
               fps: Int = 60, codec: AVVideoCodecType = .h264,
               bitsPerPixel: Double? = nil, showCursor: Bool = true,
               blurRectsPx: [CGRect] = [], decorator: FrameDecorator? = nil, url: URL) throws {
        startConfig = StartConfig(display: display, filter: filter, sourceRect: sourceRect,
                                  scale: scale, captureAudio: captureAudio, micDevice: micDevice,
                                  noiseCancellation: noiseCancellation, fps: fps, codec: codec,
                                  bitsPerPixel: bitsPerPixel, showCursor: showCursor,
                                  blurRectsPx: blurRectsPx, url: url)
        let config = SCStreamConfiguration()
        if let r = sourceRect {
            config.sourceRect = r
            config.width  = Int(r.width * scale)
            config.height = Int(r.height * scale)
        } else {
            config.width  = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
        }
        config.showsCursor = showCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(15, fps)))
        streamConfig = config
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(15, fps)))
        self.fps = max(15, fps)
        config.queueDepth = 8
        if captureAudio {
            config.capturesAudio = true
            // Never record SnapDesk's own notification/shutter sounds.
            config.excludesCurrentProcessAudio = true
        }

        let writer = try AVAssetWriter(url: url, fileType: .mov)
        // Crash/force-quit safety: write movie fragments every 5s so the file
        // stays playable up to the last fragment even if we die mid-recording.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
        ]
        // Compression properties.
        //
        // MEASURED, not assumed: with no keyframe setting at all, VideoToolbox
        // already emits keyframes roughly every 0.6 s on both high- and low-motion
        // 720p30 content. So this cap does NOT speed up scrubbing — the default was
        // fine. What it buys is a GUARANTEED CEILING: the default GOP is
        // encoder-chosen and undocumented, and can drift with the codec (HEVC) or a
        // future macOS, so bounding it keeps seek behaviour deterministic instead of
        // trusting an implementation detail. Frame reordering enables B-frames —
        // worth about 2% on this content, more on longer static screen recordings.
        var compression: [String: Any] = [
            AVVideoMaxKeyFrameIntervalKey: max(15, fps) * 2,
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoAllowFrameReorderingKey: true,
        ]
        // Quality preset → explicit average bitrate (nil = encoder default).
        if let bpp = bitsPerPixel {
            compression[AVVideoAverageBitRateKey] =
                Int(Double(config.width * config.height) * bpp * Double(fps))
        }
        videoSettings[AVVideoCompressionPropertiesKey] = compression
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard writer.canAdd(videoInput) else { throw RecorderError.setup }
        writer.add(videoInput)

        // ONE audio track, whatever the sources. 48 kHz because that is what both
        // sources already run at, so the encoder resamples nothing (the old 44.1 kHz
        // setting made it resample every buffer for no benefit).
        var audioInput: AVAssetWriterInput?
        var mixer: AudioMixer?
        if captureAudio || micDevice != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 128_000,
            ])
            ai.expectsMediaDataInRealTime = true
            if writer.canAdd(ai) {
                writer.add(ai)
                audioInput = ai
                let mx = AudioMixer()
                mx.onChunk = { [weak self] pcm, pts in self?.appendMixed(pcm, at: pts) }
                // Captured, not read back through `self`: the mixer fires from the
                // recorder queue and this property is written on main.
                if let levelHandler = onLevel {
                    mx.onLevel = { source, level in
                        DispatchQueue.main.async { levelHandler(source, level) }
                    }
                }
                mixer = mx
            }
        }

        // The microphone feeds the mixer, not its own track. Mic failure is
        // non-fatal — the screen recording continues without voice.
        var micCapture: MicCapture?
        if let micDevice, mixer != nil {
            let mc = MicCapture { [weak self] sb in
                guard let self else { return }
                // The voice-processing backend taps on the audio engine's render
                // thread, NOT this queue — the raw backend does deliver here, but
                // relying on that made every mixer/pause/writer field a race on
                // the noise-cancelling path. Hop unconditionally; it is one async
                // per ~21 ms buffer.
                let box = SampleBox(sb: sb)
                self.queue.async { self.appendMic(box.sb) }
            }
            do {
                try mc.start(device: micDevice, queue: queue,
                             noiseCancellation: noiseCancellation)
                micCapture = mc
            } catch {
                NSLog("SnapDesk: mic capture failed: \(error)")
            }
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if captureAudio { try? stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.mixer = mixer
        self.micCapture = micCapture
        self.adaptor = adaptor
        self.outputURL = url
        self.sessionStarted = false
        self.paused = false
        self.pausedAtHost = nil
        self.lastAdjustedPTS = nil
        self.lastAudioPTS = nil
        self.pauseOffset = .zero
        self.lastAppendedPTS = nil
        self.finalized = false
        self.reportedFailure = false
        self.droppedFrames = 0
        self.appendedFrames = 0
        self.blurRectsPx = blurRectsPx
        self.blurPool = nil
        self.decorator = decorator

        writer.startWriting()
        isRecording = true
        // Published BEFORE startCapture: the sample-buffer and didStopWithError
        // callbacks identify their run by comparing against this reference, and a
        // frame that arrived while it was still nil would be discarded.
        self.stream = stream
        stream.startCapture { [weak self] error in
            if let error {
                NSLog("SnapDesk: recording start failed: \(error)")
                // Tear down on the recorder queue — the stream callback thread
                // must not nil writer/inputs while didOutputSampleBuffer runs.
                self?.queue.async { self?.finish(success: false) }
            }
        }
    }

    /// Bin the partial file and immediately begin an identical run — same area,
    /// same audio sources, same effects, same destination. Safe mid-write: the
    /// stream is stopped, the writer is CANCELLED (not finished, so no half movie
    /// survives), the partial file is deleted, and only then does a new writer
    /// claim the path. Main-thread, like `pause`/`resume`/`stop`.
    func restart() {
        guard isRecording, !pendingRestart, let config = startConfig else { return }
        // Carried over alive: `FrameDecorator.stop()` removes its event monitors
        // and tears down the webcam session, and a restarted run is supposed to
        // look identical.
        let carriedDecorator = decorator
        pendingRestart = true
        queue.async { [self] in
            // Claim the teardown so a late didStopWithError or a racing
            // finalizeWriting cannot also run it. Losing that race means the
            // recording is already ending — release the flag, or a later stop()
            // would take the restart branch and never finalize anything.
            guard !finalized else {
                DispatchQueue.main.async { [weak self] in self?.pendingRestart = false }
                return
            }
            finalized = true
            micCapture?.stop()
            let dyingStream = stream
            let dyingWriter = writer
            let partial = outputURL
            stream = nil; writer = nil; videoInput = nil; audioInput = nil; adaptor = nil
            mixer = nil; micCapture = nil; blurPool = nil
            decorator = nil          // handed to the fresh run, so NOT stopped here
            outputURL = nil
            sessionStarted = false
            dyingStream?.stopCapture { _ in }
            dyingWriter?.cancelWriting()
            // cancelWriting() returns with the file closed, so deleting it here
            // cannot race the new writer opening the same path.
            if let partial { try? FileManager.default.removeItem(at: partial) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Stop/cancel landed during the teardown: start nothing, and report
                // the discard so the session tears its UI down.
                guard self.pendingRestart else {
                    carriedDecorator?.stop()
                    self.isRecording = false
                    self.onFinish?(nil)
                    return
                }
                self.pendingRestart = false
                do {
                    try self.start(display: config.display, filter: config.filter,
                                   sourceRect: config.sourceRect, scale: config.scale,
                                   captureAudio: config.captureAudio,
                                   micDevice: config.micDevice,
                                   noiseCancellation: config.noiseCancellation,
                                   fps: config.fps, codec: config.codec,
                                   bitsPerPixel: config.bitsPerPixel,
                                   showCursor: config.showCursor,
                                   blurRectsPx: config.blurRectsPx,
                                   decorator: carriedDecorator, url: config.url)
                } catch {
                    NSLog("SnapDesk: restart failed: \(error)")
                    carriedDecorator?.stop()
                    self.isRecording = false
                    self.onFinish?(nil)
                }
            }
        }
    }

    func pause()  {
        queue.async {
            guard !self.paused else { return }
            self.paused = true
            self.pausedAtHost = CMClockGetTime(CMClockGetHostTimeClock())
            // Same reason `stop()` flushes: the mixer holds everything newer than
            // `maxFilled - latencyFrames`, so 43–64 ms of already-summed audio is
            // sitting in the ring at any instant — and `resume()`'s
            // `reanchorAfterGap()` zeroes the ring, which DELETED it. Every pause
            // clipped the word the user was in the middle of. Flushing here is safe
            // for monotonicity: `pauseOffset` has not grown yet, so these chunks are
            // shifted by the same offset they would have been anyway.
            self.mixer?.flush()
            // Suspend the mic itself: dropping its samples while it keeps running
            // burns CPU and leaves the system's orange mic indicator lit.
            self.micCapture?.setPaused(true)
            // Stop ScreenCaptureKit compositing at full fps while paused — it was
            // delivering frames we just dropped, burning battery for nothing.
            if let cfg = self.streamConfig {
                cfg.minimumFrameInterval = CMTime(value: 2, timescale: 1)   // ~1 frame / 2 s
                self.stream?.updateConfiguration(cfg) { _ in }
            }
        }
    }
    func resume() {
        queue.async {
            guard self.paused else { return }
            self.paused = false
            // Grow the offset by the exact paused span, right now — so audio
            // resumes with the picture instead of staying muted until the screen
            // next changes, and the offset can never overshoot and drive a track
            // backwards.
            if let start = self.pausedAtHost {
                let span = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), start)
                if span > .zero { self.pauseOffset = CMTimeAdd(self.pauseOffset, span) }
            }
            self.pausedAtHost = nil
            // Nothing was fed to the mixer while paused, so its buffered ring is
            // stale and the paused span is not silence to write. Drop both and let
            // the next sample re-anchor, or the mixer would emit the whole paused
            // duration as silence and every real chunk after it would then be
            // rejected as non-monotonic once the pause offset is subtracted.
            self.mixer?.reanchorAfterGap()
            self.micCapture?.setPaused(false)
            if let cfg = self.streamConfig {
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(15, self.fps)))
                self.stream?.updateConfiguration(cfg) { _ in }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        // `isRecording` flips on MAIN, synchronously: callers (RecordingSession,
        // the coordinator) test it right after this returns.
        isRecording = false
        // A restart teardown is in flight: there is no stream or writer left to
        // finish. Clearing the flag makes the pending restart report a discard
        // instead of starting a run nobody could ever stop.
        if pendingRestart {
            pendingRestart = false
            return
        }
        // Everything else is queue-owned. `cleanup()` nils stream/writer/
        // micCapture/decorator ON THE RECORDER QUEUE, so reading those same vars
        // here on main was a data race — hop first, then touch them.
        queue.async { [self] in
            micCapture?.stop()
            // Push the mixer's jitter buffer into the file before the writer is
            // finished — otherwise the last ~64 ms, the end of whatever the user
            // was saying as they pressed Stop, is simply dropped.
            mixer?.flush()
            let deco = decorator
            DispatchQueue.main.async { deco?.stop() }
            guard let stream else { finalizeWriting(); return }
            stream.stopCapture { [weak self] _ in
                self?.queue.async { self?.finalizeWriting() }
            }
        }
    }

    /// Mic sample, already hopped onto the recorder queue → into the mixer. It is
    /// fed even before the writer session starts so the mixer's jitter buffer is
    /// already primed when the first video frame opens the session; nothing is
    /// written until `appendMixed` sees `sessionStarted`.
    private func appendMic(_ sb: CMSampleBuffer) {
        guard !paused, let mixer else { return }
        mixer.append(sb, from: .microphone)
    }

    /// One mixed chunk → the single audio track, shifted by the pause offset, but
    /// only if its output PTS is strictly after the last one written. A shifted
    /// chunk can otherwise land before its predecessor (a chunk straddles the
    /// pause boundary), and a regressive PTS flips the writer to `.failed`, which
    /// loses the whole recording. Video has this guard already; one audio track
    /// means exactly one more.
    private func appendMixed(_ pcm: AVAudioPCMBuffer, at pts: CMTime) {
        guard sessionStarted, let writer, writer.status == .writing,
              let input = audioInput, input.isReadyForMoreMediaData else { return }
        let outPTS = pauseOffset == .zero ? pts : CMTimeSubtract(pts, pauseOffset)
        if let last = lastAudioPTS, outPTS <= last { return }
        guard let int16 = AudioMixer.int16Interleaved(from: pcm),
              let sb = MicCapture.sampleBuffer(from: int16, at: outPTS) else { return }
        input.append(sb)
        lastAudioPTS = outPTS
    }

    private func finalizeWriting() {
        guard !finalized else { return }
        finalized = true
        // Nothing was ever appended (stopped before the first complete frame):
        // finishWriting would throw — cancel instead and report failure.
        guard sessionStarted else {
            writer?.cancelWriting()
            if let url = outputURL { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async { [weak self] in self?.onFinish?(nil) }
            cleanup()
            return
        }
        // A regressive-PTS append (or any other error) could have already
        // pushed the writer to `.failed`; markAsFinished / finishWriting on a
        // non-writing writer is undefined. Bail to the cancel path instead of
        // finalizing a writer that can't complete.
        guard writer?.status == .writing else {
            writer?.cancelWriting()
            if let url = outputURL { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async { [weak self] in self?.isRecording = false; self?.onFinish?(nil) }
            cleanup()
            return
        }
        reportDropsIfSignificant()
        // Not a notification: late audio frames and clock jumps are inaudible at
        // these counts, but a bug report about desynced sound needs the numbers.
        if let mixer, mixer.lateFrames > 0 || mixer.discontinuities > 0 {
            NSLog("SnapDesk: audio mix dropped \(mixer.lateFrames) late frames, "
                  + "re-anchored after \(mixer.discontinuities) clock jumps")
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let url = outputURL
        writer?.finishWriting { [weak self] in
            guard let self else { return }
            let ok = self.writer?.status == .completed
            DispatchQueue.main.async { self.isRecording = false; self.onFinish?(ok ? url : nil) }
            self.queue.async { self.cleanup() }   // teardown on the recorder queue, not the writer thread
        }
    }

    private func finish(success: Bool) {
        guard !finalized else { return }   // finalizeWriting() may have run first
        finalized = true
        writer?.cancelWriting()
        let url = success ? outputURL : nil
        // `isRecording` is read on the main thread (stop(), the coordinator); flip
        // it there, never from this recorder queue, so the two never race. Every
        // other exit already flips it on main — match them.
        DispatchQueue.main.async { self.isRecording = false; self.onFinish?(url) }
        cleanup()
    }

    private func cleanup() {
        micCapture?.stop()
        DispatchQueue.main.async { [decorator] in decorator?.stop() }
        stream = nil; writer = nil; videoInput = nil; audioInput = nil; adaptor = nil
        mixer = nil; micCapture = nil
        decorator = nil; blurPool = nil        // release the effects pipeline too
        outputURL = nil; sessionStarted = false
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // A restart leaves the previous stream draining for a moment. Its buffers
        // must not reach the new writer, so every callback identifies its run.
        guard stream === self.stream else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer), let writer else { return }
        // The writer can fail MID-recording — disk full is the common one. Until
        // now every later frame was silently dropped and the user only found out
        // when they pressed Stop and got nothing. Stop right there and say why,
        // so whatever was already written (fragments land every 5s) is kept.
        guard writer.status == .writing else {
            reportWriterFailure(writer)
            return
        }
        guard !paused else { return }   // dropped while paused

        switch type {
        case .screen:
            guard Self.isComplete(sampleBuffer),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            // The pause offset was already grown by the exact paused span in
            // resume(), so a straight subtract keeps the timeline continuous.
            var adjusted = CMTimeSubtract(pts, pauseOffset)
            // Belt-and-suspenders: output PTS must be strictly increasing.
            if let lastAdj = lastAdjustedPTS, adjusted <= lastAdj {
                adjusted = CMTimeAdd(lastAdj, frameDuration)
            }
            if !sessionStarted {
                writer.startSession(atSourceTime: adjusted)
                sessionStarted = true
            }
            guard videoInput?.isReadyForMoreMediaData == true else {
                droppedFrames += 1
                return
            }
            let needsGPU = !blurRectsPx.isEmpty || decorator != nil
            // Privacy blur must FAIL CLOSED: if GPU processing fails, drop the
            // frame rather than write the unblurred original.
            if needsGPU, let out = processed(pixelBuffer) {
                adaptor?.append(out, withPresentationTime: adjusted)
            } else if needsGPU {
                droppedFrames += 1
                return   // couldn't blur → don't leak the raw frame
            } else {
                adaptor?.append(pixelBuffer, withPresentationTime: adjusted)
            }
            appendedFrames += 1
            lastAppendedPTS = pts
            lastAdjustedPTS = adjusted
        case .audio:
            mixer?.append(sampleBuffer, from: .systemAudio)
        default:
            break
        }
    }

    /// Tell the user when a meaningful share of frames never made it into the
    /// file, with the one setting that fixes it. Below 2% is normal jitter and
    /// not worth a notification.
    private func reportDropsIfSignificant() {
        let total = appendedFrames + droppedFrames
        guard total > 0, droppedFrames > 0 else { return }
        let share = Double(droppedFrames) / Double(total)
        NSLog("SnapDesk: recorded \(appendedFrames) frames, dropped \(droppedFrames) (\(Int(share * 100))%)")
        guard share >= 0.02 else { return }
        let percent = Int((share * 100).rounded())
        DispatchQueue.main.async {
            Notifier.info("\(percent)% of frames were dropped",
                          "The encoder couldn't keep up. Try 30 fps, a smaller region, or the Medium quality preset.")
        }
    }

    /// Announce a mid-recording writer failure once, then finalize so the
    /// already-written fragments survive as a playable (short) file.
    private func reportWriterFailure(_ writer: AVAssetWriter) {
        guard !reportedFailure else { return }
        reportedFailure = true
        let error = writer.error as NSError?
        // Disk full is the failure worth naming — it's actionable.
        let outOfSpace = error?.domain == NSCocoaErrorDomain
            && (error?.code == NSFileWriteOutOfSpaceError
                || (error?.underlyingErrors.first as NSError?)?.code == NSFileWriteOutOfSpaceError)
        NSLog("SnapDesk: writer failed mid-recording — \(error?.localizedDescription ?? "unknown")")
        DispatchQueue.main.async {
            if outOfSpace {
                Notifier.error("Recording stopped — disk full",
                               "The video was saved up to the point the disk ran out. Free some space and record again.")
            } else {
                Notifier.error("Recording stopped",
                               "The video file couldn't be written any further. What was recorded so far is saved.")
            }
        }
        finalizeWriting()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SnapDesk: recording stream stopped: \(error)")
        queue.async { [weak self] in
            // The stream a restart just tore down can report its stop AFTER the
            // fresh run began. Finalizing then would end a recording that is one
            // frame old and hand the user an empty file.
            guard let self, stream === self.stream else { return }
            self.finalizeWriting()
        }
    }

    /// GPU pipeline: privacy blur + decorator effects → fresh pooled buffer.
    private func processed(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        var img = CIImage(cvPixelBuffer: pb)
        let bufH = CGFloat(CVPixelBufferGetHeight(pb))
        let bufW = CGFloat(CVPixelBufferGetWidth(pb))
        for r in blurRectsPx {
            // Top-left rect → CoreImage bottom-left coords.
            let ci = CGRect(x: r.minX, y: bufH - r.maxY, width: r.width, height: r.height)
            guard ci.width > 2, ci.height > 2 else { continue }
            let block = max(18, min(ci.width, ci.height) / 9)
            let pix = img.cropped(to: ci)
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: block,
                    kCIInputCenterKey: CIVector(x: ci.minX, y: ci.minY),
                ])
                .cropped(to: ci)
            img = pix.composited(over: img)
        }
        if let decorator {
            img = decorator.decorate(img, bufferSize: CGSize(width: bufW, height: bufH))
                .cropped(to: CGRect(x: 0, y: 0, width: bufW, height: bufH))
        }
        if blurPool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: CVPixelBufferGetWidth(pb),
                kCVPixelBufferHeightKey as String: CVPixelBufferGetHeight(pb),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &blurPool)
        }
        guard let pool = blurPool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }
        Self.ciContext.render(img, to: out)
        return out
    }

    /// Only append fully-rendered frames (skip idle/blank status frames).
    private static func isComplete(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = arr.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else { return false }
        return status == .complete
    }

    enum RecorderError: Error { case setup }
}
