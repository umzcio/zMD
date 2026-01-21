import SwiftUI
import UniformTypeIdentifiers

class DocumentManager: ObservableObject {
    static let shared = DocumentManager()

    @Published var openDocuments: [MarkdownDocument] = []
    @Published var selectedDocumentId: UUID?
    @Published var recentFileURLs: [URL] = []

    // Search state
    @Published var isSearching: Bool = false
    @Published var searchText: String = ""
    @Published var currentMatchIndex: Int = 0
    @Published var searchMatches: [SearchMatch] = []
    @Published var renderedMatchCount: Int = 0

    // File watching
    private var fileWatchers: [UUID: FileWatcher] = [:]
    @Published var ignoreAllFileChanges = false

    // Reading position memory
    private var scrollPositions: [String: CGFloat] = [:]
    private let scrollPositionsKey = "DocumentScrollPositions"

    private let maxRecentFiles = 10
    private let recentFilesKey = "RecentMarkdownFiles"
    private let alertManager = AlertManager.shared

    init() {
        loadRecentFiles()
        loadScrollPositions()
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!]

        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    self.loadDocument(from: url)
                }
            }
        }
    }

    func loadDocument(from url: URL) {
        // Check if already open
        if openDocuments.contains(where: { $0.url == url }) {
            if let doc = openDocuments.first(where: { $0.url == url }) {
                selectedDocumentId = doc.id
            }
            return
        }

        do {
            // Read file data first
            let data = try Data(contentsOf: url)

            // Try UTF-8 first (most common for markdown)
            var content: String?

            if let str = String(data: data, encoding: .utf8) {
                content = str
            }
            // Then try Windows encodings (common for files from Windows)
            else if let str = String(data: data, encoding: .windowsCP1252) {
                content = str
            }
            // Then ISO Latin-1
            else if let str = String(data: data, encoding: .isoLatin1) {
                content = str
            }
            // Then Mac Roman
            else if let str = String(data: data, encoding: .macOSRoman) {
                content = str
            }
            // UTF-16 only if file starts with BOM
            else if data.count >= 2 && (data[0] == 0xFF && data[1] == 0xFE || data[0] == 0xFE && data[1] == 0xFF) {
                content = String(data: data, encoding: .utf16)
            }
            // Last resort: lossy UTF-8
            else {
                content = String(decoding: data, as: UTF8.self)
            }

            guard let fileContent = content else {
                throw NSError(domain: "DocumentManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to decode file with any supported encoding"])
            }

            let document = MarkdownDocument(url: url, content: fileContent)
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

        // Try encodings in order
        var content: String?
        if let str = String(data: data, encoding: .utf8) {
            content = str
        } else if let str = String(data: data, encoding: .windowsCP1252) {
            content = str
        } else if let str = String(data: data, encoding: .isoLatin1) {
            content = str
        } else {
            content = String(decoding: data, as: UTF8.self)
        }

        guard let fileContent = content else {
            alertManager.showFileLoadError(url: document.url, error: NSError(domain: "DocumentManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to decode file"]))
            return
        }

        // Update the document in the array
        if let index = openDocuments.firstIndex(where: { $0.id == document.id }) {
            fileWatchers[document.id]?.ignoreNextChange = true
            let newDocument = MarkdownDocument(id: document.id, url: document.url, content: fileContent)
            openDocuments[index] = newDocument
        }
    }

    // MARK: - Recent Files Management

    private func loadRecentFiles() {
        if let bookmarksData = UserDefaults.standard.array(forKey: recentFilesKey) as? [Data] {
            recentFileURLs = bookmarksData.compactMap { data -> URL? in
                var isStale = false
                guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
                    return nil
                }
                return url
            }
        }
    }

    private func saveRecentFiles() {
        let bookmarksData = recentFileURLs.compactMap { url -> Data? in
            try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarksData, forKey: recentFilesKey)
    }

    private func addToRecentFiles(url: URL) {
        // Remove if already exists
        recentFileURLs.removeAll { $0 == url }

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

    func setScrollPosition(_ position: CGFloat, for url: URL) {
        scrollPositions[url.path] = position
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

    func closeDocument(_ document: MarkdownDocument) {
        if let index = openDocuments.firstIndex(where: { $0.id == document.id }) {
            // Clear search state if closing the document being searched
            if document.id == selectedDocumentId && isSearching {
                endSearch()
            }

            // Stop file watching
            stopWatchingFile(for: document)

            openDocuments.remove(at: index)

            // Select another document if available
            if !openDocuments.isEmpty {
                selectedDocumentId = openDocuments.last?.id
            } else {
                selectedDocumentId = nil
            }
        }
    }

    func closeOtherDocuments(except document: MarkdownDocument) {
        // Clear search when closing multiple tabs
        if isSearching {
            endSearch()
        }

        // Stop file watching for closed documents
        for doc in openDocuments where doc.id != document.id {
            stopWatchingFile(for: doc)
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
        savePanel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!]
        savePanel.directoryURL = document.url.deletingLastPathComponent()
        savePanel.nameFieldStringValue = document.url.deletingPathExtension().lastPathComponent + " copy.md"
        savePanel.title = "Duplicate File"
        savePanel.message = "Choose where to save the duplicate file"

        savePanel.begin { response in
            guard response == .OK, let newURL = savePanel.url else { return }

            do {
                try document.content.write(to: newURL, atomically: true, encoding: .utf8)
                // Open the duplicated file
                self.loadDocument(from: newURL)
            } catch {
                print("Error duplicating file: \(error)")
            }
        }
    }

    func renameDocument(document: MarkdownDocument) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!]
        savePanel.directoryURL = document.url.deletingLastPathComponent()
        savePanel.nameFieldStringValue = document.url.lastPathComponent
        savePanel.title = "Rename File"
        savePanel.message = "Enter a new name for the file"

        savePanel.begin { response in
            guard response == .OK, let newURL = savePanel.url else { return }

            // Don't do anything if the name hasn't changed
            guard newURL != document.url else { return }

            do {
                // Move the file to the new name
                try FileManager.default.moveItem(at: document.url, to: newURL)

                // Update the document in the array
                if let index = self.openDocuments.firstIndex(where: { $0.id == document.id }) {
                    self.openDocuments.remove(at: index)
                    let newDocument = MarkdownDocument(url: newURL, content: document.content)
                    self.openDocuments.insert(newDocument, at: index)
                    self.selectedDocumentId = newDocument.id
                }
            } catch {
                print("Error renaming file: \(error)")
            }
        }
    }

    func moveDocument(document: MarkdownDocument) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!]
        savePanel.nameFieldStringValue = document.url.lastPathComponent
        savePanel.title = "Move File"
        savePanel.message = "Choose a new location for the file"

        savePanel.begin { response in
            guard response == .OK, let newURL = savePanel.url else { return }

            // Don't do anything if the location hasn't changed
            guard newURL != document.url else { return }

            do {
                // Move the file to the new location
                try FileManager.default.moveItem(at: document.url, to: newURL)

                // Update the document in the array
                if let index = self.openDocuments.firstIndex(where: { $0.id == document.id }) {
                    self.openDocuments.remove(at: index)
                    let newDocument = MarkdownDocument(url: newURL, content: document.content)
                    self.openDocuments.insert(newDocument, at: index)
                    self.selectedDocumentId = newDocument.id
                }
            } catch {
                print("Error moving file: \(error)")
            }
        }
    }
}

struct MarkdownDocument: Identifiable {
    let id: UUID
    let url: URL
    let content: String

    init(url: URL, content: String) {
        self.id = UUID()
        self.url = url
        self.content = content
    }

    init(id: UUID, url: URL, content: String) {
        self.id = id
        self.url = url
        self.content = content
    }

    var name: String {
        url.lastPathComponent
    }
}

struct SearchMatch: Identifiable {
    let id = UUID()
    let range: Range<String.Index>
    let lineNumber: Int
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
        var searchStartIndex = content.startIndex
        var lineNumber = 1
        var currentLineStart = content.startIndex

        while searchStartIndex < content.endIndex {
            if let range = content.range(of: searchText, options: .caseInsensitive, range: searchStartIndex..<content.endIndex) {
                // Calculate line number
                while currentLineStart < range.lowerBound {
                    if content[currentLineStart] == "\n" {
                        lineNumber += 1
                    }
                    currentLineStart = content.index(after: currentLineStart)
                }

                matches.append(SearchMatch(range: range, lineNumber: lineNumber))
                searchStartIndex = range.upperBound
            } else {
                break
            }
        }

        searchMatches = matches
        if !matches.isEmpty && currentMatchIndex >= matches.count {
            currentMatchIndex = 0
        }
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
