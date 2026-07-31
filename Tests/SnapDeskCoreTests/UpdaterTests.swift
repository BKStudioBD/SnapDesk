import Testing
@testable import SnapDeskCore

/// Version comparison decides whether the app replaces itself, so a wrong answer
/// either strands users on an old build or downgrades them. No network here. The
/// comparison is pure.
struct UpdaterVersionTests {
    @Test("A later version is detected", arguments: [
        ("1.1.1", "1.1.0"), ("1.2.0", "1.1.9"), ("2.0.0", "1.99.99"),
        ("1.10.0", "1.9.0"),   // string comparison gets this one backwards
    ])
    func detectsNewer(_ candidate: String, _ current: String) {
        #expect(Updater.isNewer(candidate, than: current))
    }

    @Test("Same or older is never offered", arguments: [
        ("1.1.0", "1.1.0"), ("1.0.9", "1.1.0"),
        ("1.9.0", "1.10.0"), ("0.9.9", "1.0.0"),
        // A missing component is zero, so these two are the SAME version in both
        // directions: neither is an update.
        ("1.1", "1.1.0"), ("1.1.0", "1.1"),
    ])
    func rejectsOlderOrEqual(_ candidate: String, _ current: String) {
        #expect(Updater.isNewer(candidate, than: current) == false)
    }

    @Test("A leading v and other noise in a tag don't break the comparison")
    func tolerantOfTagNoise() {
        // The check strips a leading "v" before comparing; non-digits inside a
        // component are ignored so "1.2.0-beta" still reads as 1.2.0.
        #expect(Updater.isNewer("1.2.0-beta", than: "1.1.0"))
        #expect(Updater.isNewer("1.1.0", than: "1.2.0-beta") == false)
    }

    @Test("Releases are only ever fetched from the one pinned repository")
    func repositoryIsPinned() {
        // A wrong or user-settable value here would mean installing code from
        // somewhere else, so it's asserted rather than assumed.
        #expect(Updater.repository == "BKStudioBD/SnapDesk")
    }

    @Test func currentVersionIsReadable() {
        // Under `swift test` there's no app bundle, so this falls back to "0";
        // the point is that it never traps or returns an empty string.
        #expect(Updater.currentVersion.isEmpty == false)
    }
}

/// Picking the asset decides WHICH file replaces the app. Taking any `.zip` sent
/// everyone a dSYM or symbols archive the day a release shipped one.
struct UpdaterAssetTests {
    private func asset(_ name: String, _ url: String = "https://example.invalid/f.zip") -> [String: Any] {
        ["name": name, "browser_download_url": url]
    }

    @Test("The app archive is picked by name, not by extension")
    func picksNamedAsset() throws {
        // dSYMs first on purpose: GitHub's order is not ours to rely on.
        let url = try #require(Updater.appZipURL(in: [
            asset("SnapDesk-dSYMs.zip", "https://example.invalid/dsyms.zip"),
            asset("SnapDesk.zip", "https://example.invalid/app.zip"),
        ]))
        #expect(url.absoluteString == "https://example.invalid/app.zip")
    }

    @Test("A release without the app archive yields nothing rather than the wrong file")
    func rejectsOtherArchives() {
        #expect(Updater.appZipURL(in: [asset("SnapDesk-dSYMs.zip"), asset("symbols.zip")]) == nil)
        #expect(Updater.appZipURL(in: []) == nil)
        // Name matches but the asset carries no URL. Still nothing to download.
        #expect(Updater.appZipURL(in: [["name": "SnapDesk.zip"]]) == nil)
    }

    @Test("Asset-name matching ignores case")
    func matchesCaseInsensitively() {
        #expect(Updater.appZipURL(in: [asset("snapdesk.zip")]) != nil)
    }
}

/// The signature policy is what stands between a user and someone else's app. It
/// also decides whether a legitimate update is refused, so both directions are
/// asserted here, no codesign process involved.
struct UpdaterSignatureTests {
    private let developerID = """
    Executable=/Applications/SnapDesk.app/Contents/MacOS/SnapDesk
    Identifier=com.snapdesk.app
    Signature size=8981
    Authority=Developer ID Application: BK Studio (ABCDE12345)
    Authority=Developer ID Certification Authority
    Authority=Apple Root CA
    TeamIdentifier=ABCDE12345
    """
    private let adhoc = """
    Executable=/Applications/SnapDesk.app/Contents/MacOS/SnapDesk
    Identifier=com.snapdesk.app
    CodeDirectory v=20400 size=1234 flags=0x2(adhoc) hashes=38+7
    Signature=adhoc
    TeamIdentifier=not set
    """

    @Test("The signing identity is the FIRST Authority line")
    func readsAuthority() {
        #expect(Updater.parseSigner(developerID)
                == .authority("Developer ID Application: BK Studio (ABCDE12345)"))
    }

    @Test("An ad-hoc bundle reads as ad-hoc, not as unsigned")
    func readsAdhoc() {
        // It prints no Authority line at all; calling that "unsigned" made the
        // updater blame every download for the running copy's own signature.
        #expect(Updater.parseSigner(adhoc) == .adhoc)
    }

    @Test("Output with neither an authority nor an ad-hoc marker reads as nothing")
    func readsNothingUseful() {
        #expect(Updater.parseSigner("") == nil)
        #expect(Updater.parseSigner("code object is not signed at all") == nil)
    }

    @Test("Only the same authority may replace us")
    func acceptsMatchingAuthority() {
        let mine = Updater.Signer.authority("Developer ID Application: BK Studio (ABCDE12345)")
        #expect(Updater.signatureRefusal(running: mine, download: mine) == nil)
        #expect(Updater.signatureRefusal(running: mine,
                                         download: .authority("Developer ID Application: Someone Else (ZZZZZ99999)"))
                == .wrongSigner)
        // Signed by nobody is not the same signer, and no signature at all is
        // reported as exactly that.
        #expect(Updater.signatureRefusal(running: mine, download: .adhoc) == .wrongSigner)
        #expect(Updater.signatureRefusal(running: mine, download: nil) == .unsigned)
    }

    @Test("An ad-hoc copy blames itself, not the download")
    func adhocSelfIsHonest() {
        let theirs = Updater.Signer.authority("Developer ID Application: BK Studio (ABCDE12345)")
        #expect(Updater.signatureRefusal(running: .adhoc, download: theirs) == .noIdentity)
        #expect(Updater.signatureRefusal(running: .adhoc, download: .adhoc) == .noIdentity)
        // Unreadable own signature is the same story: nothing to compare against.
        #expect(Updater.signatureRefusal(running: nil, download: theirs) == .noIdentity)
    }
}
