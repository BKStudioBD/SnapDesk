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

    enum Err: Error, LocalizedError {
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

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true   // privacy: never leaves the Mac
        } else {
            // Server-based recognition caps at ~1 minute of audio — long
            // recordings would get silently truncated captions.
            let dur = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            if dur > 60 {
                await MainActor.run {
                    Notifier.info("Captions may be partial",
                                  "On-device speech isn't available for this language — only the first minute gets transcribed.")
                }
            }
        }

        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        let result: SFSpeechRecognitionResult? = try await withCheckedThrowingContinuation { c in
            recognizer.recognitionTask(with: request) { res, err in
                guard !once.done else { return }
                if let err {
                    once.done = true
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
                if let res, res.isFinal { once.done = true; c.resume(returning: res) }
            }
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
        return out.filter { !$0.text.isEmpty }
    }

    // MARK: - Burning

    /// Export a captioned copy to a temp file, then atomically replace the
    /// original — the video the user keeps IS the captioned one.
    static func burnInPlace(url: URL, lines: [Line]) async throws {
        let tmp = try await burn(url: url, lines: lines)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
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
        guard export.status == .completed else { throw export.error ?? Err.exportFailed }
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
