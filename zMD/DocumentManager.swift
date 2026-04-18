import SwiftUI
import UniformTypeIdentifiers

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

    // View mode
    @Published var viewMode: ViewMode = .preview

    // Focus mode
    @Published var isFocusModeActive: Bool = false

    // Cursor position in the active source editor — consumed by StatusBarView.
    // Populated by SourceEditorView.Coordinator.textViewDidChangeSelection. 1-based line/column.
    @Published var currentCursorLine: Int = 1
    @Published var currentCursorColumn: Int = 1

    // Scroll sync in split mode
    @Published var isScrollSyncEnabled: Bool = true
    @Published var scrollSyncSourcePercent: CGFloat = 0
    @Published var scrollSyncPreviewPercent: CGFloat = 0
    var scrollSyncOrigin: ScrollSyncOrigin = .none

    // Auto-save
    @Published var autoSaveEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSaveEnabled, forKey: DefaultsKeys.autoSaveEnabled) }
    }
    private var autoSaveTimer: Timer?

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
    private let scrollPositionsKey = DefaultsKeys.scrollPositions

    // Key aliases — centralized in DefaultsKeys so key strings live in a single place.
    private let maxRecentFiles = Cache.recentFilesLimit
    private let recentFilesKey = DefaultsKeys.recentFiles
    private let alertManager = AlertManager.shared

    /// Decode file data trying multiple encodings, returns content and encoding name.
    /// Order: BOM sniff → strict UTF-8 → CP1252 heuristic → Mac Roman → ISO-8859-1 catch-all.
    /// CP1252 and ISO-8859-1 decode arbitrary byte sequences successfully, so they must come AFTER
    /// strict UTF-8 and BOM detection, otherwise UTF-16 / UTF-8 files would be silently misclassified.
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
        // Check if already open
        if openDocuments.contains(where: { $0.url == url }) {
            if let doc = openDocuments.first(where: { $0.url == url }) {
                selectedDocumentId = doc.id
            }
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
            var newDocument = MarkdownDocument(id: document.id, url: document.url, content: fileContent)
            newDocument.detectedEncoding = encoding
            openDocuments[index] = newDocument
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

        // Prune if exceeding limit (remove entries for files that no longer exist)
        if scrollPositions.count > maxScrollPositions {
            let existingPaths = scrollPositions.keys.filter { FileManager.default.fileExists(atPath: $0) }
            let stalePaths = Set(scrollPositions.keys).subtracting(existingPaths)
            for path in stalePaths {
                scrollPositions.removeValue(forKey: path)
            }
            // If still over limit, just keep the most recent entries (by removing random old ones)
            if scrollPositions.count > maxScrollPositions {
                let excess = scrollPositions.count - maxScrollPositions
                let keysToRemove = Array(scrollPositions.keys.prefix(excess))
                for key in keysToRemove {
                    scrollPositions.removeValue(forKey: key)
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
    }

    func closeSplitView() {
        secondaryDocumentId = nil
        isSplitViewActive = false
    }

    // MARK: - Content Editing & Save

    func updateContent(for documentId: UUID, newContent: String) {
        guard let index = openDocuments.firstIndex(where: { $0.id == documentId }) else { return }
        openDocuments[index].content = newContent
        openDocuments[index].isDirty = true

        // Pause file watcher during editing
        fileWatchers[documentId]?.pause()

        // Schedule auto-save if enabled (skip for untitled files)
        if autoSaveEnabled && !(openDocuments[index].isUntitled) {
            autoSaveTimer?.invalidate()
            autoSaveTimer = Timer.scheduledTimer(withTimeInterval: Timing.autoSaveDebounce, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                // Never auto-save while a file-change dialog is outstanding for this doc,
                // or while the doc no longer exists in the open set.
                guard !self.pendingExternalChange.contains(documentId) else { return }
                guard self.openDocuments.contains(where: { $0.id == documentId }) else { return }
                self.saveDocument(id: documentId)
            }
        }
    }

    func saveDocument(id: UUID) {
        guard let index = openDocuments.firstIndex(where: { $0.id == id }) else { return }
        let document = openDocuments[index]

        // Untitled documents need a save dialog first
        if document.isUntitled {
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [UTType(filenameExtension: "md")].compactMap { $0 }
            savePanel.nameFieldStringValue = document.url.lastPathComponent
            savePanel.begin { [weak self] response in
                guard response == .OK, let newURL = savePanel.url else { return }
                guard let self = self,
                      let idx = self.openDocuments.firstIndex(where: { $0.id == id }) else { return }
                do {
                    let enc = DocumentManager.encoding(for: self.openDocuments[idx].detectedEncoding)
                    try self.openDocuments[idx].content.write(to: newURL, atomically: true, encoding: enc)
                    self.openDocuments[idx].url = newURL
                    self.openDocuments[idx].isUntitled = false
                    self.openDocuments[idx].isDirty = false
                    self.openDocuments[idx].bookmarkData = try? newURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    self.startWatchingFile(for: self.openDocuments[idx])
                    self.addToRecentFiles(url: newURL)
                    ToastManager.shared.show("File saved", style: .success)
                } catch {
                    self.alertManager.showError("Save Failed", message: error.localizedDescription)
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
            }
        }

        let saveEncoding = DocumentManager.encoding(for: document.detectedEncoding)

        do {
            try document.content.write(to: resolvedURL, atomically: true, encoding: saveEncoding)
            if accessGranted { resolvedURL.stopAccessingSecurityScopedResource() }
            openDocuments[index].isDirty = false

            // Resume file watcher, ignoring this change
            fileWatchers[id]?.ignoreNextChange = true
            fileWatchers[id]?.resume()

            ToastManager.shared.show("File saved", style: .success)
        } catch {
            // Release security scope before falling back to NSSavePanel
            if accessGranted { resolvedURL.stopAccessingSecurityScopedResource() }

            // Fall back to NSSavePanel (gets its own sandbox access)
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = document.url.lastPathComponent
            savePanel.directoryURL = document.url.deletingLastPathComponent()
            savePanel.begin { [weak self] response in
                guard response == .OK, let newURL = savePanel.url else { return }
                do {
                    try document.content.write(to: newURL, atomically: true, encoding: saveEncoding)
                    self?.openDocuments[index].isDirty = false
                    self?.openDocuments[index].url = newURL
                    self?.openDocuments[index].bookmarkData = try? newURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    self?.fileWatchers[id]?.ignoreNextChange = true
                    self?.fileWatchers[id]?.resume()
                } catch {
                    self?.alertManager.showError("Save Failed", message: error.localizedDescription)
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

    /// Ask the user whether to save, discard, or cancel before closing a dirty document.
    /// Returns .cancel if the user aborts; returns .save AFTER the save dialog/write completes synchronously for saved docs.
    /// For dirty untitled docs, .save routes to the save panel and we abort the close (the user can close again after the panel confirms).
    private enum DirtyCloseAction { case proceed, cancel, deferToSavePanel }

    private func resolveDirtyClose(_ document: MarkdownDocument) -> DirtyCloseAction {
        guard document.isDirty else { return .proceed }

        let alert = NSAlert()
        alert.messageText = "Save changes to \(document.name)?"
        alert.informativeText = "If you don't save, your changes will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true

        switch alert.runModal() {
        case .alertFirstButtonReturn: // Save
            if document.isUntitled {
                saveDocument(id: document.id)
                return .deferToSavePanel
            } else {
                saveDocument(id: document.id)
                return .proceed
            }
        case .alertSecondButtonReturn: // Don't Save
            return .proceed
        default: // Cancel
            return .cancel
        }
    }

    func closeDocument(_ document: MarkdownDocument) {
        switch resolveDirtyClose(document) {
        case .cancel, .deferToSavePanel:
            return
        case .proceed:
            break
        }

        if let index = openDocuments.firstIndex(where: { $0.id == document.id }) {
            // Clear search state if closing the document being searched
            if document.id == selectedDocumentId && isSearching {
                endSearch()
            }

            // Cancel any pending auto-save for this doc so it can't fire after close.
            autoSaveTimer?.invalidate()
            autoSaveTimer = nil
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

        autoSaveTimer?.invalidate()
        autoSaveTimer = nil

        // Stop file watching for closed documents
        for doc in openDocuments where doc.id != document.id {
            stopWatchingFile(for: doc)
            pendingExternalChange.remove(doc.id)
        }

        openDocuments.removeAll(where: { $0.id != document.id })
        selectedDocumentId = document.id
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
    let range: Range<String.Index>
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
        isSearching = true
        showReplace = true
    }

    func performSearch() {
        guard let selectedId = selectedDocumentId,
              let document = openDocuments.first(where: { $0.id == selectedId }),
              !searchText.isEmpty else {
            searchMatches = []
            currentMatchIndex = 0
            return
        }

        let content = document.content
        var matches: [SearchMatch] = []

        if isRegexSearch {
            // Regex search
            var options: NSRegularExpression.Options = []
            if !isCaseSensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: searchText, options: options) else {
                searchMatches = []
                currentMatchIndex = 0
                return
            }
            let nsContent = content as NSString
            let results = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            for result in results {
                guard let range = Range(result.range, in: content) else { continue }
                let lineNumber = content[content.startIndex..<range.lowerBound].filter { $0 == "\n" }.count + 1
                matches.append(SearchMatch(range: range, lineNumber: lineNumber))
            }
        } else {
            // Plain text search
            var searchOptions: String.CompareOptions = []
            if !isCaseSensitive { searchOptions.insert(.caseInsensitive) }

            var searchStartIndex = content.startIndex
            while searchStartIndex < content.endIndex {
                if let range = content.range(of: searchText, options: searchOptions, range: searchStartIndex..<content.endIndex) {
                    let lineNumber = content[content.startIndex..<range.lowerBound].filter { $0 == "\n" }.count + 1
                    matches.append(SearchMatch(range: range, lineNumber: lineNumber))
                    searchStartIndex = range.upperBound
                } else {
                    break
                }
            }
        }

        searchMatches = matches
        if !matches.isEmpty && currentMatchIndex >= matches.count {
            currentMatchIndex = 0
        }
    }

    func replaceCurrentMatch() {
        guard let selectedId = selectedDocumentId,
              let index = openDocuments.firstIndex(where: { $0.id == selectedId }),
              !searchMatches.isEmpty,
              currentMatchIndex < searchMatches.count else { return }

        let match = searchMatches[currentMatchIndex]
        var content = openDocuments[index].content
        content.replaceSubrange(match.range, with: replaceText)
        updateContent(for: selectedId, newContent: content)
        performSearch()
    }

    func replaceAllMatches() {
        guard let selectedId = selectedDocumentId,
              let index = openDocuments.firstIndex(where: { $0.id == selectedId }),
              !searchMatches.isEmpty else { return }

        var content = openDocuments[index].content
        // Replace in reverse order to maintain valid ranges
        for match in searchMatches.reversed() {
            content.replaceSubrange(match.range, with: replaceText)
        }
        let count = searchMatches.count
        updateContent(for: selectedId, newContent: content)
        performSearch()
        ToastManager.shared.show("Replaced \(count) occurrences", style: .success)
    }

    func nextMatch() {
        guard renderedMatchCount > 0 else { return }
        currentMatchIndex = (currentMatchIndex + 1) % renderedMatchCount
    }

    func previousMatch() {
        guard renderedMatchCount > 0 else { return }
        currentMatchIndex = (currentMatchIndex - 1 + renderedMatchCount) % renderedMatchCount
    }

    func setRenderedMatchCount(_ count: Int) {
        renderedMatchCount = count
        // Reset index if it's out of bounds
        if currentMatchIndex >= count {
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

        // Ask user what to do
        let action = alertManager.showFileChangedDialog(fileName: url.lastPathComponent)

        switch action {
        case .reload:
            reloadDocument(document)
        case .ignore:
            // Do nothing, but update the watcher's timestamp
            watcher.ignoreNextChange = true
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
