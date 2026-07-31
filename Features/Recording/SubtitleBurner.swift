import AVFoundation
import Speech
import AppKit

/// Burns automatic subtitles into a finished recording — fully on-device.
/// Pipeline: SFSpeechRecognizer (on-device when supported) transcribes the
/// movie's audio → word segments grouped into caption lines → CATextLayers
/// composited over the video (AVVideoCompositionCoreAnimationTool) → exported
/// as "<name> subtitled.mov" next to the original.
enum SubtitleBurner {
    struct Line { let text: String; let start: TimeInterval; let end: TimeInterval }

    enum Err: Error, LocalizedError, Equatable {
        case notAuthorized, unavailable, noVideoTrack, exportFailed
        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Speech recognition permission was not granted."
            case .unavailable:   "Speech recognition is unavailable for this language."
            case .noVideoTrack:  "The recording has no video track."
            case .exportFailed:  "Couldn't export the subtitled video."
            }
        }
    }

    /// Transcribe + burn IN PLACE: the captions are written into the recording
    /// itself (the original file is replaced — no separate "subtitled" copy).
    /// `language` = BCP-47 code of the SPOKEN language (en-US / es-ES / de-DE…).
    /// Returns true when captions were added, false when there was no speech.
    static func process(url: URL, language: String = "en-US") async throws -> Bool {
        let lines = try await transcribe(url: url, language: language)
        guard !lines.isEmpty else { return false }
        try await burnInPlace(url: url, lines: lines)
        return true
    }

    // MARK: - Transcription

    static func transcribe(url: URL, language: String = "en-US") async throws -> [Line] {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw Err.notAuthorized }
        // Transcribe in the user-chosen spoken language (Settings → Recording),
        // independent of the Mac's system language.
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.isAvailable else { throw Err.unavailable }

        // Captions are on-device ONLY. If Apple's on-device model for this
        // language isn't installed, the alternative is uploading the whole audio
        // track to Apple's speech servers — which would break SnapDesk's core
        // "100% on-device, never touches the network" promise silently. Refuse
        // instead: the recording is still saved, just without captions.
        guard recognizer.supportsOnDeviceRecognition else { throw Err.unavailable }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true   // privacy: never leaves the Mac

        // The recognition callback can fire on multiple threads and more than
        // once; the continuation must be resumed EXACTLY once. A plain Bool read
        // across threads is a race — gate with a lock that atomically claims the
        // single resume.
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        /// Holds the recognition task so cancelling the surrounding Task can
        /// reach it — the returned task was previously discarded outright.
        final class HeldTask: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: SFSpeechRecognitionTask?
            var task: SFSpeechRecognitionTask? {
                get { lock.lock(); defer { lock.unlock() }; return stored }
                set { lock.lock(); stored = newValue; lock.unlock() }
            }
        }
        let once = Once()
        // The task has to be retained and cancellable. `Once` guarantees the
        // continuation is resumed at most once — nothing guaranteed it was
        // resumed at ALL: if the handler never delivered `isFinal` or an error
        // (recognizer released mid-transcription, or the task dropped), the
        // caller suspended forever and the finished recording simply never
        // appeared — no preview window, no error, no file offered.
        let held = HeldTask()
        let result: SFSpeechRecognitionResult? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                held.task = recognizer.recognitionTask(with: request) { res, err in
                    if let err {
                        guard once.claim() else { return }
                        // "No speech detected" is a NORMAL outcome for a silent
                        // recording — return no lines instead of an error dialog.
                        let ns = err as NSError
                        if ns.domain == "kAFAssistantErrorDomain" && (ns.code == 1110 || ns.code == 203) {
                            c.resume(returning: nil)
                        } else {
                            c.resume(throwing: err)
                        }
                        return
                    }
                    if let res, res.isFinal, once.claim() { c.resume(returning: res) }
                }
            }
        } onCancel: {
            held.task?.cancel()
        }
        guard let transcription = result?.bestTranscription else { return [] }
        return lines(from: transcription)
    }

    /// Group word segments into readable caption lines (~7 words / 4s / gaps).
    private static func lines(from t: SFTranscription) -> [Line] {
        var out: [Line] = []
        var cur: [SFTranscriptionSegment] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            let text = cur.map(\.substring).joined(separator: " ")
            out.append(Line(text: text, start: f.timestamp, end: l.timestamp + l.duration + 0.2))
            cur = []
        }
        for seg in t.segments {
            if let last = cur.last {
                let gap = seg.timestamp - (last.timestamp + last.duration)
                let span = seg.timestamp + seg.duration - (cur.first?.timestamp ?? 0)
                if gap > 0.8 || cur.count >= 7 || span > 4.0 { flush() }
            }
            cur.append(seg)
        }
        flush()
        let grouped = out.filter { !$0.text.isEmpty }
        // Clamp every line to where the NEXT one starts. A group is flushed on word
        // count or elapsed span at least as often as on a pause, so the +0.2 s
        // reading tail routinely runs past the following caption's start — and both
        // pills are drawn in the same place, so the overlap rendered one line of
        // text on top of another. Burned into the file, permanently.
        return grouped.enumerated().map { index, line in
            guard index + 1 < grouped.count else { return line }
            return Line(text: line.text, start: line.start,
                        end: min(line.end, grouped[index + 1].start))
        }
    }

    // MARK: - Burning

    /// Export a captioned copy to a temp file, then atomically replace the
    /// original — the video the user keeps IS the captioned one.
    static func burnInPlace(url: URL, lines: [Line]) async throws {
        let tmp = try await burn(url: url, lines: lines)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            // replaceItemAt consumes the temp file only on success. A failure here
            // leaves a full second copy of the recording in /tmp with nothing
            // pointing at it — gigabytes for a long take.
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    static func burn(url: URL, lines: [Line]) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw Err.noVideoTrack
        }
        let size = try await videoTrack.load(.naturalSize)
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        composition.renderSize = size

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: size)
        let parent = CALayer()
        parent.frame = videoLayer.frame
        parent.addSublayer(videoLayer)
        for line in lines { parent.addSublayer(captionLayer(line, canvas: size)) }
        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)

        // Temp export target (can't write over the asset we're reading).
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapDesk-captions-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: out)

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw Err.exportFailed
        }
        export.outputURL = out
        export.outputFileType = .mov
        export.videoComposition = composition
        await export.export()
        guard export.status == .completed else {
            // A failed export still wrote whatever it got through — the same dead
            // weight in /tmp, on the path that runs after every captioned take.
            try? FileManager.default.removeItem(at: out)
            throw export.error ?? Err.exportFailed
        }
        return out
    }

    /// One caption: rounded dark pill with bold white text, faded in/out via a
    /// keyframe animation pinned to the video timeline.
    private static func captionLayer(_ line: Line, canvas: CGSize) -> CALayer {
        let fontSize = max(18, canvas.height * 0.045)
        let width = canvas.width * 0.9
        let height = fontSize * 2.6

        let text = CATextLayer()
        text.string = line.text
        text.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        text.fontSize = fontSize
        text.foregroundColor = NSColor.white.cgColor
        text.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        text.cornerRadius = fontSize * 0.35
        text.masksToBounds = true
        text.alignmentMode = .center
        text.isWrapped = true
        text.truncationMode = .end
        text.contentsScale = 2
        text.frame = CGRect(x: (canvas.width - width) / 2, y: canvas.height * 0.05,
                            width: width, height: height)
        text.opacity = 0

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        let dur = max(0.4, line.end - line.start)
        anim.values = [0, 1, 1, 0]
        anim.keyTimes = [0, NSNumber(value: min(0.15, 0.12 / dur)), NSNumber(value: 1 - min(0.15, 0.12 / dur)), 1]
        anim.beginTime = AVCoreAnimationBeginTimeAtZero + line.start
        anim.duration = dur
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        text.add(anim, forKey: "fade")
        return text
    }
}
