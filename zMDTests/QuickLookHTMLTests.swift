import XCTest
@testable import zMD

/// Tests for the Quick Look extension's pure helpers. `QuickLookHTML.swift` is compiled directly
/// into this test bundle (an .appex cannot host XCTest), and is exercised against the real
/// `MarkdownParser.toHTML` output from the app module — the same composition
/// `PreviewProvider.providePreview` performs.
nonisolated final class QuickLookHTMLTests: XCTestCase {
    // MARK: - makeOfflineSafe

    func testStripsCDNScriptsAndLinksFromMermaidAndMathDocument() {
        let markdown = """
        # Title

        Inline $x^2$ math.

        ```mermaid
        graph TD; A-->B;
        ```

        $$
        a < b
        $$
        """
        let raw = MarkdownParser.shared.toHTML(markdown, includeStyles: true)
        // Guard the premise: if the parser stops emitting these, the test below proves nothing.
        XCTAssertTrue(raw.contains(CDN.mermaidJS))
        XCTAssertTrue(raw.contains(CDN.katexCSS))
        XCTAssertTrue(raw.contains("<script"))

        let safe = QuickLookHTML.makeOfflineSafe(raw)
        XCTAssertFalse(safe.lowercased().contains("<script"))
        XCTAssertFalse(safe.lowercased().contains("</script"))
        XCTAssertFalse(safe.lowercased().contains("<link"))
        XCTAssertFalse(safe.contains("cdn.jsdelivr.net"))
        // Content survives.
        XCTAssertTrue(safe.contains("<h1>Title</h1>"))
        XCTAssertTrue(safe.contains("<pre class=\"mermaid\">"))
        XCTAssertTrue(safe.contains("A--&gt;B"))
        XCTAssertTrue(safe.contains("$x^2$"))
    }

    func testDisplayMathSourceIsKeptAsEscapedText() {
        let raw = MarkdownParser.shared.toHTML("$$\na < b </script> \\& c\n$$", includeStyles: false)
        let safe = QuickLookHTML.makeOfflineSafe(raw)
        XCTAssertFalse(safe.lowercased().contains("<script"))
        XCTAssertTrue(
            safe.contains("<pre class=\"math-source\"><code>a &lt; b &lt;/script&gt; \\&amp; c</code></pre>"),
            "LaTeX should be shown as escaped source, got: \(safe)"
        )
    }

    func testScriptTextInUserContentStaysVisibleAndInert() {
        let markdown = "Text <script>alert(1)</script> here\n\n```html\n<script src=\"x.js\"></script>\n```"
        let safe = QuickLookHTML.makeOfflineSafe(MarkdownParser.shared.toHTML(markdown))
        XCTAssertFalse(safe.lowercased().contains("<script"))
        XCTAssertTrue(safe.contains("&lt;script src="), "escaped code sample must not be stripped")
    }

    func testInjectsDarkModeStylesAndCSPInsideHead() throws {
        let safe = QuickLookHTML.makeOfflineSafe(MarkdownParser.shared.toHTML("hello"))
        let headEnd = try XCTUnwrap(safe.range(of: "</head>"))
        let head = safe[..<headEnd.lowerBound]
        XCTAssertTrue(head.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(head.contains("Content-Security-Policy"))
        XCTAssertTrue(head.contains("default-src 'none'"))
        // Our overrides must come after the parser's stylesheet to win the cascade.
        let parserStyle = try XCTUnwrap(safe.range(of: "@page"))
        let injected = try XCTUnwrap(safe.range(of: "prefers-color-scheme"))
        XCTAssertLessThan(parserStyle.lowerBound, injected.lowerBound)
        XCTAssertTrue(safe.contains("<p>hello</p>"))
    }

    func testParserStylesheetStillLacksDarkMode() {
        // The dark-mode injection exists because toHTML's sheet has none. If the parser gains
        // its own, revisit QuickLookHTML.headInjection instead of stacking two dark themes.
        XCTAssertFalse(MarkdownParser.shared.toHTML("x").contains("prefers-color-scheme"))
    }

    func testHeadlessFragmentStillGetsStyles() {
        let safe = QuickLookHTML.makeOfflineSafe("<p>bare</p>")
        XCTAssertTrue(safe.contains("prefers-color-scheme"))
        XCTAssertTrue(safe.hasSuffix("<p>bare</p>"))
    }

    // MARK: - decode

    func testDecodesUTF8AndStripsBOM() {
        XCTAssertEqual(QuickLookHTML.decode(Data("héllo — ✓".utf8)), "héllo — ✓")
        XCTAssertEqual(QuickLookHTML.decode(Data([0xEF, 0xBB, 0xBF]) + Data("# Hi".utf8)), "# Hi")
    }

    func testDecodesUTF16WithBOMBothEndians() {
        let little = Data([0xFF, 0xFE]) + "# Hé".data(using: .utf16LittleEndian)!
        let big = Data([0xFE, 0xFF]) + "# Hé".data(using: .utf16BigEndian)!
        XCTAssertEqual(QuickLookHTML.decode(little), "# Hé")
        XCTAssertEqual(QuickLookHTML.decode(big), "# Hé")
    }

    func testFallsBackToWindows1252ForInvalidUTF8() {
        // 0x93/0x94 are curly quotes in CP1252 and invalid as UTF-8 lead bytes; 0xE9 is é.
        let data = Data([0x93, 0x63, 0x61, 0x66, 0xE9, 0x94])
        XCTAssertEqual(QuickLookHTML.decode(data), "\u{201C}caf\u{E9}\u{201D}")
    }

    func testBytesUndefinedInCP1252StillDecode() {
        // 0x81 is unassigned in CP1252; must not produce an empty preview.
        XCTAssertFalse(QuickLookHTML.decode(Data([0x41, 0x81, 0xE9])).isEmpty)
    }

    func testTruncatedUTF8TailDoesNotFallBackToCP1252() {
        let full = Data("abc✓".utf8)          // ✓ = E2 9C 93
        let cut = full.dropLast()              // E2 9C — incomplete scalar
        XCTAssertEqual(QuickLookHTML.decode(cut, truncated: true), "abc")
        // Same bytes claimed complete are genuinely not UTF-8 → CP1252 mojibake, not a crash.
        XCTAssertNotEqual(QuickLookHTML.decode(cut, truncated: false), "abc")
    }

    func testEmptyData() {
        XCTAssertEqual(QuickLookHTML.decode(Data()), "")
        XCTAssertEqual(QuickLookHTML.decode(Data(), truncated: true), "")
    }

    // MARK: - readPrefix

    func testReadPrefixCapsAndReportsTruncation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmd-ql-\(UUID().uuidString).md")
        try Data(repeating: 0x61, count: 100).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let capped = try QuickLookHTML.readPrefix(of: url, maxBytes: 40)
        XCTAssertEqual(capped.data.count, 40)
        XCTAssertTrue(capped.truncated)

        let exact = try QuickLookHTML.readPrefix(of: url, maxBytes: 100)
        XCTAssertEqual(exact.data.count, 100)
        XCTAssertFalse(exact.truncated)

        let whole = try QuickLookHTML.readPrefix(of: url)
        XCTAssertEqual(whole.data.count, 100)
        XCTAssertFalse(whole.truncated)
    }

    func testReadPrefixThrowsForMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zmd-ql-missing-\(UUID().uuidString).md")
        XCTAssertThrowsError(try QuickLookHTML.readPrefix(of: url))
    }
}
