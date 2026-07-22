import XCTest
@testable import zMD

/// Characterization tests for `MarkdownParser.parse`/`.toHTML` block-level constructs.
/// These pin the parser's *current* behavior (per its own simplified, non-CommonMark-complete
/// design — see CLAUDE.md's "Known Limitations") rather than assert conformance to any spec.
/// Deliberate behavior changes should update these tests, not treat a failure as automatically
/// wrong.
final class MarkdownParserTests: XCTestCase {
    // MARK: - 1. Headings

    func testHeadingLevelsProduceMatchingElementsAndTags() {
        let markdown = "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6"
        let elements = MarkdownParser.shared.parse(markdown)

        XCTAssertEqual(elements.count, 6)
        guard case .heading1(let h1) = elements[0],
              case .heading2(let h2) = elements[1],
              case .heading3(let h3) = elements[2],
              case .heading4(let h4) = elements[3],
              case .heading5(let h5) = elements[4],
              case .heading6(let h6) = elements[5] else {
            return XCTFail("Expected heading1...heading6 in order, got \(elements)")
        }
        XCTAssertEqual([h1, h2, h3, h4, h5, h6], ["H1", "H2", "H3", "H4", "H5", "H6"])

        let html = MarkdownParser.shared.toHTML(markdown, includeStyles: false)
        for tag in ["h1", "h2", "h3", "h4", "h5", "h6"] {
            XCTAssertTrue(html.contains("<\(tag)>"), "Expected <\(tag)> in HTML output")
        }
    }

    // MARK: - 2. Nested lists

    func testNestedUnorderedListPreservesLevels() {
        let markdown = "- Level0\n  - Level1\n    - Level2\n- Level0b"
        let elements = MarkdownParser.shared.parse(markdown)

        XCTAssertEqual(elements.count, 1)
        guard case .list(let items) = elements[0] else {
            return XCTFail("Expected a single list element, got \(elements)")
        }

        let levels = items.map { $0.level }
        let texts = items.map { $0.text }
        XCTAssertEqual(levels, [0, 1, 2, 0])
        XCTAssertEqual(texts, ["Level0", "Level1", "Level2", "Level0b"])
        XCTAssertTrue(items.allSatisfy { !$0.isOrdered })
    }

    func testNestedOrderedListPreservesLevelsAndStartNumbers() {
        let markdown = "1. First\n   1. Nested\n2. Second"
        let elements = MarkdownParser.shared.parse(markdown)

        XCTAssertEqual(elements.count, 1)
        guard case .list(let items) = elements[0] else {
            return XCTFail("Expected a single list element, got \(elements)")
        }

        XCTAssertEqual(items.map { $0.level }, [0, 1, 0])
        XCTAssertEqual(items.map { $0.text }, ["First", "Nested", "Second"])
        XCTAssertTrue(items.allSatisfy { $0.isOrdered })
        XCTAssertEqual(items.map { $0.startNumber }, [1, 1, 2])
    }

    // MARK: - 3. Tables

    func testTableSeparatesHeaderFromBodyRows() {
        let markdown = "| Header1 | Header2 |\n| --- | --- |\n| a | b |\n| c | d |"
        let elements = MarkdownParser.shared.parse(markdown)

        XCTAssertEqual(elements.count, 1)
        guard case .table(let rows) = elements[0] else {
            return XCTFail("Expected a single table element, got \(elements)")
        }

        // Separator row is consumed during parsing and never appears as data.
        XCTAssertEqual(rows, [["Header1", "Header2"], ["a", "b"], ["c", "d"]])

        let html = MarkdownParser.shared.toHTML(markdown, includeStyles: false)
        XCTAssertTrue(html.contains("<th>Header1</th>"))
        XCTAssertTrue(html.contains("<th>Header2</th>"))
        XCTAssertTrue(html.contains("<td>a</td>"))
        XCTAssertFalse(html.contains("<th>a</th>"))
    }

    // MARK: - 4. Fenced code blocks

    func testFencedCodeBlockKeepsHashLineLiteral() {
        let markdown = "```swift\n# not a heading\nlet x = 1\n```"
        let elements = MarkdownParser.shared.parse(markdown)

        XCTAssertEqual(elements.count, 1)
        guard case .codeBlock(let code, let language) = elements[0] else {
            return XCTFail("Expected a single codeBlock element, got \(elements)")
        }
        XCTAssertEqual(code, "# not a heading\nlet x = 1")
        XCTAssertEqual(language, "swift")

        let html = MarkdownParser.shared.toHTML(markdown, includeStyles: false)
        XCTAssertFalse(html.contains("<h1>"))
        XCTAssertTrue(html.contains("# not a heading"))
    }

