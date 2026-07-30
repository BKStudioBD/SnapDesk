import Testing
import AppKit
@testable import SnapDeskCore

extension Tag {
    /// Cases that were real shipped bugs — treat with extra care.
    @Tag static var regression: Self
}

/// Content classification drives which card each history row draws, so a
/// misclassification is user-visible.
struct ClipboardItemClassification {
    private func item(_ s: String) -> ClipboardItem { ClipboardItem(kind: .text(s)) }

    @Test("Links are recognized with and without a scheme",
          arguments: ["https://example.com/x", "http://example.com", "www.example.com",
                      "https://example.com\n"])
    func recognizesLinks(_ input: String) {
        #expect(item(input).contentType == .link)
    }

    @Test("Text that merely contains a URL is not a link",
          arguments: ["not a link http://x", "see https://a.com and https://b.com"])
    func rejectsNonLinks(_ input: String) {
        #expect((item(input).contentType == .link) == false)
    }

    @Test("Hex colors need the leading #", .tags(.regression))
    func hexColorsNeedHash() {
        #expect(item("#FF8800").contentType == .color)
        // "facade" and git short SHAs are 6 hex chars — treating them as colors
        // was the bug the # requirement fixed.
        #expect(item("FF8800").contentType == .text)
        #expect(item("facade").contentType == .text)
        #expect(item("#GG8800").contentType == .text)
    }

    @Test func recognizesEmail() {
        #expect(item("user@site.com").contentType == .email)
        #expect(item("user@site").contentType == .text, "a domain without a dot isn't an address")
    }

    @Test func recognizesCode() {
        #expect(item("func f() {\n  x\n}").contentType == .code)
        #expect(item("plain words").contentType == .text)
    }

    @Test func imageItemsReportAsImages() {
        let blank = NSImage(size: NSSize(width: 1, height: 1))
        let item = ClipboardItem(kind: .image(data: Data([0x00]), thumb: blank))
        #expect(item.isImage)
        #expect(item.contentType == .image)
    }
}

/// The preview string is what the row renders and what search matches, so it must
/// stay bounded no matter how large the copied text is.
struct ClipboardItemPreview {
    @Test func whitespaceOnlyGetsAPlaceholder() {
        #expect(ClipboardItem(kind: .text("   \n  ")).preview == "(whitespace)")
    }

    @Test("Long text is capped so SwiftUI never renders a multi-MB string")
    func capsLongPreviews() {
        let preview = ClipboardItem(kind: .text(String(repeating: "a", count: 600))).preview
        #expect(preview.count == 501, "500 characters plus the ellipsis")
        #expect(preview.hasSuffix("…"))
    }

    @Test func shortTextPassesThroughTrimmed() {
        #expect(ClipboardItem(kind: .text("  hello  ")).preview == "hello")
    }
}

/// Storage normalization: a copied URL routinely carries a trailing newline, and
/// re-emitting it navigates or SENDS the moment it's pasted.
struct ClipboardItemStorage {
    @Test(.tags(.regression)) func trimsBareLinks() {
        #expect(ClipboardItem.normalizedForStorage("https://a.com\n") == "https://a.com")
    }

    @Test("Anything that isn't a bare link is kept byte-for-byte")
    func keepsOtherTextVerbatim() {
        #expect(ClipboardItem.normalizedForStorage("hello\n") == "hello\n")
        #expect(ClipboardItem.normalizedForStorage("  indented\n") == "  indented\n")
    }
}
