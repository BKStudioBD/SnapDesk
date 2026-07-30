import AVFoundation

/// Live microphone level for the pre-record meter, so "is my mic actually picking
/// me up" is answered BEFORE the countdown rather than after the upload.
///
/// It runs the same `MicCapture` the recording will run, through the same
/// noise-cancellation setting, so what the meter shows is what gets recorded.
///
/// It never asks for microphone permission: the pre-record panel appears before
/// the recording flow's own request, and a meter is not worth a surprise prompt.
/// Not-yet-authorized simply means no meter.
///
/// `start`/`stop` are main-thread only. Everything else lives on `queue`.
final class MicLevelMonitor {
    /// Fires on the MAIN thread, about 20× a second while audio flows.
    var onLevel: ((AudioLevel) -> Void)?

    private var capture: MicCapture?
    private let queue = DispatchQueue(label: "com.snapdesk.mic.level", qos: .userInitiated)
    /// Queue-confined.
    private var meter = AudioLevelMeter()
    /// Queue-confined.
    private let converter = AudioMixer.Converter()

    /// Counts starts so a `stop()` — or a second `start` — issued while a device is
    /// still spinning up can disown the capture it is waiting on. Main-thread only.
    private var startToken = 0

    /// Opens the microphone and reports on MAIN whether it worked. False means no
    /// meter should be shown — permission not granted yet, no device, or the capture
    /// refused to start.
    ///
    /// Returns IMMEDIATELY: the open itself (an AVCaptureDevice discovery pass, VPIO
    /// initialisation and a CoreAudio walk that queries every device's UID one at a
    /// time) runs 100–500 ms, and hundreds of milliseconds more on a machine with
    /// aggregate or virtual inputs. Doing that on the main thread made the
    /// pre-record bar appear late and froze the panel on every mic / noise-
    /// cancellation click with the button stuck in its old state — the very rule
    /// `MicCapture`'s raw path already follows for `startRunning()`.
    func start(deviceID: String, noiseCancellation: Bool, onReady: @escaping (Bool) -> Void) {
        guard capture == nil else { onReady(true); return }
        // Cheap and main-safe, and it must stay before the hop: an unauthorized mic
        // has to answer "no meter" without opening anything at all.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            onReady(false)
            return
        }
        let capture = MicCapture { [weak self] sampleBuffer in
            guard let self else { return }
            // The voice-processing backend taps on the audio engine's render
            // thread, so hop before touching the meter or the converter.
            self.queue.async { self.measure(sampleBuffer) }
        }
        self.capture = capture
        startToken += 1
        let token = startToken
        let queue = self.queue
        queue.async { [weak self] in
            var opened = false
            if let device = MicCapture.device(forID: deviceID) {
                do {
                    try capture.start(device: device, queue: queue,
                                      noiseCancellation: noiseCancellation)
                    opened = true
                } catch {
                    NSLog("SnapDesk: mic level monitor couldn't start: \(error)")
                }
            }
            DispatchQueue.main.async {
                // Stopped (or restarted) while the device was spinning up: this
                // capture belongs to nobody now, and leaving it running would keep
                // the system's orange mic indicator lit for no meter at all.
                guard let self, self.startToken == token else {
                    if opened { queue.async { capture.stop() } }
                    return
                }
                if !opened { self.capture = nil }
                onReady(opened)
            }
        }
    }

    func stop() {
        guard let capture else { return }
        self.capture = nil
        // Disown any start still in flight — see `startToken`.
        startToken += 1
        // Tear down ON THE SAME QUEUE the start runs on. A stop dispatched straight
        // to `MicCapture.control` could otherwise be enqueued there BEFORE the
        // pending start and then be undone by it, leaving the microphone live.
        queue.async { [weak self] in
            capture.stop()
            self?.meter = AudioLevelMeter()
        }
        // The bar must fall to zero, not freeze at whatever it last showed.
        onLevel?(.silent)
    }

    private func measure(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = converter.converted(sampleBuffer),
              let level = meter.accumulate(pcm) else { return }
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }
}