    // MARK: - 5. Blockquotes with inline formatting

    func testBlockquoteAppliesInlineFormatting() {
        let markdown = "> **bold** text"
        let elements = MarkdownParser.shared.parse(markdown)

        XCTAssertEqual(elements.count, 1)
        guard case .blockquote(let text) = elements[0] else {
            return XCTFail("Expected a single blockquote element, got \(elements)")
        }
        XCTAssertEqual(text, "**bold** text")

        let html = MarkdownParser.shared.toHTML(markdown, includeStyles: false)
        XCTAssertTrue(html.contains("<blockquote><strong>bold</strong> text</blockquote>"))
    }

    // MARK: - 6. YAML frontmatter

    func testLeadingFrontmatterIsCapturedSeparatelyFromContent() {
        let markdown = "---\ntitle: Test\nauthor: Me\n---\n# Heading"
        let elements = MarkdownParser.shared.parse(markdown)

        XCTAssertEqual(elements.count, 2)
        guard case .frontmatter(let lines) = elements[0] else {
            return XCTFail("Expected frontmatter as the first element, got \(elements)")
        }
        XCTAssertEqual(lines, ["title: Test", "author: Me"])

        guard case .heading1(let heading) = elements[1] else {
            return XCTFail("Expected heading1 as the second element, got \(elements)")
        }
        XCTAssertEqual(heading, "Heading")

        // Frontmatter must not also render as a horizontal rule or plain paragraph.
        let html = MarkdownParser.shared.toHTML(markdown, includeStyles: false)
        XCTAssertTrue(html.contains("class=\"frontmatter\""))
        XCTAssertFalse(html.contains("<hr>"))
    }

    // MARK: - 7. Horizontal rules (mid-document, distinct from frontmatter)

    func testMidDocumentHorizontalRuleIsNotTreatedAsFrontmatter() {
        let markdown = "Text\n\n***\n\nMore text"
        let elements = MarkdownParser.shared.parse(markdown)

        XCTAssertEqual(elements.count, 3)
        guard case .paragraph(let first) = elements[0],
              case .horizontalRule = elements[1],
              case .paragraph(let second) = elements[2] else {
            return XCTFail("Expected paragraph, horizontalRule, paragraph, got \(elements)")
        }
        XCTAssertEqual(first, "Text")
        XCTAssertEqual(second, "More text")
    }

    // MARK: - 8. Standalone image line vs. text+image line

    func testStandaloneImageLineProducesImageElement() {
        let markdown = "![alt](img.png)"
        let elements = MarkdownParser.shared.parse(markdown)

        XCTAssertEqual(elements.count, 1)
        guard case .image(let alt, let path) = elements[0] else {
            return XCTFail("Expected a single image element, got \(elements)")
        }
        XCTAssertEqual(alt, "alt")
        XCTAssertEqual(path, "img.png")
    }

    // (Complementary mixed-text-and-image case already covered by
    // testMixedInlineImagePreservesSurroundingTextInHTML in InlineMarkdownTests.swift.)

    // MARK: - 9. Empty document

    func testEmptyDocumentProducesNoElementsAndDoesNotCrash() {
        XCTAssertTrue(MarkdownParser.shared.parse("").isEmpty)
        XCTAssertEqual(MarkdownParser.shared.toHTMLBody(""), "")

        // Full toHTML wraps in a document shell even for empty content — should not crash.
        let html = MarkdownParser.shared.toHTML("", includeStyles: false)
        XCTAssertTrue(html.contains("<body>"))
        XCTAssertTrue(html.contains("</body>"))
    }

    // MARK: - 10. CRLF line endings

    func testCRLFLineEndingsParseIdenticallyToLF() {
        let lf = "# Heading\n\nSome text\n\n- item1\n- item2"
        let crlf = "# Heading\r\n\r\nSome text\r\n\r\n- item1\r\n- item2"

        let lfElements = MarkdownParser.shared.parse(lf)
        let crlfElements = MarkdownParser.shared.parse(crlf)

        // Element isn't Equatable, but `.id` is documented as a content-addressed,
        // collision-free identity — comparing id sequences is a faithful structural comparison.
        XCTAssertFalse(lfElements.isEmpty)
        XCTAssertEqual(lfElements.map { $0.id }, crlfElements.map { $0.id })
    }
}
