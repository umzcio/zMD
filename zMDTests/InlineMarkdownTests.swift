import XCTest
@testable import zMD

final class InlineMarkdownTests: XCTestCase {
    func testCodeSpansAreAtomicBeforeEmphasis() {
        XCTAssertEqual(
            InlineMarkdown.tokenize("`*literal*` **strong**"),
            [.code("*literal*"), .text(" "), .strong("strong")]
        )
    }

    func testInlineMathIsAtomicBeforeEmphasis() {
        XCTAssertEqual(
            InlineMarkdown.tokenize("value $a * b$ end"),
            [.text("value "), .math("a * b"), .text(" end")]
        )
    }

    func testMixedInlineImagePreservesSurroundingTextInHTML() {
        let html = MarkdownParser.shared.toHTML("See ![diagram](diagram.png) for the flow.", includeStyles: false)

        XCTAssertTrue(html.contains("See "))
        XCTAssertTrue(html.contains("<img src=\"diagram.png\" alt=\"diagram\">"))
        XCTAssertTrue(html.contains(" for the flow."))
    }

    func testInlineImageURLIsEscapedOnce() {
        let html = MarkdownParser.shared.formatInlineHTML("![remote](https://host/img.png?a=1&b=2)")

        XCTAssertTrue(html.contains("src=\"https://host/img.png?a=1&amp;b=2\""))
        XCTAssertFalse(html.contains("&amp;amp;"))
    }

    func testRawHTMLBlockIsEscapedInExportHTML() {
        let html = MarkdownParser.shared.toHTML("<div/onclick=alert(1)>raw</div>", includeStyles: false)

        XCTAssertTrue(html.contains("&lt;div/onclick=alert(1)&gt;raw&lt;/div&gt;"))
        XCTAssertFalse(html.contains("<div/onclick"))
    }

    func testMarkdownGeneratedLinkStillEmitsHTML() {
        let html = MarkdownParser.shared.toHTML("[site](https://example.com?a=1&b=2)", includeStyles: false)

        XCTAssertTrue(html.contains("<a href=\"https://example.com?a=1&amp;b=2\">site</a>"))
    }

    func testObfuscatedJavaScriptLinkIsNeutralized() {
        let html = MarkdownParser.shared.toHTML("[bad](java&#9;script:alert(1))", includeStyles: false)

        XCTAssertTrue(html.contains("<a href=\"#\">bad</a>"))
        XCTAssertFalse(html.contains("java&#9;script"))
    }

    func testSVGDataImageSourceIsNeutralized() {
        let html = MarkdownParser.shared.toHTML("![bad](data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=)", includeStyles: false)

        XCTAssertTrue(html.contains("<img src=\"#\" alt=\"bad\">"))
        XCTAssertFalse(html.contains("data:image/svg+xml"))
    }

    func testNestedInlineFormattingInsideLinkLabelRendersInHTML() {
        let html = MarkdownParser.shared.formatInlineHTML("[**bold**](https://example.com)")

        XCTAssertEqual(html, "<a href=\"https://example.com\"><strong>bold</strong></a>")
    }

    func testLinkInsideStrongFormattingRendersInHTML() {
        let html = MarkdownParser.shared.formatInlineHTML("**[label](https://example.com)**")

        XCTAssertEqual(html, "<strong><a href=\"https://example.com\">label</a></strong>")
    }

    func testDOCXHyperlinkURLsUseSameSchemeHardening() {
        XCTAssertEqual(ExportManager.safeDOCXHyperlinkURL("https://example.com?a=1&b=2"), "https://example.com?a=1&b=2")
        XCTAssertNil(ExportManager.safeDOCXHyperlinkURL("javascript:alert(1)"))
        XCTAssertNil(ExportManager.safeDOCXHyperlinkURL("java&#9;script:alert(1)"))
        XCTAssertNil(ExportManager.safeDOCXHyperlinkURL("#fragment"))
    }

    func testMathExtractionDoesNotReuseUserAuthoredPlaceholderText() {
        let extraction = ExportManager.shared.extractMathFromMarkdown("literal ZMDMATHPH0ZMDEND and $x + y$")

        XCTAssertTrue(extraction.modified.contains("literal ZMDMATHPH0ZMDEND"))
        XCTAssertEqual(extraction.math.count, 1)
        XCTAssertNotEqual(extraction.placeholder(at: 0), "ZMDMATHPH0ZMDEND")
        XCTAssertTrue(extraction.modified.contains(extraction.placeholder(at: 0)))
    }
}

