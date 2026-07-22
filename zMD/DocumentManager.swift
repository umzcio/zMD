import SwiftUI
import UniformTypeIdentifiers

/// The user's raw choice when asked whether to save a dirty document before it closes.
/// Deliberately simpler than `DocumentManager.DirtyCloseAction` — that caller-facing enum also
/// encodes "what the caller should do next" (e.g. `.deferToSave` for the async-save-in-progress
/// case); this one only encodes what the user picked. `resolveDirtyClose` translates between them.
enum DirtyCloseChoice {
    case save
    case discard
    case cancel
}

/// Seam for "ask the user what to do about a dirty document" (Plan 013 Phase 1). Lets tests
/// substitute a fake so DocumentManager's dirty-close/quit-safety logic — the highest-risk code
/// in the app — can be exercised without a real, test-process-blocking NSAlert.
protocol DirtyCloseConfirming {
    /// Returns the user's choice for a single dirty document, synchronously. Matches
    /// resolveDirtyClose's prior direct NSAlert.runModal() contract — this seam does not change
    /// sync/async behavior, only who decides the answer.
    func confirmDirtyClose(for document: MarkdownDocument) -> DirtyCloseChoice
}

/// Production implementation — presents the real save/don't-save/cancel NSAlert. Wording and
/// button order are unchanged from the pre-extraction inline implementation.
final class NSAlertDirtyCloseConfirmer: DirtyCloseConfirming {
    func confirmDirtyClose(for document: MarkdownDocument) -> DirtyCloseChoice {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(document.name)?"
        alert.informativeText = "If you don't save, your changes will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}

class DocumentManager: ObservableObject {
    static let shared = DocumentManager()

    @Published var openDocuments: [MarkdownDocument] = []
    @Published var selectedDocumentId: UUID?
    @Published var recentFileURLs: [URL] = []

    // Tab drag-reorder
    @Published var draggingDocumentId: UUID?

    // Split view
    @Published var secondaryDocumentId: UUID?
    @Published var isSplitViewActive: Bool = false
    // Per-pane mode for the two-file split. Each pane independently shows the rendered preview
    // or an editable source editor. Reset to .rendered whenever the split is opened or closed.
    @Published var splitPrimaryMode: SplitPaneMode = .rendered
    @Published var splitSecondaryMode: SplitPaneMode = .rendered

    // View mode
    @Published var viewMode: ViewMode = .preview {
        didSet {
            guard viewMode != oldValue else { return }
            reconcileSearchStateForViewMode()
        }
    }

    // Focus mode
    @Published var isFocusModeActive: Bool = false

    // Cursor position in the active source editor — consumed by StatusBarView.
    // Populated by SourceEditorView.Coordinator.textViewDidChangeSelection. 1-based line/column.
    @Published var currentCursorLine: Int = 1
    @Published var currentCursorColumn: Int = 1

    // Bumped by MarkdownTextView.Coordinator after the diagram-render coalesce timer fires,
    // keyed by the document whose diagram/math just rendered. Forces SwiftUI to re-evaluate
    // the view body so updateNSView runs and rebuilds the attributed string from cache (now
    // containing the rendered Mermaid/KaTeX images). Without this, math/diagrams stay as the
    // purple placeholder text on static docs.
    // Per-document (Plan 003): was previously a single shared Int. The coordinator-side
    // notification handler now filters by document id before this is ever touched, so only
    // the originating document's entry is bumped; other open panes' coordinators return early
    // and never reach this. Entries are not removed when a document closes — the map holds
    // one small Int per document ever opened this session, which is negligible.
    @Published var diagramRenderTicks: [UUID: Int] = [:]

    // Scroll sync in split mode
    @Published var isScrollSyncEnabled: Bool = true
    @Published var scrollSyncSourcePercent: CGFloat = 0
    @Published var scrollSyncPreviewPercent: CGFloat = 0
    var scrollSyncOrigin: ScrollSyncOrigin = .none

    // Auto-save
    @Published var autoSaveEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSaveEnabled, forKey: DefaultsKeys.autoSaveEnabled) }
    }
    // Per-document auto-save timers. Previously a single shared `autoSaveTimer` was reused across
    // all docs, so typing in tab A would cancel tab B's pending save (and Cmd+S during the debounce
    // window left an armed timer that re-saved 2s later, clobbering intermediate undo state).
    // Keyed by document id, mirroring `fileWatchers`.
    private var autoSaveTimers: [UUID: Timer] = [:]

    // Search state
    @Published var isSearching: Bool = false
    @Published var searchText: String = ""
    @Published var currentMatchIndex: Int = 0
    @Published var searchMatches: [SearchMatch] = []
    @Published var renderedMatchCount: Int = 0

    // Find & Replace state
    @Published var replaceText: String = ""
    @Published var isRegexSearch: Bool = false
    @Published var isCaseSensitive: Bool = false
    @Published var showReplace: Bool = false

    // File watching
    private var fileWatchers: [UUID: FileWatcher] = [:]
    @Published var ignoreAllFileChanges = false

    // Documents with a pending external-change dialog — auto-save must not fire while a user decision is outstanding.
    private var pendingExternalChange: Set<UUID> = []

    // Search debouncing — every keystroke triggers performSearch via the ContentView .onChange.
    // For plain-text we run inline (cheap). For regex we hop to a background queue and gate by a
    // monotonic token so a stale background result can't overwrite a newer one.
    private var searchDebounceTimer: Timer?
    private var searchToken: UInt64 = 0
    private static let maxSearchMatches = 10_000

    /// Map a human-readable encoding name (stored on MarkdownDocument.detectedEncoding) back to a String.Encoding.
    /// Callers writing a file must use this so round-tripping preserves the source encoding.
    static func encoding(for name: String) -> String.Encoding {
        switch name {
        case "UTF-16": return .utf16
        case "UTF-32": return .utf32
        case "CP1252": return .windowsCP1252
        case "ISO-8859-1": return .isoLatin1
        case "Mac Roman": return .macOSRoman
        default: return .utf8
        }
    }

    // Reading position memory
    private var scrollPositions: [String: CGFloat] = [:]
    // Per-path access timestamps so eviction can be LRU rather than random. Without this,
    // `Dictionary.keys.prefix(excess)` returned in unspecified order and could drop the user's
    // currently-open doc when the cap was hit (M9).
    private var scrollPositionTouched: [String: Date] = [:]
    private let scrollPositionsKey = DefaultsKeys.scrollPositions

    // Key aliases — centralized in DefaultsKeys so key strings live in a single place.
    private let maxRecentFiles = Cache.recentFilesLimit
    private let recentFilesKey = DefaultsKeys.recentFiles
    private let alertManager = AlertManager.shared

    /// Decode file data trying multiple encodings, returns content and encoding name.
    /// Order: BOM sniff → strict UTF-8 → CP1252 heuristic → Mac Roman → ISO-8859-1 catch-all.
    /// L5 note: CP1252 *almost* decodes any byte sequence — Foundation rejects 5 undefined
    /// positions (0x81, 0x8D, 0x8F, 0x90, 0x9D). When CP1252 fails on those, the chain falls
    /// through to Mac Roman / ISO-8859-1 (latter has no undefined positions). Either way the
    /// strict UTF-8 + BOM checks must come first or UTF-encoded files get misclassified.
    private func decodeFileData(_ data: Data) -> (content: String, encoding: String) {
        // 1) BOM sniff — most reliable discrimination.
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF,
           let str = String(data: data, encoding: .utf8) {
            return (str, "UTF-8")
        }
        if data.count >= 4, data[0] == 0xFF, data[1] == 0xFE, data[2] == 0x00, data[3] == 0x00,
           let str = String(data: data, encoding: .utf32LittleEndian) {
            return (str, "UTF-32")
        }
        if data.count >= 4, data[0] == 0x00, data[1] == 0x00, data[2] == 0xFE, data[3] == 0xFF,
           let str = String(data: data, encoding: .utf32BigEndian) {
            return (str, "UTF-32")
        }
        if data.count >= 2, (data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF),
           let str = String(data: data, encoding: .utf16) {
            return (str, "UTF-16")
        }

        // 2) Strict UTF-8 (returns nil on invalid byte sequences).
        if let str = String(data: data, encoding: .utf8) {
            return (str, "UTF-8")
        }
        // 3) CP1252 — heuristic fallback; decodes any byte sequence.
        if let str = String(data: data, encoding: .windowsCP1252) {
            return (str, "CP1252")
        }
        // 4) Mac Roman.
        if let str = String(data: data, encoding: .macOSRoman) {
            return (str, "Mac Roman")
        }
        // 5) ISO-8859-1 as final catch-all (every byte maps to a code point).
        if let str = String(data: data, encoding: .isoLatin1) {
            return (str, "ISO-8859-1")
        }
        return (String(decoding: data, as: UTF8.self), "UTF-8")
    }

    init() {
        self.autoSaveEnabled = UserDefaults.standard.bool(forKey: DefaultsKeys.autoSaveEnabled)
        loadRecentFiles()
        loadScrollPositions()
    }

    func createNewFile() {
        // Scan existing untitled docs and pick the lowest unused number.
        // Previously a monotonic counter reset on relaunch but never decremented: closing
        // Untitled 2 and then opening a new one produced "Untitled 4.md" instead of "Untitled 2.md".
        let existingNames = Set(openDocuments.map { $0.url.lastPathComponent })
        var name = "Untitled.md"
        var n = 2
        while existingNames.contains(name) {
            name = "Untitled \(n).md"
            n += 1
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)

        var document = MarkdownDocument(url: tempURL, content: "")
        document.isUntitled = true
        document.isDirty = true
        openDocuments.append(document)
        selectedDocumentId = document.id
        viewMode = .source
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }

        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    // Save directory bookmark while NSOpenPanel grants access
                    let parentDir = url.deletingLastPathComponent()
                    let dirBookmark = try? parentDir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    self.loadDocument(from: url, directoryBookmark: dirBookmark)
                }
            }
        }
    }

    func loadDocument(from url: URL, directoryBookmark: Data? = nil) {
        let key = Self.canonicalKey(for: url)

        // Check if already open. Use the same canonical path key as Open Recent so symlinks,
        // standardized paths, and case variants focus the existing tab instead of duplicating it.
        if let doc = openDocuments.first(where: { Self.canonicalKey(for: $0.url) == key }) {
            selectedDocumentId = doc.id
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let (fileContent, encoding) = decodeFileData(data)

            var document = MarkdownDocument(url: url, content: fileContent)
            document.detectedEncoding = encoding
            document.bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            document.directoryBookmarkData = directoryBookmark
            openDocuments.append(document)
            selectedDocumentId = document.id

            // Start file watching
            startWatchingFile(for: document)

            // Add to recent files
            addToRecentFiles(url: url)
        } catch {
            alertManager.showFileLoadError(url: url, error: error)
        }
    }

    // MARK: - File Watching

    private func startWatchingFile(for document: MarkdownDocument) {
        let watcher = FileWatcher(url: document.url)
        watcher.delegate = self
        watcher.startWatching()
        fileWatchers[document.id] = watcher
    }

    private func stopWatchingFile(for document: MarkdownDocument) {
        fileWatchers[document.id]?.stopWatching()
        fileWatchers.removeValue(forKey: document.id)
    }

    func reloadDocument(_ document: MarkdownDocument) {
        guard let data = try? Data(contentsOf: document.url) else {
            alertManager.showFileLoadError(url: document.url, error: NSError(domain: "DocumentManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to read file"]))
            return
        }

        let (fileContent, encoding) = decodeFileData(data)

        if let index = openDocuments.firstIndex(where: { $0.id == document.id }) {
            fileWatchers[document.id]?.ignoreNextChange = true
            // C8: mutate in place. Rebuilding via MarkdownDocument(id:url:content:) dropped every
            // other field (bookmarkData, directoryBookmarkData, isUntitled) — the same field-loss
            // bug already fixed for rename/move. directoryBookmarkData is what MarkdownTextView uses
            // for relative-image access.
            openDocuments[index].content = fileContent
            openDocuments[index].detectedEncoding = encoding
            openDocuments[index].isDirty = false
        }
    }

    // MARK: - Recent Files Management

    /// Canonical path used for case-insensitive dedup on macOS's default HFS+/APFS filesystem.
    private static func canonicalKey(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }

    private func loadRecentFiles() {
        guard let bookmarksData = UserDefaults.standard.array(forKey: recentFilesKey) as? [Data] else { return }

        var urls: [URL] = []
        var rewroteAny = false
        var rewrittenBookmarks: [Data] = []

        for data in bookmarksData {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                // Resolution failed — drop this bookmark (file deleted / volume gone).
                rewroteAny = true
                continue
            }

            // Dedup against earlier entries by canonical path (case-insensitive on macOS).
            if urls.contains(where: { Self.canonicalKey(for: $0) == Self.canonicalKey(for: url) }) {
                rewroteAny = true
                continue
            }

            if isStale {
                // Bookmark is stale (file moved) — regenerate so it resolves next launch.
                if let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    rewrittenBookmarks.append(fresh)
                    rewroteAny = true
                } else {
                    rewrittenBookmarks.append(data)
                }
            } else {
                rewrittenBookmarks.append(data)
            }
            urls.append(url)
        }

        recentFileURLs = urls
        if rewroteAny {
            UserDefaults.standard.set(rewrittenBookmarks, forKey: recentFilesKey)
        }
    }

    private func saveRecentFiles() {
        let bookmarksData = recentFileURLs.compactMap { url -> Data? in
            try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarksData, forKey: recentFilesKey)
    }

    private func addToRecentFiles(url: URL) {
        // Remove any existing entry for this file — canonical compare so /Users/Z/file.md
        // and /users/z/file.md do not both appear on a case-insensitive volume.
        let key = Self.canonicalKey(for: url)
        recentFileURLs.removeAll { Self.canonicalKey(for: $0) == key }

        // Add to beginning
        recentFileURLs.insert(url, at: 0)

        // Limit to max count
        if recentFileURLs.count > maxRecentFiles {
            recentFileURLs = Array(recentFileURLs.prefix(maxRecentFiles))
        }

        saveRecentFiles()
    }

    func clearRecentFiles() {
        recentFileURLs.removeAll()
        saveRecentFiles()
    }

    // MARK: - Scroll Position Memory

    private func loadScrollPositions() {
        if let data = UserDefaults.standard.dictionary(forKey: scrollPositionsKey) as? [String: Double] {
            scrollPositions = data.mapValues { CGFloat($0) }
        }
    }

    private func saveScrollPositions() {
        let data = scrollPositions.mapValues { Double($0) }
        UserDefaults.standard.set(data, forKey: scrollPositionsKey)
    }

    func getScrollPosition(for url: URL) -> CGFloat {
        return scrollPositions[url.path] ?? 0
    }

    private let maxScrollPositions = Cache.scrollPositionLimit

    func setScrollPosition(_ position: CGFloat, for url: URL) {
        // Untitled documents sit at a transient /tmp path that will never be reached again;
        // persisting a scroll entry against that path pollutes UserDefaults until the 100-entry
        // cap kicks in. Skip silently.
        if openDocuments.contains(where: { $0.url == url && $0.isUntitled }) {
            return
        }
        scrollPositions[url.path] = position
        scrollPositionTouched[url.path] = Date()

        // Prune if exceeding limit. First drop stale entries (files no longer on disk); if still
        // over cap, evict the LRU entries by access timestamp.
        if scrollPositions.count > maxScrollPositions {
            let existingPaths = scrollPositions.keys.filter { FileManager.default.fileExists(atPath: $0) }
            let stalePaths = Set(scrollPositions.keys).subtracting(existingPaths)
            for path in stalePaths {
                scrollPositions.removeValue(forKey: path)
                scrollPositionTouched.removeValue(forKey: path)
            }
            if scrollPositions.count > maxScrollPositions {
                let excess = scrollPositions.count - maxScrollPositions
                let lruKeys = scrollPositionTouched
                    .sorted { $0.value < $1.value }
                    .prefix(excess)
                    .map(\.key)
                for key in lruKeys {
                    scrollPositions.removeValue(forKey: key)
                    scrollPositionTouched.removeValue(forKey: key)
                }
            }
        }

        saveScrollPositions()
    }

    // MARK: - File Watching Control

    func resumeFileWatching() {
        ignoreAllFileChanges = false
    }

    // MARK: - Refresh/Reload

    func refreshCurrentDocument() {
        guard let selectedId = selectedDocumentId,
              let document = openDocuments.first(where: { $0.id == selectedId }) else {
            return
        }
        reloadDocument(document)
    }

    // MARK: - Tab Reorder

    func moveDocument(withId id: UUID, toIndex: Int) {
        guard let fromIndex = openDocuments.firstIndex(where: { $0.id == id }),
              fromIndex != toIndex, toIndex >= 0, toIndex < openDocuments.count else { return }
        let doc = openDocuments.remove(at: fromIndex)
        openDocuments.insert(doc, at: toIndex)
    }

    // MARK: - Split View

    func openInSplitView(documentId: UUID) {
        guard documentId != selectedDocumentId else { return }
        secondaryDocumentId = documentId
        isSplitViewActive = true
        splitPrimaryMode = .rendered
        splitSecondaryMode = .rendered
    }

    func closeSplitView() {
        secondaryDocumentId = nil
        isSplitViewActive = false
        splitPrimaryMode = .rendered
        splitSecondaryMode = .rendered
    }

    // MARK: - Content Editing & Save

    func updateContent(for documentId: UUID, newContent: String) {
        guard let index = openDocuments.firstIndex(where: { $0.id == documentId }) else { return }
        openDocuments[index].content = newContent
        openDocuments[index].isDirty = true

        if documentId == selectedDocumentId && isSearching && !searchText.isEmpty {
            performSearch(immediate: true)
        }

        // Note: previously this paused the file watcher per-keystroke and only resumed it on
        // save. With auto-save off and no Cmd+S, the watcher stayed paused after the first
        // keystroke — external changes were silently never detected. `ignoreNextChange` already
        // suppresses self-write echoes from save, so the pause is redundant.

        // Schedule auto-save if enabled (skip for untitled files). Each doc has its own timer
        // so typing in tab A can't cancel a pending save in tab B.
        if autoSaveEnabled && !(openDocuments[index].isUntitled) {
            autoSaveTimers[documentId]?.invalidate()
            autoSaveTimers[documentId] = Timer.scheduledTimer(withTimeInterval: Timing.autoSaveDebounce, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.autoSaveTimers[documentId] = nil
                // Never auto-save while a file-change dialog is outstanding for this doc,
                // or while the doc no longer exists in the open set.
                guard !self.pendingExternalChange.contains(documentId) else { return }
                guard self.openDocuments.contains(where: { $0.id == documentId }) else { return }
                // L4: an external write may have landed during the 2s debounce with its watcher
                // change-event still queued behind this timer. Skip the auto-save so we don't
                // clobber it; the pending watcher event will surface the external-change dialog.
                if self.fileWatchers[documentId]?.hasPendingExternalChange() == true { return }
                self.saveDocument(id: documentId)
            }
        }
    }

    func saveDocument(id: UUID) {
        saveDocument(id: id, completion: nil)
    }

    private func saveDocument(id: UUID, completion: ((Bool) -> Void)?) {
        guard let index = openDocuments.firstIndex(where: { $0.id == id }) else {
            completion?(false)
            return
        }
        // Cancel any pending auto-save for this doc — we're saving right now, the pending
        // timer would fire 2s later and re-save (clobbering intermediate undo state).
        autoSaveTimers[id]?.invalidate()
        autoSaveTimers[id] = nil

        let document = openDocuments[index]

        // Untitled documents need a save dialog first
        if document.isUntitled {
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [UTType(filenameExtension: "md")].compactMap { $0 }
            savePanel.nameFieldStringValue = document.url.lastPathComponent
            savePanel.begin { [weak self] response in
                guard let self = self else { return }
                guard response == .OK, let newURL = savePanel.url else {
                    // User cancelled — surface a toast so they don't think Cmd+S succeeded.
                    ToastManager.shared.show("Save cancelled — changes still unsaved", style: .warning)
                    completion?(false)
                    return
                }
                guard let idx = self.openDocuments.firstIndex(where: { $0.id == id }) else {
                    completion?(false)
                    return
                }
                do {
                    let enc = DocumentManager.encoding(for: self.openDocuments[idx].detectedEncoding)
                    try self.openDocuments[idx].content.write(to: newURL, atomically: true, encoding: enc)
                    self.openDocuments[idx].url = newURL
                    self.openDocuments[idx].isUntitled = false
                    self.openDocuments[idx].isDirty = false
                    self.openDocuments[idx].bookmarkData = try? newURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    FolderManager.shared.noteSelfWrite(at: newURL)
                    self.startWatchingFile(for: self.openDocuments[idx])
                    self.addToRecentFiles(url: newURL)
                    ToastManager.shared.show("File saved", style: .success)
                    completion?(true)
                } catch {
                    self.alertManager.showFileSaveError(url: newURL, error: error)
                    completion?(false)
                }
            }
            return
        }

        // Try using bookmark data for security-scoped access
        var accessGranted = false
        var resolvedURL = document.url

        if let bookmark = document.bookmarkData {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                accessGranted = url.startAccessingSecurityScopedResource()
                resolvedURL = url
                // M10: regenerate the bookmark if stale so it doesn't keep accumulating drift
                // and eventually fail to resolve, falling silently to NSSavePanel.
                if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    openDocuments[index].bookmarkData = fresh
                }
            }
        }

        let saveEncoding = DocumentManager.encoding(for: document.detectedEncoding)

        do {
            try document.content.write(to: resolvedURL, atomically: true, encoding: saveEncoding)
            if accessGranted { resolvedURL.stopAccessingSecurityScopedResource() }
            openDocuments[index].isDirty = false

            // Suppress the self-write echo from per-file watcher and folder DirectoryWatcher.
            fileWatchers[id]?.ignoreNextChange = true
            FolderManager.shared.noteSelfWrite(at: resolvedURL)

            ToastManager.shared.show("File saved", style: .success)
            completion?(true)
        } catch {
            // L2: A document read via a non-UTF-8 fallback (CP1252 / Mac Roman / ISO-8859-1)
            // keeps that encoding for saving. A character the user typed that the encoding cannot
            // represent (emoji, CJK, math symbols) makes write throw
            // NSFileWriteInapplicableStringEncodingError. The NSSavePanel fallback below retries
            // with the SAME encoding and fails identically forever, trapping the user — and with
            // auto-save on it pops an unprompted, always-failing save panel mid-typing. Detect that
            // specific error and convert to UTF-8 instead.
            if (error as NSError).code == NSFileWriteInapplicableStringEncodingError {
                do {
                    try document.content.write(to: resolvedURL, atomically: true, encoding: .utf8)
                    if accessGranted { resolvedURL.stopAccessingSecurityScopedResource() }
                    openDocuments[index].detectedEncoding = "UTF-8"
                    openDocuments[index].isDirty = false
                    fileWatchers[id]?.ignoreNextChange = true
                    FolderManager.shared.noteSelfWrite(at: resolvedURL)
                    ToastManager.shared.show("Saved as UTF-8 — the original encoding couldn't store the new characters", style: .success)
                    completion?(true)
                } catch {
                    if accessGranted { resolvedURL.stopAccessingSecurityScopedResource() }
                    self.alertManager.showFileSaveError(url: resolvedURL, error: error)
                    completion?(false)
                }
                return
            }

            // Release security scope before falling back to NSSavePanel
            if accessGranted { resolvedURL.stopAccessingSecurityScopedResource() }

            // Fall back to NSSavePanel (gets its own sandbox access).
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = document.url.lastPathComponent
            savePanel.directoryURL = document.url.deletingLastPathComponent()
            // Capture content snapshot for the closure — we re-resolve the document index by id
            // at completion time because the user can close other tabs while the panel is up,
            // shifting `index`. Previously the captured `index` could point to the wrong row
            // (or be out of bounds → crash).
            let contentSnapshot = document.content
            savePanel.begin { [weak self] response in
                guard let self = self else { return }
                guard response == .OK, let newURL = savePanel.url else {
                    ToastManager.shared.show("Save cancelled — changes still unsaved", style: .warning)
                    completion?(false)
                    return
                }
                guard let idx = self.openDocuments.firstIndex(where: { $0.id == id }) else {
                    completion?(false)
                    return
                }
                do {
                    try contentSnapshot.write(to: newURL, atomically: true, encoding: saveEncoding)
                    self.openDocuments[idx].isDirty = false
                    self.openDocuments[idx].url = newURL
                    self.openDocuments[idx].bookmarkData = try? newURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    self.fileWatchers[id]?.ignoreNextChange = true
                    FolderManager.shared.noteSelfWrite(at: newURL)
                    ToastManager.shared.show("File saved", style: .success)
                    completion?(true)
                } catch {
                    self.alertManager.showFileSaveError(url: newURL, error: error)
                    completion?(false)
                }
            }
        }
    }

    func saveCurrentDocument() {
        guard let selectedId = selectedDocumentId else { return }
        saveDocument(id: selectedId)
    }

    func hasUnsavedChanges() -> Bool {
        openDocuments.contains(where: { $0.isDirty })
    }

    enum TerminationPreparation {
        case terminateNow
        case terminateLater
        case cancel
    }

    /// Ask the user whether to save, discard, or cancel before closing or quitting with a dirty document.
    /// Save is always treated as deferred because it may need an asynchronous NSSavePanel.
    private enum DirtyCloseAction { case proceed, discard, cancel, deferToSave }

    // Testable seam (Plan 013 Phase 1): swappable so tests can drive resolveDirtyClose's
    // multi-document recursive logic (closeDocument/prepareForTermination) without a real
    // NSAlert.runModal() blocking the test process. `internal` (not `private`) so a
    // `@testable import zMD` test target can substitute a fake — same access-control pattern as
    // ExportManager.safeDOCXHyperlinkURL's testable exposure.
    var dirtyCloseConfirmer: DirtyCloseConfirming = NSAlertDirtyCloseConfirmer()

    private func resolveDirtyClose(_ document: MarkdownDocument, onSaveFinished: ((Bool) -> Void)? = nil) -> DirtyCloseAction {
        guard document.isDirty else { return .proceed }

        switch dirtyCloseConfirmer.confirmDirtyClose(for: document) {
        case .save:
            saveDocument(id: document.id) { success in
                DispatchQueue.main.async {
                    onSaveFinished?(success)
                }
            }
            return .deferToSave
        case .discard:
            return .discard
        case .cancel:
            return .cancel
        }
    }

    func closeDocument(_ document: MarkdownDocument) {
        switch resolveDirtyClose(document, onSaveFinished: { [weak self] success in
            guard success else { return }
            self?.closeDocumentWithoutPrompt(id: document.id)
        }) {
        case .cancel, .deferToSave:
            return
        case .proceed, .discard:
            closeDocumentWithoutPrompt(id: document.id)
        }
    }

    private func closeDocumentWithoutPrompt(id documentId: UUID) {
        if let index = openDocuments.firstIndex(where: { $0.id == documentId }) {
            let document = openDocuments[index]

            // Clear search state if closing the document being searched
            if document.id == selectedDocumentId && isSearching {
                endSearch()
            }

            // Cancel any pending auto-save for this doc so it can't fire after close.
            autoSaveTimers[document.id]?.invalidate()
            autoSaveTimers[document.id] = nil
            pendingExternalChange.remove(document.id)

            // Handle split view: if closing secondary, just close split
            if document.id == secondaryDocumentId {
                closeSplitView()
            }
            // If closing primary while split is active, promote secondary
            else if document.id == selectedDocumentId && isSplitViewActive {
                selectedDocumentId = secondaryDocumentId
                closeSplitView()
            }

            // Stop file watching
            stopWatchingFile(for: document)

            openDocuments.remove(at: index)

            // Clear dragging state if this was the dragged doc
            if draggingDocumentId == document.id {
                draggingDocumentId = nil
            }

            // Select another document if available
            if !openDocuments.isEmpty && selectedDocumentId == document.id {
                selectedDocumentId = openDocuments.last?.id
            } else if openDocuments.isEmpty {
                selectedDocumentId = nil
            }
        }
    }

    func prepareForTermination(completion: @escaping (Bool) -> Void) -> TerminationPreparation {
        prepareForTermination(discardedDirtyDocuments: [], completion: completion)
    }

    private func prepareForTermination(discardedDirtyDocuments: Set<UUID>, completion: @escaping (Bool) -> Void) -> TerminationPreparation {
        guard let document = openDocuments.first(where: { $0.isDirty && !discardedDirtyDocuments.contains($0.id) }) else {
            return .terminateNow
        }

        switch resolveDirtyClose(document, onSaveFinished: { [weak self] success in
            guard success, let self = self else {
                completion(false)
                return
            }

            switch self.prepareForTermination(discardedDirtyDocuments: discardedDirtyDocuments, completion: completion) {
            case .terminateNow:
                completion(true)
            case .cancel:
                completion(false)
            case .terminateLater:
                break
            }
        }) {
        case .cancel:
            return .cancel
        case .deferToSave:
            return .terminateLater
        case .discard:
            var nextDiscarded = discardedDirtyDocuments
            nextDiscarded.insert(document.id)
            return prepareForTermination(discardedDirtyDocuments: nextDiscarded, completion: completion)
        case .proceed:
            var nextDiscarded = discardedDirtyDocuments
            nextDiscarded.insert(document.id)
            return prepareForTermination(discardedDirtyDocuments: nextDiscarded, completion: completion)
        }
    }

    func closeOtherDocuments(except document: MarkdownDocument) {
        // If any of the others are dirty, require one confirmation instead of N nagging dialogs.
        let dirtyOthers = openDocuments.filter { $0.id != document.id && $0.isDirty }
        if !dirtyOthers.isEmpty {
            let alert = NSAlert()
            let count = dirtyOthers.count
            alert.messageText = count == 1
                ? "Close 1 tab with unsaved changes?"
                : "Close \(count) tabs with unsaved changes?"
            alert.informativeText = "Your changes will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Discard & Close")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            if alert.runModal() != .alertFirstButtonReturn { return }
        }

        // Clear search when closing multiple tabs
        if isSearching {
            endSearch()
        }

        // Cancel pending auto-saves for every doc being closed.
        for doc in openDocuments where doc.id != document.id {
            autoSaveTimers[doc.id]?.invalidate()
            autoSaveTimers[doc.id] = nil
        }

        // Stop file watching for closed documents
        for doc in openDocuments where doc.id != document.id {
            stopWatchingFile(for: doc)
            pendingExternalChange.remove(doc.id)
        }

        openDocuments.removeAll(where: { $0.id != document.id })
        selectedDocumentId = document.id
        if isSplitViewActive {
            closeSplitView()
        }
    }

    func selectNextTab() {
        guard !openDocuments.isEmpty else { return }

        if let currentId = selectedDocumentId,
           let currentIndex = openDocuments.firstIndex(where: { $0.id == currentId }) {
            let nextIndex = (currentIndex + 1) % openDocuments.count
            selectedDocumentId = openDocuments[nextIndex].id
        } else {
            selectedDocumentId = openDocuments.first?.id
        }
    }

    func selectPreviousTab() {
        guard !openDocuments.isEmpty else { return }

        if let currentId = selectedDocumentId,
           let currentIndex = openDocuments.firstIndex(where: { $0.id == currentId }) {
            let previousIndex = (currentIndex - 1 + openDocuments.count) % openDocuments.count
            selectedDocumentId = openDocuments[previousIndex].id
        } else {
            selectedDocumentId = openDocuments.last?.id
        }
    }

    // MARK: - File Management Operations

    func revealInFinder(document: MarkdownDocument) {
        NSWorkspace.shared.activateFileViewerSelecting([document.url])
    }

    func duplicateDocument(document: MarkdownDocument) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
        savePanel.directoryURL = document.url.deletingLastPathComponent()
        savePanel.nameFieldStringValue = document.url.deletingPathExtension().lastPathComponent + " copy.md"
        savePanel.title = "Duplicate File"
        savePanel.message = "Choose where to save the duplicate file"

        savePanel.begin { response in
            guard response == .OK, let newURL = savePanel.url else { return }

            do {
                let enc = DocumentManager.encoding(for: document.detectedEncoding)
                try document.content.write(to: newURL, atomically: true, encoding: enc)
                // Open the duplicated file
                self.loadDocument(from: newURL)
            } catch {
                self.alertManager.showError("Duplicate Failed", message: "Error duplicating file: \(error.localizedDescription)")
            }
        }
    }

    func renameDocument(document: MarkdownDocument) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
        savePanel.directoryURL = document.url.deletingLastPathComponent()
        savePanel.nameFieldStringValue = document.url.lastPathComponent
        savePanel.title = "Rename File"
        savePanel.message = "Enter a new name for the file"

        savePanel.begin { response in
            guard response == .OK, let newURL = savePanel.url else { return }

            // Don't do anything if the name hasn't changed
            guard newURL != document.url else { return }

            do {
                let oldURL = document.url
                try FileManager.default.moveItem(at: oldURL, to: newURL)

                // Mutate in place so detectedEncoding, isDirty, isUntitled, bookmarkData, etc.
                // are preserved. Previously we constructed `MarkdownDocument(id:url:content:)` and
                // lost every other field.
                if let index = self.openDocuments.firstIndex(where: { $0.id == document.id }) {
                    self.stopWatchingFile(for: document)
                    self.openDocuments[index].url = newURL
                    // Refresh the security-scoped bookmark to the new path so subsequent saves
                    // still have access.
                    self.openDocuments[index].bookmarkData = try? newURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    self.startWatchingFile(for: self.openDocuments[index])
                    self.migrateScrollPosition(from: oldURL, to: newURL)
                }
            } catch {
                self.alertManager.showError("Rename Failed", message: "Error renaming file: \(error.localizedDescription)")
            }
        }
    }

    func moveDocument(document: MarkdownDocument) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
        savePanel.nameFieldStringValue = document.url.lastPathComponent
        savePanel.title = "Move File"
        savePanel.message = "Choose a new location for the file"

        savePanel.begin { response in
            guard response == .OK, let newURL = savePanel.url else { return }

            // Don't do anything if the location hasn't changed
            guard newURL != document.url else { return }

            do {
                let oldURL = document.url
                try FileManager.default.moveItem(at: oldURL, to: newURL)

                if let index = self.openDocuments.firstIndex(where: { $0.id == document.id }) {
                    self.stopWatchingFile(for: document)
                    self.openDocuments[index].url = newURL
                    self.openDocuments[index].bookmarkData = try? newURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    self.startWatchingFile(for: self.openDocuments[index])
                    self.migrateScrollPosition(from: oldURL, to: newURL)
                }
            } catch {
                self.alertManager.showError("Move Failed", message: "Error moving file: \(error.localizedDescription)")
            }
        }
    }

    /// Move a scroll-position entry to its new path key on rename/move so the user's reading
    /// position survives the file operation. Previously the entry was orphaned at the old path
    /// and a future file landing at that path would inherit the stale offset.
    private func migrateScrollPosition(from oldURL: URL, to newURL: URL) {
        if let pos = scrollPositions.removeValue(forKey: oldURL.path) {
            scrollPositions[newURL.path] = pos
            saveScrollPositions()
        }
    }
}

