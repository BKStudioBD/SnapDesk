import Foundation

/// Why the webcam bubble isn't there.
///
/// Every one of these used to be a bare `return` inside `FrameDecorator`: no
/// device, a device another app had already claimed, an output the session
/// refused. The bubble simply never appeared, on screen or in the video, and
/// nothing said why — which reads as "the camera is broken". Each case carries
/// the sentence the user needs, and the mapping is pure so it can be checked
/// without a camera attached.
///
/// None of these stop the recording: the screen keeps being captured, only the
/// bubble is missing. Every message says so, because the alternative — a scary
/// notification mid-recording — makes people stop a take that was fine.
enum CameraProblem: String, CaseIterable, Equatable {
    /// No video device at all: no built-in camera, nothing plugged in.
    case noDevice
    /// The device exists but wouldn't open. In practice: another app has it.
    case busy
    /// The session refused our input or output, so there is nothing to show.
    case rejected
    /// The session opened and then never delivered a frame. A Continuity Camera
    /// with the phone asleep, and virtual cameras whose host app isn't running,
    /// both land here.
    case noFrames
    /// The camera went away mid-recording — unplugged, or lid closed on a
    /// display that owned it.
    case disconnected
    /// AVFoundation reported a runtime error on the session.
    case runtimeError

    var title: String {
        switch self {
        case .noDevice: "No camera found"
        case .busy, .rejected, .runtimeError: "Camera unavailable"
        case .noFrames: "Camera sent no video"
        case .disconnected: "Camera disconnected"
        }
    }

    /// True when the camera died in the middle of a take, which deserves the
    /// louder alert. A camera that never opened is just information — the user
    /// hasn't lost anything they had.
    var isDisruption: Bool { self == .disconnected || self == .runtimeError }

    var body: String {
        switch self {
        case .noDevice:
            "No webcam is connected, so the bubble is off. The screen is still being recorded."
        case .busy:
            "Another app is using the camera — quit it and record again. The screen is still being recorded."
        case .rejected:
            "This camera couldn't be used for the bubble. The screen is still being recorded."
        case .noFrames:
            "The camera opened but sent no picture. If it's your iPhone, wake it; if it's a virtual camera, start its app. The screen is still being recorded."
        case .disconnected:
            "The camera was disconnected, so the bubble stopped. The screen is still being recorded."
        case .runtimeError:
            "The camera stopped working, so the bubble is gone. The screen is still being recorded."
        }
    }
}
