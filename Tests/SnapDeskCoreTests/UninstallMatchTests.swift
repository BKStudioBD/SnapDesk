import Testing
import Foundation
@testable import SnapDeskCore

/// Which files an uninstall claims. Every rule here was written because a looser
/// version once matched a file belonging to something else, and an uninstaller
/// that takes the wrong folder is worse than one that leaves a cache behind.
struct UninstallMatchTests {

    // MARK: - Bundle id

    @Test("The app's own files match")
    func matchesOwnFiles() {
        #expect(UninstallMatch.matchesBundleID("com.google.Chrome.plist", bundleID: "com.google.Chrome"))
        #expect(UninstallMatch.matchesBundleID("com.google.Chrome", bundleID: "com.google.Chrome"))
        #expect(UninstallMatch.matchesBundleID("com.google.Chrome.savedState", bundleID: "com.google.Chrome"))
    }

    @Test("A sibling product with a longer id is left alone")
    func doesNotClaimSiblingProducts() {
        // Removing Chrome must not take Chrome Canary's data with it.
        #expect(!UninstallMatch.matchesBundleID("com.google.Chromecanary.plist",
                                                bundleID: "com.google.Chrome"))
        #expect(!UninstallMatch.matchesBundleID("com.google.Chrome2", bundleID: "com.google.Chrome"))
    }

    @Test("Case doesn't matter — the file system's does not either")
    func caseInsensitive() {
        #expect(UninstallMatch.matchesBundleID("COM.GOOGLE.CHROME.plist", bundleID: "com.google.Chrome"))
    }

    @Test("An app with no bundle id matches nothing by id")
    func emptyBundleIDMatchesNothing() {
        #expect(!UninstallMatch.matchesBundleID("anything.plist", bundleID: ""))
    }

    // MARK: - Name

    @Test("The name matches when it stands on its own")
    func matchesWholeName() {
        #expect(UninstallMatch.matchesName("Slack", appName: "Slack"))
        #expect(UninstallMatch.matchesName("Slack Helper.plist", appName: "Slack"))
        #expect(UninstallMatch.matchesName("com_slack_data", appName: "Slack"))
    }

    @Test("A name that is only part of a longer word does not match")
    func respectsWordBoundaries() {
        // The bug this pins: uninstalling "Snap" swept up every SnapDesk file.
        #expect(!UninstallMatch.matchesName("SnapDeskCache", appName: "Snap"))
        #expect(!UninstallMatch.matchesName("Slackware", appName: "Slack"))
    }

    @Test("Short names are too weak a signal to use")
    func ignoresShortNames() {
        // "Arc" would otherwise claim every folder with "arc" in it.
        #expect(!UninstallMatch.matchesName("Arc", appName: "Arc"))
        #expect(!UninstallMatch.matchesName("search-arc.db", appName: "Arc"))
    }

    @Test("A reverse-DNS filename is never matched by name")
    func neverMatchesBundleIDsByName() {
        // A third-party app called "Music" must not claim Apple's preferences.
        #expect(!UninstallMatch.matchesName("com.apple.Music.plist", appName: "Music"))
        #expect(!UninstallMatch.matchesName("com.apple.Notes.savedState", appName: "Notes"))
    }

    @Test("What counts as a reverse-DNS filename")
    func bundleIDShape() {
        #expect(UninstallMatch.looksLikeBundleID("com.apple.Music.plist"))
        #expect(UninstallMatch.looksLikeBundleID("org.mozilla.firefox"))
        #expect(!UninstallMatch.looksLikeBundleID("Music.plist"))
        #expect(!UninstallMatch.looksLikeBundleID("my.app"))
        #expect(!UninstallMatch.looksLikeBundleID("com..Music"))
    }

    // MARK: - Vendor folders

    @Test("Fragments too short to mean anything are dropped")
    func tokensSkipNoise() {
        let tokens = UninstallMatch.tokens(appName: "Google Chrome", bundleID: "com.google.Chrome")
        #expect(tokens.contains("google"))
        #expect(tokens.contains("chrome"))
        #expect(!tokens.contains("com"))       // matches every bundle id ever made
    }

    @Test("Inside a vendor folder, the child must match a DIFFERENT word")
    func vendorChildNeedsItsOwnMatch() {
        let tokens = UninstallMatch.tokens(appName: "Google Chrome", bundleID: "com.google.Chrome")
        // Application Support/Google/Chrome — the child names the product.
        #expect(UninstallMatch.vendorChildMatches(vendor: "Google", child: "Chrome", tokens: tokens))
        // Google/GoogleUpdater is shared with Drive and Earth: it matches only
        // the same word the vendor folder did, so it stays.
        #expect(!UninstallMatch.vendorChildMatches(vendor: "Google", child: "GoogleUpdater", tokens: tokens))
        #expect(!UninstallMatch.vendorChildMatches(vendor: "Google", child: "DriveFS", tokens: tokens))
    }

    @Test("A folder that isn't the vendor's is not searched at all")
    func unrelatedVendorFolderIsSkipped() {
        let tokens = UninstallMatch.tokens(appName: "Google Chrome", bundleID: "com.google.Chrome")
        #expect(!UninstallMatch.vendorChildMatches(vendor: "Adobe", child: "Chrome", tokens: tokens))
    }
}