struct MarkdownDocument: Identifiable {
    let id: UUID
    var url: URL
    var content: String
    var isDirty: Bool = false
    var isUntitled: Bool = false
    var bookmarkData: Data?
    var directoryBookmarkData: Data?
    var detectedEncoding: String = "UTF-8"

    /// Single initializer. Defaults match the member defaults so all call sites can construct
    /// with just `url:` and `content:`; callers needing to preserve state on rename/move should
    /// mutate the existing instance in place (see DocumentManager.renameDocument / moveDocument).
    init(id: UUID = UUID(),
         url: URL,
         content: String,
         isDirty: Bool = false,
         isUntitled: Bool = false,
         bookmarkData: Data? = nil,
         directoryBookmarkData: Data? = nil,
         detectedEncoding: String = "UTF-8") {
        self.id = id
        self.url = url
        self.content = content
        self.isDirty = isDirty
        self.isUntitled = isUntitled
        self.bookmarkData = bookmarkData
        self.directoryBookmarkData = directoryBookmarkData
        self.detectedEncoding = detectedEncoding
    }

    var name: String {
        url.lastPathComponent
    }
}

enum SplitPaneMode: String, CaseIterable {
    case rendered
    case edit
}

enum ViewMode: String, CaseIterable {
    case preview = "Preview"
    case source = "Source"
    case split = "Split"

