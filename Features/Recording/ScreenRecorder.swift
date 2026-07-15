import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage

/// Records a display (or a region of it) to an H.264 .mov via ScreenCaptureKit +
/// AVAssetWriter. Optional system audio. Supports pause/resume by shifting
/// presentation timestamps, so the paused wall-clock time is cut out of the
/// movie instead of appearing as a frozen gap. SnapDesk's own windows (control
/// bar, region border) are excluded from the capture. Frame delivery + writing
/// happen on a private serial queue; control methods are main-thread.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var micCapture: MicCapture?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var outputURL: URL?
    private let queue = DispatchQueue(label: "com.snapdesk.recorder")

    // Pause bookkeeping (queue-confined).
    private var paused = false
    private var needsResumeSync = false
    private var pauseOffset = CMTime.zero
    private var lastAppendedPTS: CMTime?
    /// Queue-confined: guards against finalizing twice (stop() racing
    /// didStopWithError would otherwise call finishWriting twice → crash).
    private var finalized = false

    // Privacy blur: regions (pixel coords, top-left origin, relative to the
    // output frame) pixelated on every frame via GPU CoreImage.
    private var blurRectsPx: [CGRect] = []
    private var blurPool: CVPixelBufferPool?
    private var decorator: FrameDecorator?
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private(set) var isRecording = false
    /// Called on the main thread when writing finishes (URL = file, or nil on failure).
    var onFinish: ((URL?) -> Void)?

    // MARK: - Control

    @MainActor
    func start(display: SCDisplay, filter: SCContentFilter, sourceRect: CGRect?, scale: CGFloat,
               captureAudio: Bool, micDevice: AVCaptureDevice?,
               fps: Int = 60, codec: AVVideoCodecType = .h264,
               bitsPerPixel: Double? = nil, showCursor: Bool = true,
               blurRectsPx: [CGRect] = [], decorator: FrameDecorator? = nil, url: URL) throws {
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
        // Quality preset → explicit average bitrate (nil = encoder default).
        if let bpp = bitsPerPixel {
            let bitrate = Int(Double(config.width * config.height) * bpp * Double(fps))
            videoSettings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: bitrate]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard writer.canAdd(videoInput) else { throw RecorderError.setup }
        writer.add(videoInput)

        func makeAACInput() -> AVAssetWriterInput {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 128_000,
            ])
            ai.expectsMediaDataInRealTime = true
            return ai
        }

        var audioInput: AVAssetWriterInput?
        if captureAudio {
            let ai = makeAACInput()
            if writer.canAdd(ai) { writer.add(ai); audioInput = ai }
        }

        // Second audio track: the microphone. Mic failure is non-fatal — the
        // screen recording continues without voice.
        var micInput: AVAssetWriterInput?
        var micCapture: MicCapture?
        if let micDevice {
            let mi = makeAACInput()
            if writer.canAdd(mi) {
                writer.add(mi)
                let mc = MicCapture()
                mc.onSample = { [weak self] sb in self?.appendMic(sb) }
                do {
                    try mc.start(device: micDevice, queue: queue)
                    micInput = mi
                    micCapture = mc
                } catch {
                    NSLog("SnapDesk: mic capture failed: \(error)")
                }
            }
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if captureAudio { try? stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.micInput = micInput
        self.micCapture = micCapture
        self.adaptor = adaptor
        self.outputURL = url
        self.sessionStarted = false
        self.paused = false
        self.needsResumeSync = false
        self.pauseOffset = .zero
        self.lastAppendedPTS = nil
        self.finalized = false
        self.blurRectsPx = blurRectsPx
        self.blurPool = nil
        self.decorator = decorator

        writer.startWriting()
        isRecording = true
        stream.startCapture { [weak self] error in
            if let error {
                NSLog("SnapDesk: recording start failed: \(error)")
                // Tear down on the recorder queue — the stream callback thread
                // must not nil writer/inputs while didOutputSampleBuffer runs.
                self?.queue.async { self?.finish(success: false) }
            }
        }
        self.stream = stream
    }

    func pause()  { queue.async { self.paused = true } }
    func resume() { queue.async { self.paused = false; self.needsResumeSync = true } }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        micCapture?.stop()
        DispatchQueue.main.async { [decorator] in decorator?.stop() }
        stream?.stopCapture { [weak self] _ in
            self?.queue.async { self?.finalizeWriting() }
        }
    }

    /// Mic sample arriving on the recorder queue → retime + append (2nd track).
    private func appendMic(_ sb: CMSampleBuffer) {
        // needsResumeSync: the pause offset is stale until the first complete
        // video frame recomputes it — audio appended now would jump a full
        // pause-length ahead and then go non-monotonic (writer failure).
        guard !paused, !needsResumeSync, sessionStarted, let writer, writer.status == .writing,
              micInput?.isReadyForMoreMediaData == true else { return }
        if pauseOffset == .zero {
            micInput?.append(sb)
        } else if let shifted = Self.retimed(sb, by: pauseOffset) {
            micInput?.append(shifted)
        }
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
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        micInput?.markAsFinished()
        let url = outputURL
        writer?.finishWriting { [weak self] in
            let ok = self?.writer?.status == .completed
            DispatchQueue.main.async { self?.onFinish?(ok ? url : nil) }
            self?.cleanup()
        }
    }

    private func finish(success: Bool) {
        guard !finalized else { return }   // finalizeWriting() may have run first
        isRecording = false
        finalized = true
        writer?.cancelWriting()
        let url = success ? outputURL : nil
        DispatchQueue.main.async { self.onFinish?(url) }
        cleanup()
    }

    private func cleanup() {
        micCapture?.stop()
        DispatchQueue.main.async { [decorator] in decorator?.stop() }
        stream = nil; writer = nil; videoInput = nil; audioInput = nil; adaptor = nil
        micInput = nil; micCapture = nil
        decorator = nil; blurPool = nil        // release the effects pipeline too
        outputURL = nil; sessionStarted = false
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let writer, writer.status == .writing else { return }
        guard !paused else { return }   // dropped while paused

        switch type {
        case .screen:
            guard Self.isComplete(sampleBuffer),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            // First frame after a resume: grow the offset by the gap we skipped,
            // so the output timeline stays continuous.
            if needsResumeSync {
                if let last = lastAppendedPTS {
                    pauseOffset = CMTimeAdd(pauseOffset, CMTimeSubtract(pts, last))
                }
                needsResumeSync = false
            }
            let adjusted = CMTimeSubtract(pts, pauseOffset)
            if !sessionStarted {
                writer.startSession(atSourceTime: adjusted)
                sessionStarted = true
            }
            if videoInput?.isReadyForMoreMediaData == true {
                let needsGPU = !blurRectsPx.isEmpty || decorator != nil
                let out = needsGPU ? (processed(pixelBuffer) ?? pixelBuffer) : pixelBuffer
                adaptor?.append(out, withPresentationTime: adjusted)
                lastAppendedPTS = pts
            }
        case .audio:
            // Same stale-offset guard as appendMic (see there).
            guard sessionStarted, !needsResumeSync,
                  audioInput?.isReadyForMoreMediaData == true else { return }
            if pauseOffset == .zero {
                audioInput?.append(sampleBuffer)
            } else if let shifted = Self.retimed(sampleBuffer, by: pauseOffset) {
                audioInput?.append(shifted)
            }
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SnapDesk: recording stream stopped: \(error)")
        queue.async { [weak self] in self?.finalizeWriting() }
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

    /// Copy of `sb` with all timestamps shifted earlier by `offset`.
    private static func retimed(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for i in 0..<infos.count {
            infos[i].presentationTimeStamp = CMTimeSubtract(infos[i].presentationTimeStamp, offset)
            if infos[i].decodeTimeStamp.isValid {
                infos[i].decodeTimeStamp = CMTimeSubtract(infos[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb,
                                              sampleTimingEntryCount: count, sampleTimingArray: infos,
                                              sampleBufferOut: &out)
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
