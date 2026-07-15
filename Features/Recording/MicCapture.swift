import AVFoundation

/// Microphone capture for screen recordings. Wraps an AVCaptureSession with an
/// audio-data output and hands compressed-ready CMSampleBuffers (host-time
/// clock, same timebase as ScreenCaptureKit) to the recorder's queue.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private var disconnectObserver: NSObjectProtocol?
    var onSample: ((CMSampleBuffer) -> Void)?

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

    func start(device: AVCaptureDevice, queue: DispatchQueue) throws {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Err.setup }
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw Err.setup }
        session.addOutput(output)
        // Tell the user if their mic is yanked mid-recording — otherwise they
        // narrate a whole video into nothing and only find out afterwards.
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
        ) { note in
            guard let gone = note.object as? AVCaptureDevice, gone.uniqueID == device.uniqueID else { return }
            Notifier.error("Microphone disconnected",
                           "The recording continues without your voice.")
        }
        // startRunning() is slow (device spin-up) — never block the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    func stop() {
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        disconnectObserver = nil
        // NO isRunning guard: if stop() lands before the queued startRunning
        // executes, the guard would skip → mic stays on forever (privacy).
        // stopRunning() is a safe no-op when idle.
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onSample?(sampleBuffer)
    }

    enum Err: Error { case setup }
}
