import AppKit

/// Plays a named feedback sound. Resolves in order: bundled custom sound
/// (Resources/Sounds/<name>.wav) → named NSSound → system sound file. Instances
/// are cached and retriggered, so rapid clicks stay snappy.
enum Sounds {
    private static var cache: [String: NSSound] = [:]

    static func play(_ name: String) {
        guard let s = sound(for: name) else { return }
        s.stop()      // retrigger if still playing
        s.play()
    }

    private static func sound(for name: String) -> NSSound? {
        if let cached = cache[name] { return cached }
        var snd: NSSound?
        if let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: name, withExtension: "wav") {
            snd = NSSound(contentsOf: url, byReference: true)
        }
        if snd == nil { snd = NSSound(named: name) }
        if snd == nil {
            snd = NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)
        }
        cache[name] = snd
        return snd
    }
}
