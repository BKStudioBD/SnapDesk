import Testing
import AppKit
@testable import SnapDeskCore

/// Every picked color is handed to the user as a string, so parse and format must
/// be exact inverses: a one-off here silently corrupts what they paste.
struct ColorHexTests {
    @Test("Parse → format returns the original hex",
          arguments: ["#000000", "#FFFFFF", "#FF8800", "#123456", "#0A0B0C", "#7F7F7F"])
    func roundTrips(_ hex: String) throws {
        let color = try #require(NSColor(hex: hex))
        #expect(color.hexString(uppercase: true) == hex)
    }

    @Test("Malformed input yields nil rather than a wrong color",
          arguments: ["12345", "#12345G", "", "#", "1234567", "##FFFFFF", "not a color"])
    func rejectsMalformed(_ hex: String) {
        #expect(NSColor(hex: hex) == nil)
    }

    /// `Int(_:radix:)` reads a leading sign, so these are six characters long and
    /// parse: as a NEGATIVE number, which the shifts then mask into a valid
    /// looking colour. "-00001" came back as white.
    @Test("A signed number is not a colour", .tags(.regression),
          arguments: ["-00001", "+12345", "#-00001", "#+FFFFF", "-FFFFF", "+00000"])
    func rejectsSignedNumbers(_ hex: String) {
        #expect(NSColor(hex: hex) == nil)
    }

    /// Six characters that Unicode calls hex digits but `Int` cannot read.
    @Test("Non-ASCII digits are rejected too", arguments: ["#ＦＦＦＦＦＦ", "#٠٠٠٠٠٠"])
    func rejectsNonASCIIDigits(_ hex: String) {
        #expect(NSColor(hex: hex) == nil)
    }

    @Test func toleratesSurroundingWhitespaceAndMissingHash() throws {
        #expect(NSColor(hex: "  #ffffff  ") != nil)
        let noHash = try #require(NSColor(hex: "ffffff"))
        #expect(noHash.hexString() == "#FFFFFF")
    }

    @Test func honoursTheLowercaseFlag() throws {
        let color = try #require(NSColor(hex: "#AABBCC"))
        #expect(color.hexString(uppercase: false) == "#aabbcc")
    }

    @Test("Channel order is R, G, B (not reversed)")
    func channelOrder() throws {
        let red = try #require(NSColor(hex: "#FF0000")).usingColorSpace(.sRGB)
        #expect(red?.redComponent == 1)
        #expect(red?.blueComponent == 0)
        let blue = try #require(NSColor(hex: "#0000FF")).usingColorSpace(.sRGB)
        #expect(blue?.blueComponent == 1)
        #expect(blue?.redComponent == 0)
    }
}