final class RuntimeSmokeTests: XCTestCase {
    func testSourceReplaceUsesFreshSourceRangesAfterEdit() throws {
        let manager = DocumentManager.shared
        let previousAutoSave = manager.autoSaveEnabled
        let previousDocuments = manager.openDocuments
        let previousSelectedId = manager.selectedDocumentId
        let previousViewMode = manager.viewMode
        let previousSearchText = manager.searchText
        let previousReplaceText = manager.replaceText
        let previousSearchMatches = manager.searchMatches
        let previousRenderedMatchCount = manager.renderedMatchCount
        let previousCurrentMatchIndex = manager.currentMatchIndex
        let previousIsSearching = manager.isSearching
        let previousShowReplace = manager.showReplace
        let previousRegex = manager.isRegexSearch
        let previousCaseSensitive = manager.isCaseSensitive

        defer {
            manager.autoSaveEnabled = previousAutoSave
            manager.openDocuments = previousDocuments
            manager.selectedDocumentId = previousSelectedId
            manager.viewMode = previousViewMode
            manager.searchText = previousSearchText
            manager.replaceText = previousReplaceText
            manager.searchMatches = previousSearchMatches
            manager.renderedMatchCount = previousRenderedMatchCount
            manager.currentMatchIndex = previousCurrentMatchIndex
            manager.isSearching = previousIsSearching
            manager.showReplace = previousShowReplace
            manager.isRegexSearch = previousRegex
            manager.isCaseSensitive = previousCaseSensitive
        }

        manager.autoSaveEnabled = false
        manager.openDocuments = []
        manager.selectedDocumentId = nil
        manager.viewMode = .source
        manager.isRegexSearch = false
        manager.isCaseSensitive = true
        manager.renderedMatchCount = 0

        let documentId = UUID()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmd-source-replace-\(UUID().uuidString).md")
        manager.openDocuments = [
            MarkdownDocument(id: documentId, url: url, content: "alpha target beta target")
        ]
        manager.selectedDocumentId = documentId
        manager.startFindAndReplace()
        manager.searchText = "target"
        manager.replaceText = "REPLACED"
        manager.performSearch(immediate: true)

        XCTAssertEqual(manager.searchMatches.count, 2)
        XCTAssertEqual(manager.searchControlMatchCount, 2)

        manager.updateContent(for: documentId, newContent: "prefix alpha target beta target")
        XCTAssertEqual(manager.searchMatches.count, 2)

        manager.replaceCurrentMatch()

        XCTAssertEqual(manager.openDocuments.first?.content, "prefix alpha REPLACED beta target")
    }

    func testEnteringPreviewClearsReplaceStateAndUsesRenderedCount() {
        let manager = DocumentManager.shared
        let previousViewMode = manager.viewMode
        let previousShowReplace = manager.showReplace
        let previousReplaceText = manager.replaceText
        let previousSearchMatches = manager.searchMatches
        let previousRenderedMatchCount = manager.renderedMatchCount
        let previousCurrentMatchIndex = manager.currentMatchIndex

        defer {
            manager.viewMode = previousViewMode
            manager.showReplace = previousShowReplace
            manager.replaceText = previousReplaceText
            manager.searchMatches = previousSearchMatches
            manager.renderedMatchCount = previousRenderedMatchCount
            manager.currentMatchIndex = previousCurrentMatchIndex
        }

        manager.viewMode = .source
        manager.showReplace = true
        manager.replaceText = "replacement"
        manager.searchMatches = [
            SearchMatch(range: NSRange(location: 0, length: 1), lineNumber: 1),
            SearchMatch(range: NSRange(location: 4, length: 1), lineNumber: 1)
        ]
        manager.renderedMatchCount = 1
        manager.currentMatchIndex = 1

        manager.viewMode = .preview

        XCTAssertFalse(manager.showReplace)
        XCTAssertEqual(manager.replaceText, "")
        XCTAssertEqual(manager.searchControlMatchCount, 1)
        XCTAssertEqual(manager.currentMatchIndex, 0)
    }

    func testFileWatcherSurvivesIgnoredAtomicRenameAndReportsLaterEdit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmd-filewatcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("watch.md")
        try "initial".write(to: url, atomically: true, encoding: .utf8)

        let changed = expectation(description: "reports edit after ignored atomic rename")
        let delegate = FileWatcherProbe(expectedURL: url, changed: changed)
        let watcher = FileWatcher(url: url)
        watcher.delegate = delegate
        watcher.startWatching()
        defer { watcher.stopWatching() }

        watcher.ignoreNextChange = true
        try "self-save".write(to: url, atomically: true, encoding: .utf8)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            try? "external-edit".write(to: url, atomically: true, encoding: .utf8)
        }

        wait(for: [changed], timeout: 4.0)
    }
}

private final class FileWatcherProbe: FileWatcherDelegate {
    private let expectedURL: URL
    private let changed: XCTestExpectation

    init(expectedURL: URL, changed: XCTestExpectation) {
        self.expectedURL = expectedURL
        self.changed = changed
    }

    func fileWatcher(_ watcher: FileWatcher, fileDidChange url: URL) {
        if url == expectedURL {
            changed.fulfill()
        }
    }

    func fileWatcher(_ watcher: FileWatcher, fileWasDeleted url: URL) {}
}
