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

    func testMathTokenRejectsCarriageReturnAndLineSeparators() {
        // A \r, U+2028, or U+2029 inside a $...$ span must not be accepted into a
        // .math token — those characters break the single-quoted JS string literal
        // that WebRenderer splices math content into. The tokenizer already rejects
        // literal \n the same way; confirm \r and the Unicode line separators are
        // rejected too. With no other token type able to claim a lone "$", a rejected
        // span falls all the way through to plain buffered text (mirroring how "\n"
        // already behaves today).
        XCTAssertEqual(InlineMarkdown.tokenize("$a\rb$"), [.text("$a\rb$")])
        XCTAssertEqual(InlineMarkdown.tokenize("$a\u{2028}b$"), [.text("$a\u{2028}b$")])
        XCTAssertEqual(InlineMarkdown.tokenize("$a\u{2029}b$"), [.text("$a\u{2029}b$")])

        XCTAssertNil(InlineMarkdown.tokenize("$a\rb$").first { if case .math = $0 { return true } else { return false } })
        XCTAssertNil(InlineMarkdown.tokenize("$a\u{2028}b$").first { if case .math = $0 { return true } else { return false } })
        XCTAssertNil(InlineMarkdown.tokenize("$a\u{2029}b$").first { if case .math = $0 { return true } else { return false } })
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

    func testEmphasisSkipsEscapedDelimiter() {
        XCTAssertEqual(
            InlineMarkdown.tokenize("*a\\*b*"),
            [.emphasis("a\\*b")]
        )
    }

    func testMathExtractionDoesNotReuseUserAuthoredPlaceholderText() {
        let extraction = ExportManager.shared.extractMathFromMarkdown("literal ZMDMATHPH0ZMDEND and $x + y$")

        XCTAssertTrue(extraction.modified.contains("literal ZMDMATHPH0ZMDEND"))
        XCTAssertEqual(extraction.math.count, 1)
        XCTAssertNotEqual(extraction.placeholder(at: 0), "ZMDMATHPH0ZMDEND")
        XCTAssertTrue(extraction.modified.contains(extraction.placeholder(at: 0)))
    }

    func testIsNewerVersionRejectsEqualAndOlderVersions() {
        let manager = UpdateManager.shared
        XCTAssertFalse(manager.isNewerVersion(remote: "2.7.1", current: "2.7.1"))
        XCTAssertFalse(manager.isNewerVersion(remote: "2.6.0", current: "2.7.1"))
        XCTAssertTrue(manager.isNewerVersion(remote: "2.7.2", current: "2.7.1"))
        XCTAssertTrue(manager.isNewerVersion(remote: "3.0.0", current: "2.7.1"))
    }

    // Regression test for the stuck-"ready"-stage bug: sheet reaches .ready -> user clicks
    // "Later" (onLater's unconditional reset, mirrored here since onLater itself lives in a
    // SwiftUI closure in zMDApp.swift and isn't independently callable) -> "Check for Updates"
    // reopens the sheet -> user clicks "Update Now" again. Before the fix, onLater only reset
    // `stage` on `.failed`, so `.ready` stuck around forever and downloadAndInstall()'s
    // re-entrancy guard (`stage == .idle`) permanently no-oped "Update Now".
    func testLaterFromReadyUnsticksDownloadAndInstall() {
        let manager = UpdateManager.shared
        let previousStage = manager.stage
        let previousDownloadURL = manager.downloadURL
        let previousLatestVersion = manager.latestVersion
        defer {
            manager.stage = previousStage
            manager.downloadURL = previousDownloadURL
            manager.latestVersion = previousLatestVersion
        }

        manager.stage = .ready
        // This is exactly onLater's new body from zMDApp.swift.
        manager.stage = .idle
        XCTAssertEqual(manager.stage, .idle, "stage should be unstuck after Later")

        // Now simulate clicking "Update Now" again: downloadAndInstall()'s re-entrancy guard
        // must NOT bounce it back out immediately (that was the bug). Use a version that's not
        // newer so the *new* downgrade guard (Step 2) is what stops it, not a stale .ready stage.
        manager.latestVersion = manager.currentVersion
        manager.downloadURL = URL(string: "https://example.com/zMD.dmg")
        manager.downloadAndInstall()
        if case .failed(let message) = manager.stage {
            XCTAssertTrue(message.contains("not newer"), "should fail on the downgrade guard, not the stale re-entrancy guard: \(message)")
        } else {
            XCTFail("expected .failed from the downgrade guard, got \(manager.stage)")
        }
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

final class FolderManagerTests: XCTestCase {
    func testFolderScanDoesNotRecurseIntoSymlinkCycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmd-symlink-cycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A real markdown file so the folder isn't filtered out as empty.
        try "hello".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

        // A directory symlink pointing back at `root` itself — the simplest cycle.
        let cycleLink = root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: cycleLink, withDestinationURL: root)

        // FolderManager's initializer is private (singleton), so drive this through
        // .shared and restore its state afterward, matching the RuntimeSmokeTests pattern
        // above for DocumentManager.shared.
        let manager = FolderManager.shared
        let previousFolderURL = manager.folderURL
        let previousFileTree = manager.fileTree
        let previousShowingSidebar = manager.isShowingFolderSidebar

        defer {
            manager.closeFolder()
            manager.folderURL = previousFolderURL
            manager.fileTree = previousFileTree
            manager.isShowingFolderSidebar = previousShowingSidebar
        }

        let done = expectation(description: "tree scan completes without crashing")

        // setFolder dispatches the scan async and publishes fileTree on main;
        // poll briefly rather than relying on a Combine subscription to keep this
        // test dependency-free.
        manager.setFolder(root)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            done.fulfill()
        }
        wait(for: [done], timeout: 3.0)

        // Reaching here without a crash/timeout is the primary assertion. Also
        // confirm the real file surfaced and the cyclic symlink did not appear
        // as a nested directory entry.
        XCTAssertTrue(manager.fileTree.contains { $0.name == "note.md" })
        XCTAssertFalse(manager.fileTree.contains { $0.name == "loop" })
    }
}
