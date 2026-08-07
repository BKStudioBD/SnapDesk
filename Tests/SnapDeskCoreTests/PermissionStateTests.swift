import Testing
@testable import SnapDeskCore

/// What the five capture features are allowed to do, and what the menu bar is
/// told to say about it.
///
/// The bug this locks: a Screen Recording grant that arrives AFTER the process
/// started reads as allowed to `CGPreflightScreenCaptureAccess`, while the
/// capture engine is still running on the launch-time answer and returns blank
/// frames. Treating that as "ready" is how ⌃1, ⌃2, ⌃5, ⌃6 and ⌃7 came to fail
/// with nothing on screen to explain it.
struct PermissionStateTests {

    @Test("Granted before launch is the only state that captures")
    func onlyALaunchTimeGrantIsReady() {
        #expect(Permissions.state(hasGrant: true, grantedAtLaunch: true) == .ready)
    }

    @Test("A grant that arrived after launch asks for a restart, not a capture")
    func lateGrantNeedsRestart() {
        // Preflight says yes here. Believing it is the failure.
        #expect(Permissions.state(hasGrant: true, grantedAtLaunch: false) == .needsRestart)
    }

    @Test("No grant asks for the grant, whatever launch looked like",
          arguments: [true, false])
    func noGrantNeedsGrant(_ atLaunch: Bool) {
        #expect(Permissions.state(hasGrant: false, grantedAtLaunch: atLaunch) == .needsGrant)
    }

    @Test("Every state says something, and no two say the same thing")
    func summariesAreDistinct() {
        let states: [Permissions.CaptureState] = [.ready, .needsGrant, .needsRestart]
        let summaries = states.map(\.summary)
        #expect(summaries.allSatisfy { !$0.isEmpty })
        #expect(Set(summaries).count == states.count)
    }
}
