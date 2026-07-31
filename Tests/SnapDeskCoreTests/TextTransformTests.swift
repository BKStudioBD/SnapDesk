import Testing
@testable import SnapDeskCore

/// Transforms rewrite what the user pastes, so a wrong one is worse than none.
struct TextTransformTests {
    @Test func stripsLineBreaksAndCollapsesRuns() {
        #expect(TextTransform.plain.apply(to: "one\ntwo   three\n\nfour") == "one two three four")
    }

    @Test func trimsEachLineButKeepsTheLines() {
        #expect(TextTransform.trimLines.apply(to: "  a  \n\tb\t\n c ") == "a\nb\nc")
    }

    @Test("Case transforms", arguments: [
        (TextTransform.lowercase, "Hello World", "hello world"),
        (.uppercase, "Hello World", "HELLO WORLD"),
        (.titleCase, "hello wide world", "Hello Wide World"),
    ])
    func changesCase(_ transform: TextTransform, _ input: String, _ expected: String) {
        #expect(transform.apply(to: input) == expected)
    }

    @Test func makesSlugs() {
        #expect(TextTransform.slug.apply(to: "Hello, World! 2026") == "hello-world-2026")
        #expect(TextTransform.slug.apply(to: "  spaced  out  ") == "spaced-out")
        #expect(TextTransform.slug.apply(to: "!!!") == nil, "nothing sluggable → leave it alone")
    }

    @Test func decodesPercentEncoding() {
        #expect(TextTransform.urlDecode.apply(to: "a%20b%2Fc") == "a b/c")
        #expect(TextTransform.urlDecode.apply(to: "plain text") == nil,
                "nothing encoded → nil, so the caller pastes the original")
    }

    @Test func prettyPrintsJSONAndRefusesNonJSON() throws {
        let pretty = try #require(TextTransform.prettyJSON.apply(to: #"{"b":1,"a":[2,3]}"#))
        #expect(pretty.contains("\n"), "should be multi-line")
        #expect(pretty.contains("\"a\""))
        // sortedKeys → "a" comes before "b".
        let a = try #require(pretty.range(of: "\"a\""))
        let b = try #require(pretty.range(of: "\"b\""))
        #expect(a.lowerBound < b.lowerBound)
        #expect(TextTransform.prettyJSON.apply(to: "not json") == nil)
    }

    @Test("Only transforms that would change something are offered")
    func filtersUselessOptions() {
        let single = TextTransform.available(for: "already one line")
        #expect(single.contains(.plain) == false, "nothing to strip")
        #expect(single.contains(.prettyJSON) == false)
        #expect(single.contains(.uppercase), "case changes always apply")

        let wrapped = TextTransform.available(for: "two\nlines")
        #expect(wrapped.contains(.plain))
    }

    /// The menu is built while each row RENDERS, so this must decide by looking
    /// at the text rather than by running the transforms over it.
    @Test("Trimming is offered only when a line actually has edge whitespace")
    func trimDetection() {
        #expect(TextTransform.available(for: "clean\nlines").contains(.trimLines) == false)
        #expect(TextTransform.available(for: "trailing \nspace").contains(.trimLines))
        #expect(TextTransform.available(for: "  indented").contains(.trimLines))
        #expect(TextTransform.available(for: "tabbed\t").contains(.trimLines))
    }

    @Test("URL-decode is offered only where there is an escape to decode")
    func urlDecodeDetection() {
        #expect(TextTransform.available(for: "plain text").contains(.urlDecode) == false)
        #expect(TextTransform.available(for: "a%20b").contains(.urlDecode))
    }

    @Test("Pretty-print is offered for JSON, not for text that merely has braces")
    func jsonDetection() {
        #expect(TextTransform.available(for: #"{"a":1}"#).contains(.prettyJSON))
        #expect(TextTransform.available(for: "  [1, 2, 3]").contains(.prettyJSON))
        #expect(TextTransform.available(for: "not { json }").contains(.prettyJSON) == false)
        #expect(TextTransform.available(for: "{oops").contains(.prettyJSON) == false)
    }

    @Test("A huge JSON row is offered without being parsed first")
    func hugeJSONIsOfferedOptimistically() {
        // Over the parse threshold: confirming it would mean deserialising a
        // megabyte for every visible row on every keystroke.
        let big = "[" + Array(repeating: "\"x\"", count: 40_000).joined(separator: ",") + "]"
        #expect(big.utf8.count > 32_768)
        #expect(TextTransform.available(for: big).contains(.prettyJSON))
    }
}