    var icon: String {
        switch self {
        case .preview: return "doc.richtext"
        case .source: return "doc.text"
        case .split: return "rectangle.split.2x1"
        }
    }
}

struct SearchMatch: Identifiable {
    let id = UUID()
    let range: NSRange
    let lineNumber: Int
}

enum ScrollSyncOrigin {
    case none
    case source
    case preview
}

extension DocumentManager {
    func startSearch() {
        isSearching = true
        searchText = ""
        searchMatches = []
        currentMatchIndex = 0
        renderedMatchCount = 0
    }

    func endSearch() {
        isSearching = false
        searchText = ""
        searchMatches = []
        currentMatchIndex = 0
        renderedMatchCount = 0
        replaceText = ""
        showReplace = false
    }

    func startFindAndReplace() {
        guard viewMode != .preview else { return }
        isSearching = true
        showReplace = true
    }

    var searchControlMatchCount: Int {
        if viewMode == .preview {
            return renderedMatchCount
        }
        return searchMatches.count
    }

    private func reconcileSearchStateForViewMode() {
        if viewMode == .preview {
            showReplace = false
            replaceText = ""
            if currentMatchIndex >= renderedMatchCount {
                currentMatchIndex = 0
            }
        } else if currentMatchIndex >= searchMatches.count {
            currentMatchIndex = 0
        }
    }

