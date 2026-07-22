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

    func testHighlightTokenizesAsDistinctFromEquals() {
        XCTAssertEqual(
            InlineMarkdown.tokenize("==important== and =not= this"),
            [.highlight("important"), .text(" and =not= this")]
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

    func testHighlightRendersAsMarkTagInHTML() {
        let html = MarkdownParser.shared.formatInlineHTML("==important==")

        XCTAssertEqual(html, "<mark>important</mark>")
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

    // MARK: - Plan 013 Step 1: characterization tests for already-in-memory-testable behavior.
    // These lock in current updateContent/hasUnsavedChanges/closeDocument-fast-path behavior
    // BEFORE any DirtyCloseConfirming extraction, so Step 2's extraction can be verified against
    // them for zero behavior change.

    func testUpdateContentMarksDocumentDirtyImmediately() {
        let manager = DocumentManager.shared
        let previousAutoSave = manager.autoSaveEnabled
        let previousDocuments = manager.openDocuments
        let previousSelectedId = manager.selectedDocumentId

        defer {
            manager.autoSaveEnabled = previousAutoSave
            manager.openDocuments = previousDocuments
            manager.selectedDocumentId = previousSelectedId
        }

        manager.autoSaveEnabled = false
        let documentId = UUID()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmd-update-content-\(UUID().uuidString).md")
        manager.openDocuments = [
            MarkdownDocument(id: documentId, url: url, content: "initial", isDirty: false)
        ]
        manager.selectedDocumentId = documentId

        manager.updateContent(for: documentId, newContent: "changed")

        XCTAssertTrue(manager.openDocuments.first?.isDirty ?? false)
        XCTAssertEqual(manager.openDocuments.first?.content, "changed")
    }

    func testUpdateContentSchedulesAutoSaveWhenEnabled() throws {
        let manager = DocumentManager.shared
        let previousAutoSave = manager.autoSaveEnabled
        let previousDocuments = manager.openDocuments
        let previousSelectedId = manager.selectedDocumentId

        defer {
            manager.autoSaveEnabled = previousAutoSave
            manager.openDocuments = previousDocuments
            manager.selectedDocumentId = previousSelectedId
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmd-autosave-on-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try "initial".write(to: url, atomically: true, encoding: .utf8)

        manager.autoSaveEnabled = true
        let documentId = UUID()
        manager.openDocuments = [
            MarkdownDocument(id: documentId, url: url, content: "initial", isDirty: false)
        ]
        manager.selectedDocumentId = documentId

        manager.updateContent(for: documentId, newContent: "autosaved content")
        XCTAssertTrue(manager.openDocuments.first?.isDirty ?? false, "should be dirty immediately after the edit")

        // Timing.autoSaveDebounce is 2.0s — wait comfortably past it for the timer to fire and
        // saveDocument to complete its (synchronous, non-untitled, non-sandboxed) disk write.
        let saved = expectation(description: "auto-save fires and clears dirty flag")
        var attempts = 0
        func poll() {
            attempts += 1
            if manager.openDocuments.first?.isDirty == false {
                saved.fulfill()
            } else if attempts < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
            }
        }
        poll()
        wait(for: [saved], timeout: 4.0)

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, "autosaved content")
    }

    func testUpdateContentDoesNotAutoSaveWhenDisabled() throws {
        let manager = DocumentManager.shared
        let previousAutoSave = manager.autoSaveEnabled
        let previousDocuments = manager.openDocuments
        let previousSelectedId = manager.selectedDocumentId

        defer {
            manager.autoSaveEnabled = previousAutoSave
            manager.openDocuments = previousDocuments
            manager.selectedDocumentId = previousSelectedId
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmd-autosave-off-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try "initial".write(to: url, atomically: true, encoding: .utf8)

        manager.autoSaveEnabled = false
        let documentId = UUID()
        manager.openDocuments = [
            MarkdownDocument(id: documentId, url: url, content: "initial", isDirty: false)
        ]
        manager.selectedDocumentId = documentId

        manager.updateContent(for: documentId, newContent: "not autosaved")

        // Wait past the 2.0s auto-save debounce interval to prove no timer fires when disabled.
        let waited = expectation(description: "wait past the auto-save debounce window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { waited.fulfill() }
        wait(for: [waited], timeout: 4.0)

        XCTAssertTrue(manager.openDocuments.first?.isDirty ?? false, "should remain dirty — auto-save is disabled")
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, "initial", "disk content must be untouched when auto-save is disabled")
    }

    func testHasUnsavedChangesReflectsMixedDirtyStateAcrossDocuments() {
        let manager = DocumentManager.shared
        let previousDocuments = manager.openDocuments
        defer { manager.openDocuments = previousDocuments }

        let cleanId = UUID()
        let dirtyId = UUID()
        let tmp = FileManager.default.temporaryDirectory

        // All clean -> false.
        manager.openDocuments = [
            MarkdownDocument(id: cleanId, url: tmp.appendingPathComponent("a.md"), content: "a", isDirty: false)
        ]
        XCTAssertFalse(manager.hasUnsavedChanges())

        // One dirty among several clean -> true.
        manager.openDocuments = [
            MarkdownDocument(id: cleanId, url: tmp.appendingPathComponent("a.md"), content: "a", isDirty: false),
            MarkdownDocument(id: dirtyId, url: tmp.appendingPathComponent("b.md"), content: "b", isDirty: true)
        ]
        XCTAssertTrue(manager.hasUnsavedChanges())

        // No open documents -> false.
        manager.openDocuments = []
        XCTAssertFalse(manager.hasUnsavedChanges())
    }

    func testCloseDocumentOnCleanDocumentClosesImmediatelyWithNoAlert() {
        let manager = DocumentManager.shared
        let previousDocuments = manager.openDocuments
        let previousSelectedId = manager.selectedDocumentId
        defer {
            manager.openDocuments = previousDocuments
            manager.selectedDocumentId = previousSelectedId
        }

        let documentId = UUID()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmd-close-clean-\(UUID().uuidString).md")
        let document = MarkdownDocument(id: documentId, url: url, content: "clean", isDirty: false)
        manager.openDocuments = [document]
        manager.selectedDocumentId = documentId

        // If resolveDirtyClose's `guard document.isDirty else { return .proceed }` fast path were
        // broken, this would hang the test process on a real NSAlert.runModal() instead of
        // returning promptly — the test completing at all is the load-bearing assertion.
        manager.closeDocument(document)

        XCTAssertTrue(manager.openDocuments.isEmpty)
        XCTAssertNil(manager.selectedDocumentId)
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

final class FolderManagerLifecycleTests: XCTestCase {
    // Regression pin for the suppression-window drop bug (Plan 007): a genuine external edit
    // landing inside the 800ms self-write suppression window used to be dropped silently with
    // nothing scheduled to catch it. This drives the real FolderManager.shared singleton (its
    // initializer is private) through setFolder/noteSelfWrite/closeFolder with real file I/O,
    // matching the RuntimeSmokeTests pattern above for DocumentManager.shared.
    func testExternalEditWithinSuppressionWindowIsEventuallyReflected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmd-folder-suppress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileA = root.appendingPathComponent("a.md")
        try "initial".write(to: fileA, atomically: true, encoding: .utf8)

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

        manager.setFolder(root)

        // Give the initial scan time to complete and publish.
        let initialScan = expectation(description: "initial scan completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { initialScan.fulfill() }
        wait(for: [initialScan], timeout: 4.0)
        XCTAssertTrue(manager.fileTree.contains { $0.name == "a.md" })

        // Simulate zMD's own save (marks the suppression window), then immediately write a
        // SECOND file externally within that window — this is the exact scenario the bug drops.
        manager.noteSelfWrite(at: fileA)
        let fileB = root.appendingPathComponent("b.md")
        try "external".write(to: fileB, atomically: false, encoding: .utf8)

        // Wait comfortably past FSEvents latency (1.0s) + DirectoryWatcher's debounce (0.3s) +
        // the 800ms self-write suppression window + the deferred-rescan timer, with margin.
        let eventuallyReflected = expectation(description: "b.md eventually appears in sidebar")
        var attempts = 0
        func poll() {
            attempts += 1
            if manager.fileTree.contains(where: { $0.name == "b.md" }) {
                eventuallyReflected.fulfill()
            } else if attempts < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
            }
        }
        poll()
        wait(for: [eventuallyReflected], timeout: 12.0)
    }
}

// MARK: - Plan 013 Step 3: seam-driven tests for prepareForTermination's multi-document logic.

/// Consumes `responses` in call order — one response per dirty document `resolveDirtyClose` asks
/// about. Answering past the end of `responses` returns `.cancel` (a safe default that would stop
/// any further recursion rather than silently discarding data the test didn't intend).
private final class FakeDirtyCloseConfirmer: DirtyCloseConfirming {
    private(set) var callIndex = 0
    private let responses: [DirtyCloseChoice]

    init(responses: [DirtyCloseChoice]) {
        self.responses = responses
    }

    func confirmDirtyClose(for document: MarkdownDocument) -> DirtyCloseChoice {
        defer { callIndex += 1 }
        return callIndex < responses.count ? responses[callIndex] : .cancel
    }
}

final class DocumentManagerTerminationTests: XCTestCase {
    func testDiscardingAllDirtyDocumentsTerminatesNowWithoutCallingCompletion() {
        let manager = DocumentManager.shared
        let previousDocuments = manager.openDocuments
        let previousConfirmer = manager.dirtyCloseConfirmer
        defer {
            manager.openDocuments = previousDocuments
            manager.dirtyCloseConfirmer = previousConfirmer
        }

        let tmp = FileManager.default.temporaryDirectory
        let docA = MarkdownDocument(url: tmp.appendingPathComponent("a-\(UUID().uuidString).md"), content: "a", isDirty: true)
        let docB = MarkdownDocument(url: tmp.appendingPathComponent("b-\(UUID().uuidString).md"), content: "b", isDirty: true)
        manager.openDocuments = [docA, docB]

        let fake = FakeDirtyCloseConfirmer(responses: [.discard, .discard])
        manager.dirtyCloseConfirmer = fake

        var completionCalled = false
        let result = manager.prepareForTermination { _ in completionCalled = true }

        // Both discards resolve synchronously (no NSSavePanel involved), so the whole recursive
        // chain — ask about docA, discard, recurse; ask about docB, discard, recurse; no more
        // dirty docs left — completes within this single call.
        if case .terminateNow = result {} else { XCTFail("expected .terminateNow, got \(result)") }
        XCTAssertEqual(fake.callIndex, 2, "both dirty documents should have been asked about")
        // completion is AppKit's async-reply channel for the .terminateLater case only; a
        // synchronous .terminateNow result must not also invoke it (the caller reads the return
        // value directly — see AppDelegate.applicationShouldTerminate in zMDApp.swift).
        XCTAssertFalse(completionCalled)
    }

    func testCancelOnFirstDirtyDocumentStopsTheChainBeforeAskingAboutTheSecond() {
        let manager = DocumentManager.shared
        let previousDocuments = manager.openDocuments
        let previousConfirmer = manager.dirtyCloseConfirmer
        defer {
            manager.openDocuments = previousDocuments
            manager.dirtyCloseConfirmer = previousConfirmer
        }

        let tmp = FileManager.default.temporaryDirectory
        let docA = MarkdownDocument(url: tmp.appendingPathComponent("a-\(UUID().uuidString).md"), content: "a", isDirty: true)
        let docB = MarkdownDocument(url: tmp.appendingPathComponent("b-\(UUID().uuidString).md"), content: "b", isDirty: true)
        manager.openDocuments = [docA, docB]

        // Cancel on the very first document; a .discard queued second would only be consumed if
        // the (buggy) chain kept going instead of stopping.
        let fake = FakeDirtyCloseConfirmer(responses: [.cancel, .discard])
        manager.dirtyCloseConfirmer = fake

        var completionCalled = false
        let result = manager.prepareForTermination { _ in completionCalled = true }

        if case .cancel = result {} else { XCTFail("expected .cancel, got \(result)") }
        XCTAssertEqual(fake.callIndex, 1, "the second document must never be asked once the first cancels")
        XCTAssertFalse(completionCalled)
    }

    func testSavingTheOnlyDirtyDocumentDefersAndEventuallyCompletesTermination() throws {
        let manager = DocumentManager.shared
        let previousDocuments = manager.openDocuments
        let previousConfirmer = manager.dirtyCloseConfirmer
        defer {
            manager.openDocuments = previousDocuments
            manager.dirtyCloseConfirmer = previousConfirmer
        }

        // A real, non-untitled, writable URL so saveDocument takes its direct-write branch
        // instead of popping an NSSavePanel (which would hang the test).
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmd-terminate-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try "initial".write(to: url, atomically: true, encoding: .utf8)

        let documentId = UUID()
        let document = MarkdownDocument(id: documentId, url: url, content: "unsaved edits", isDirty: true)
        manager.openDocuments = [document]

        let fake = FakeDirtyCloseConfirmer(responses: [.save])
        manager.dirtyCloseConfirmer = fake

        let completed = expectation(description: "termination completes after the deferred save finishes")
        var completionResult: Bool?
        let result = manager.prepareForTermination { success in
            completionResult = success
            completed.fulfill()
        }

        // Save is asynchronous (NSSavePanel-shaped API even on the direct-write branch, which
        // still round-trips through a completion closure), so the outer call returns
        // .terminateLater immediately; completion fires later once the save — and the recursive
        // re-check that finds nothing left dirty — finishes.
        if case .terminateLater = result {} else { XCTFail("expected .terminateLater, got \(result)") }

        wait(for: [completed], timeout: 4.0)

        XCTAssertEqual(completionResult, true)
        XCTAssertEqual(fake.callIndex, 1)
        XCTAssertFalse(manager.openDocuments.first?.isDirty ?? true)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, "unsaved edits")
    }
}
