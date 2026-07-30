import AVFoundation
import CoreAudio

/// Microphone capture for screen recordings. Hands CMSampleBuffers stamped on the
/// HOST TIME clock — the same timebase ScreenCaptureKit uses — to the recorder's
/// queue, so voice lines up with picture without any correction.
///
/// Two backends:
///
///  * **Voice** (default) — `AVAudioEngine` with Apple's Voice Processing I/O
///    enabled: real-time **noise suppression, echo cancellation and automatic
///    gain control**, the same processing FaceTime uses. This is the only way to
///    get Apple-grade noise cancellation on a capture path; `AVCaptureSession`
///    exposes no equivalent.
///  * **Raw** — plain `AVCaptureSession`, used when the user turns noise
///    cancellation off, and as an automatic fallback if voice processing refuses
///    to start on this device (it does on some aggregate/virtual inputs). Falling
///    back beats recording silence.
///
/// `@unchecked Sendable` is justified narrowly: `onSample` is a `let` injected at
/// init (the audio thread only reads it), `disconnectObserver` is main-thread
/// only, and every session start/stop is serialized on `control`.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// `let`, not `var`: the audio thread reads this on every buffer, so a
    /// reassignment from another thread would be a race.
    private let onSample: (CMSampleBuffer) -> Void

    // Raw backend.
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    // Voice backend.
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    private var disconnectObserver: NSObjectProtocol?
    private(set) var usingNoiseCancellation = false

    init(onSample: @escaping (CMSampleBuffer) -> Void) {
        self.onSample = onSample
        super.init()
    }

    /// All available microphones.
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }

    /// Device for a saved uniqueID; empty/unknown falls back to the default mic.
    static func device(forID id: String) -> AVCaptureDevice? {
        if !id.isEmpty, let d = devices().first(where: { $0.uniqueID == id }) { return d }
        return AVCaptureDevice.default(for: .audio)
    }

    // MARK: - Start / stop

    /// - Parameter noiseCancellation: prefer the voice-processing backend. Falls
    ///   back to raw capture automatically if it can't be started.
    func start(device: AVCaptureDevice, queue: DispatchQueue, noiseCancellation: Bool) throws {
        watchForDisconnect(of: device)
        if noiseCancellation, startVoiceEngine(device: device) {
            usingNoiseCancellation = true
            return
        }
        if noiseCancellation {
            NSLog("SnapDesk: voice processing unavailable on \(device.localizedName) — recording raw mic")
        }
        try startRawCapture(device: device, queue: queue)
    }

    func stop() {
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        disconnectObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            Self.control.async { engine.stop() }
            self.engine = nil
        }
        // Same serial queue → guaranteed to run AFTER the start above.
        // stopRunning() is a safe no-op when idle, so no isRunning guard.
        Self.control.async { [session] in session.stopRunning() }
    }

    /// Suspend/resume capture for a recording pause. Without this the mic keeps
    /// running while every sample is thrown away — wasted CPU, and the system's
    /// orange mic indicator stays lit, which reads as "still recording my voice".
    func setPaused(_ paused: Bool) {
        if let engine {
            Self.control.async { paused ? engine.pause() : try? engine.start() }
            return
        }
        Self.control.async { [session] in
            if paused { session.stopRunning() } else { session.startRunning() }
        }
    }

    /// Serializes session start/stop so they can never execute out of order:
    /// two `.global()` blocks have NO ordering guarantee, so a stop issued moments
    /// after a start could run FIRST and then be undone by the late start —
    /// leaving the microphone live until the app quits.
    private static let control = DispatchQueue(label: "com.snapdesk.mic.control", qos: .userInitiated)

    /// Tell the user if their mic is yanked mid-recording — otherwise they narrate
    /// a whole video into nothing and only find out afterwards.
    private func watchForDisconnect(of device: AVCaptureDevice) {
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
        ) { note in
            guard let gone = note.object as? AVCaptureDevice, gone.uniqueID == device.uniqueID else { return }
            Notifier.error("Microphone disconnected",
                           "The recording continues without your voice.")
        }
    }

    // MARK: - Voice backend (noise cancellation)

    /// True when the engine started with voice processing active.
    private func startVoiceEngine(device: AVCaptureDevice) -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Point the AUHAL at the user's chosen mic BEFORE enabling processing —
        // the unit reconfigures around the device.
        if let unit = input.audioUnit, let id = Self.audioDeviceID(forUID: device.uniqueID) {
            var deviceID = id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &deviceID,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            NSLog("SnapDesk: setVoiceProcessingEnabled failed: \(error)")
            return false
        }
        input.isVoiceProcessingAGCEnabled = true
        // Don't duck the audio we're also recording — ducking would pump the
        // system-audio track every time the user speaks.
        var ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
        ducking.duckingLevel = .min
        input.voiceProcessingOtherAudioDuckingConfiguration = ducking

        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0,
              // 48 kHz mono Int16 interleaved: what the AAC encoder wants, and
              // voice is mono after processing anyway.
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                         channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: tapFormat, to: target) else { return false }
        targetFormat = target
        converter = conv

        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, when in
            self?.deliver(buffer, at: when)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("SnapDesk: audio engine start failed: \(error)")
            input.removeTap(onBus: 0)
            return false
        }
        self.engine = engine
        return true
    }

    /// Convert one processed PCM buffer and hand it on, stamped on the host clock.
    private func deliver(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        guard let converter, let targetFormat else { return }
        // Frame count scales with the sample-rate ratio.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }
        // AVAudioTime.hostTime is mach-absolute — the same clock ScreenCaptureKit
        // stamps its buffers on, so no offset correction is needed anywhere.
        let pts = CMClockMakeHostTimeFromSystemUnits(when.hostTime)
        if let sb = Self.sampleBuffer(from: out, at: pts) { onSample(sb) }
    }

    /// PCM buffer → CMSampleBuffer the asset writer can take.
    /// Internal (not private) so the unit tests can exercise it without a mic.
    static func sampleBuffer(from buffer: AVAudioPCMBuffer, at pts: CMTime) -> CMSampleBuffer? {
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: buffer.format.streamDescription,
                                             layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        // ONE sample-size entry = "every sample is this many bytes" (the CBR form).
        // Passing none is legal for constant-bitrate PCM, but some writer inputs
        // want the size stated; stating it costs nothing and removes the doubt.
        var sampleSize = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
                                   dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format,
                                   sampleCount: CMItemCount(buffer.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                   sampleBufferOut: &sb) == noErr,
              let sb else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sb, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: buffer.mutableAudioBufferList) == noErr else { return nil }
        return sb
    }

    /// CoreAudio device id for an `AVCaptureDevice.uniqueID` (they are the same
    /// UID string for audio devices). nil → leave the engine on the system default.
    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            // `Unmanaged`, not `CFString?`: forming a raw pointer to an optional
            // OBJECT reference is undefined (the compiler warns). Unmanaged is a
            // trivial pointer wrapper, which is what CoreAudio actually writes.
            // kAudioDevicePropertyDeviceUID returns a +1 object — hence *Retained*.
            var cfUID: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let ok = withUnsafeMutablePointer(to: &cfUID) { ptr in
                AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, ptr)
            }
            guard ok == noErr, let found = cfUID?.takeRetainedValue() else { continue }
            if found as String == uid { return id }
        }
        return nil
    }

    // MARK: - Raw backend

    private func startRawCapture(device: AVCaptureDevice, queue: DispatchQueue) throws {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Err.setup }
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw Err.setup }
        session.addOutput(output)
        // startRunning() is slow (device spin-up) — never block the main thread.
        Self.control.async { [session] in session.startRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onSample(sampleBuffer)
    }

    enum Err: Error { case setup }
}
