import Testing
import Foundation
@testable import SnapDeskCore

/// The store's own logic. The parsing, the caps, the presets.
///
/// Every store here is built on its own throwaway suite and the suite is removed
/// afterwards, so nothing touches the preferences of whoever runs the tests.
/// That is exactly why the initialiser takes a `UserDefaults`.
struct SettingsStoreTests {

    /// A store on a private suite, plus the teardown that removes it.
    private func makeStore() throws -> (store: SettingsStore, cleanup: () -> Void) {
        let name = "snapdesk-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (SettingsStore(defaults: defaults),
                { defaults.removePersistentDomain(forName: name) })
    }

    // MARK: - Custom words

    @Test("Custom words split on commas AND newlines, trimmed, with the blanks dropped")
    func parsesCustomWords() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.ocrCustomWordsText = "Klaviyo, SnapDesk\n  Omnisend  ,,\n\nBKStudio\r"
        #expect(store.ocrCustomWords == ["Klaviyo", "SnapDesk", "Omnisend", "BKStudio"])
    }

    @Test("No custom words means an empty list, not a list holding one empty string")
    func emptyCustomWords() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.ocrCustomWordsText = "   \n , \n"
        #expect(store.ocrCustomWords.isEmpty)
    }

    @Test("Custom words reach the recognizer's options")
    func customWordsReachOCROptions() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.ocrCustomWordsText = "Klaviyo"
        #expect(store.ocrOptions.customWords == ["Klaviyo"])
    }

    // MARK: - Recent colours

    @Test("A pick goes to the front, and picking it again moves it rather than duplicating it")
    func recentColorsMoveToFront() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.addRecentColor("#FF0000")
        store.addRecentColor("#00FF00")
        store.addRecentColor("#FF0000")
        #expect(store.recentColors == ["#FF0000", "#00FF00"])
    }

    @Test("The list stops at sixteen. The oldest pick falls off the end", .tags(.regression))
    func recentColorsAreCapped() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        for i in 0..<20 { store.addRecentColor(String(format: "#0000%02X", i)) }
        #expect(store.recentColors.count == 16)
        #expect(store.recentColors.first == "#000013")     // the 20th, newest
        #expect(store.recentColors.contains("#000000") == false)   // the 1st, dropped
    }

    // MARK: - Recording presets

    @Test("Tutorial records both audio sources and turns the presenter effects on")
    func tutorialPreset() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.apply(.tutorial)
        #expect(store.recordFPS == 60)
        #expect(store.recordSystemAudio)
        #expect(store.recordMic)
        #expect(store.recordCamera == false)
        #expect(store.recordCursorBoost)
        #expect(store.recordClickHighlight)
        #expect(store.recordKeystrokes)
    }

    @Test("Silent demo takes the audio away and leaves nothing recording sound")
    func silentDemoPreset() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.apply(.tutorial)          // start from the noisiest one
        store.apply(.silentDemo)
        #expect(store.recordSystemAudio == false)
        #expect(store.recordMic == false)
        #expect(store.recordSubtitles == false)
    }

    @Test("A preset leaves the output settings alone. They aren't its business")
    func presetsLeaveOutputAlone() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.recordHEVC = true
        store.recordCountdown = 5
        store.recordBlurEnabled = true
        store.apply(.meeting)
        #expect(store.recordHEVC)
        #expect(store.recordCountdown == 5)
        #expect(store.recordBlurEnabled)
    }

    // MARK: - Persistence

    @Test("What was set comes back on the next launch")
    func settingsSurviveARelaunch() throws {
        let name = "snapdesk-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let first = SettingsStore(defaults: defaults)
        first.ocrCustomWordsText = "Klaviyo"
        first.addRecentColor("#ABCDEF")
        first.recordFPS = 60

        let second = SettingsStore(defaults: defaults)
        #expect(second.ocrCustomWords == ["Klaviyo"])
        #expect(second.recentColors == ["#ABCDEF"])
        #expect(second.recordFPS == 60)
    }

    @Test("The text stack starts OFF every launch, whatever the last session did",
          .tags(.regression))
    func textStackNeverPersists() throws {
        let name = "snapdesk-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let first = SettingsStore(defaults: defaults)
        first.ocrStackActive = true
        // A collect mode that survives a relaunch is a mode you forget is on,
        // and every later grab silently glues onto the last one.
        #expect(SettingsStore(defaults: defaults).ocrStackActive == false)
    }
}