    /// Run the current search.
    ///
    /// Plain text search runs synchronously on the main thread (it's cheap even on multi-MB docs).
    /// Regex search hops to a background queue with a monotonic token so a slow pattern (e.g.,
    /// catastrophic backtracker like `(a+)+b`) can't freeze the UI on every keystroke. The result
    /// list is capped at `maxSearchMatches` to bound memory + render cost.
    ///
    /// Pass `immediate: true` to bypass debouncing (used for explicit user actions like clicking
    /// Next/Previous after a programmatic edit).
    func performSearch(immediate: Bool = false) {
        searchDebounceTimer?.invalidate()
        if immediate {
            executeSearch()
            return
        }
        // 200ms debounce: enough to coalesce a typing burst, short enough to feel live.
        searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.executeSearch()
        }
    }

    private func executeSearch() {
        guard let selectedId = selectedDocumentId,
              let document = openDocuments.first(where: { $0.id == selectedId }),
              !searchText.isEmpty else {
            searchMatches = []
            currentMatchIndex = 0
            return
        }

        let content = document.content
        let useRegex = isRegexSearch
        let caseSensitive = isCaseSensitive
        let pattern = searchText

        searchToken &+= 1
        let token = searchToken

        if useRegex {
            // Background: regex evaluation can be O(catastrophic) on adversarial patterns.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let matches = Self.regexMatches(pattern: pattern, content: content, caseSensitive: caseSensitive)
                DispatchQueue.main.async {
                    guard let self = self, self.searchToken == token else { return }
                    self.searchMatches = matches
                    if self.currentMatchIndex >= matches.count {
                        self.currentMatchIndex = 0
                    }
                }
            }
        } else {
            let matches = Self.plainMatches(pattern: pattern, content: content, caseSensitive: caseSensitive)
            searchMatches = matches
            if currentMatchIndex >= matches.count {
                currentMatchIndex = 0
            }
        }
    }

    /// P5: count newlines in content[from..<to]. Used to advance a running line number across
    /// matches without rescanning the whole prefix from startIndex for every match. Because match
    /// positions are monotonic, the scanned regions are disjoint and cover the content at most once,
    /// so total work is O(n) instead of O(n × matches).
    private static func newlineCount(in content: String, from: String.Index, to: String.Index) -> Int {
        var count = 0
        var i = from
        while i < to {
            if content[i] == "\n" { count += 1 }
            i = content.index(after: i)
        }
        return count
    }

    private static func regexMatches(pattern: String, content: String, caseSensitive: Bool) -> [SearchMatch] {
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let nsContent = content as NSString
        let results = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(results.count, maxSearchMatches))
        var lastIndex = content.startIndex
        var runningLine = 1
        for result in results {
            if matches.count >= maxSearchMatches { break }
            guard let range = Range(result.range, in: content) else { continue }
            runningLine += newlineCount(in: content, from: lastIndex, to: range.lowerBound)
            lastIndex = range.lowerBound
            matches.append(SearchMatch(range: result.range, lineNumber: runningLine))
        }
        return matches
    }

    private static func plainMatches(pattern: String, content: String, caseSensitive: Bool) -> [SearchMatch] {
        var searchOptions: NSString.CompareOptions = []
        if !caseSensitive { searchOptions.insert(.caseInsensitive) }
        let nsContent = content as NSString
        var matches: [SearchMatch] = []
        var lastIndex = content.startIndex
        var runningLine = 1
        var searchRange = NSRange(location: 0, length: nsContent.length)
        while searchRange.location < nsContent.length && matches.count < maxSearchMatches {
            let range = nsContent.range(of: pattern, options: searchOptions, range: searchRange)
            guard range.location != NSNotFound else { break }
            guard let swiftRange = Range(range, in: content) else { break }
            runningLine += newlineCount(in: content, from: lastIndex, to: swiftRange.lowerBound)
            lastIndex = swiftRange.lowerBound
            matches.append(SearchMatch(range: range, lineNumber: runningLine))
            let advance = max(1, range.length)
            searchRange.location = range.location + advance
            searchRange.length = max(0, nsContent.length - searchRange.location)
        }
        return matches
    }

    func replaceCurrentMatch() {
        guard viewMode != .preview else { return }
        guard let selectedId = selectedDocumentId,
              let index = openDocuments.firstIndex(where: { $0.id == selectedId }),
              !searchMatches.isEmpty,
              currentMatchIndex < searchMatches.count else { return }

        let match = searchMatches[currentMatchIndex]
        var content = openDocuments[index].content
        let nsContent = content as NSString
        guard match.range.location != NSNotFound,
              match.range.location >= 0,
              NSMaxRange(match.range) <= nsContent.length else {
            performSearch(immediate: true)
            return
        }

        if isRegexSearch {
            // For regex mode, run the pattern over only the match range so capture-group
            // backreferences in `replaceText` (e.g., `$1`, `\1`) expand correctly. Without this,
            // a regex like `(\w+)` with replacement `[$1]` was inserting the literal string `[$1]`.
            var options: NSRegularExpression.Options = []
            if !isCaseSensitive { options.insert(.caseInsensitive) }
            if let regex = try? NSRegularExpression(pattern: searchText, options: options),
               regex.matches(in: content, options: [], range: match.range).contains(where: { NSEqualRanges($0.range, match.range) }) {
                let replaced = regex.stringByReplacingMatches(in: content, options: [], range: match.range, withTemplate: replaceText)
                // stringByReplacingMatches returns the entire content with that one range replaced.
                content = replaced
            } else {
                performSearch(immediate: true)
                return
            }
        } else {
            let currentText = nsContent.substring(with: match.range)
            let compareOptions: NSString.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
            guard currentText.compare(searchText, options: compareOptions) == .orderedSame,
                  let swiftRange = Range(match.range, in: content) else {
                performSearch(immediate: true)
                return
            }
            content.replaceSubrange(swiftRange, with: replaceText)
        }

        updateContent(for: selectedId, newContent: content)
        performSearch(immediate: true)
    }

    func replaceAllMatches() {
        guard viewMode != .preview else { return }
        guard let selectedId = selectedDocumentId,
              let index = openDocuments.firstIndex(where: { $0.id == selectedId }),
              !searchMatches.isEmpty else { return }

        var content = openDocuments[index].content
        var count = 0

        if isRegexSearch {
            var options: NSRegularExpression.Options = []
            if !isCaseSensitive { options.insert(.caseInsensitive) }
            if let regex = try? NSRegularExpression(pattern: searchText, options: options) {
                let nsContent = content as NSString
                count = min(regex.numberOfMatches(in: content, options: [], range: NSRange(location: 0, length: nsContent.length)), Self.maxSearchMatches)
                content = regex.stringByReplacingMatches(
                    in: content,
                    options: [],
                    range: NSRange(location: 0, length: nsContent.length),
                    withTemplate: replaceText
                )
            } else {
                performSearch(immediate: true)
                return
            }
        } else {
            // Replace in reverse order to maintain valid ranges
            let matches = Self.plainMatches(pattern: searchText, content: content, caseSensitive: isCaseSensitive)
            count = matches.count
            for match in matches.reversed() {
                guard let range = Range(match.range, in: content) else { continue }
                content.replaceSubrange(range, with: replaceText)
            }
        }

        guard count > 0 else {
            performSearch(immediate: true)
            return
        }

        updateContent(for: selectedId, newContent: content)
        performSearch(immediate: true)
        ToastManager.shared.show("Replaced \(count) occurrences", style: .success)
    }

    func nextMatch() {
        let count = searchControlMatchCount
        guard count > 0 else { return }
        currentMatchIndex = (currentMatchIndex + 1) % count
    }

    func previousMatch() {
        let count = searchControlMatchCount
        guard count > 0 else { return }
        currentMatchIndex = (currentMatchIndex - 1 + count) % count
    }

    func setRenderedMatchCount(_ count: Int) {
        renderedMatchCount = count
        // Reset index if it's out of bounds
        if viewMode == .preview && currentMatchIndex >= count {
            currentMatchIndex = 0
        }
    }
}

