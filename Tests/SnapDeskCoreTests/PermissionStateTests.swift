import Testing
@testable import SnapDeskCore

/// What the five capture features are allowed to do, and what the menu bar is
/// told to say about it.
///
/// The bug this locks: the state has to be decided by EVIDENCE. Refusing every
/// capture because the grant arrived after launch left a menu-bar app that had
/// been up for two and a half days declining to even try, forever. Deciding it
/// on a blank frame instead means the app tries, reports only what it actually
/// saw, and recovers on its own the moment a capture works again.
struct PermissionStateTests {

    @Test("A grant with nothing against it is ready, whenever it arrived")
    func grantWithoutEvidenceIsReady() {
        // The old rule said no here whenever the grant post-dated launch, and
        // that refusal was the bug: it never expired.
        #expect(Permissions.state(hasGrant: true, blankCaptureSeen: false) == .ready)
    }

    @Test("A blank frame under a live grant asks for a restart")
    func blankFrameNeedsRestart() {
        // Preflight says yes and the screen came back empty. That pair, and
        // only that pair, means this process is not really allowed to capture.
        #expect(Permissions.state(hasGrant: true, blankCaptureSeen: true) == .needsRestart)
    }

    @Test("No grant asks for the grant, whatever was seen",
          arguments: [true, false])
    func noGrantNeedsGrant(_ blankSeen: Bool) {
        #expect(Permissions.state(hasGrant: false, blankCaptureSeen: blankSeen) == .needsGrant)
    }

    @Test("Every state says something, and no two say the same thing")
    func summariesAreDistinct() {
        let states: [Permissions.CaptureState] = [.ready, .needsGrant, .needsRestart]
        let summaries = states.map(\.summary)
        #expect(summaries.allSatisfy { !$0.isEmpty })
        #expect(Set(summaries).count == states.count)
    }
}