// MARK: - File Watcher Delegate

extension DocumentManager: FileWatcherDelegate {
    func fileWatcher(_ watcher: FileWatcher, fileDidChange url: URL) {
        guard !ignoreAllFileChanges else { return }

        // Find the document that corresponds to this URL
        guard let document = openDocuments.first(where: { $0.url == url }) else { return }

        ToastManager.shared.show("File changed externally", style: .warning)

        // Gate auto-save while we wait on the user's decision.
        pendingExternalChange.insert(document.id)
        defer { pendingExternalChange.remove(document.id) }

        // C4: Pass dirty state so the user is warned before destroying unsaved local edits.
        let action = alertManager.showFileChangedDialog(
            fileName: url.lastPathComponent,
            hasUnsavedChanges: document.isDirty
        )

        switch action {
        case .reload:
            reloadDocument(document)
        case .ignore:
            // L3: Do nothing. The triggering write already advanced the watcher's
            // lastModificationDate before this dialog was shown, so its echo is suppressed by
            // the mod-date guard in FileWatcher.handleFileChange. Arming ignoreNextChange here
            // would instead silently swallow the NEXT genuine external edit.
            break
        case .ignoreAll:
            ignoreAllFileChanges = true
        }
    }

    func fileWatcher(_ watcher: FileWatcher, fileWasDeleted url: URL) {
        // Find the document that corresponds to this URL
        guard let document = openDocuments.first(where: { $0.url == url }) else { return }

        // Show warning that file was deleted
        let shouldClose = alertManager.showConfirmation(
            title: "File Deleted",
            message: "\"\(url.lastPathComponent)\" has been deleted. Do you want to close this tab?",
            confirmButton: "Close Tab",
            cancelButton: "Keep Open"
        )

        if shouldClose {
            closeDocument(document)
        }
    }
}
