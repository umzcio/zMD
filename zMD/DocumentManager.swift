import SwiftUI
import UniformTypeIdentifiers

class DocumentManager: ObservableObject {
    @Published var openDocuments: [MarkdownDocument] = []
    @Published var selectedDocumentId: UUID?
    @Published var recentFileURLs: [URL] = []

    private let maxRecentFiles = 10
    private let recentFilesKey = "RecentMarkdownFiles"

    init() {
        loadRecentFiles()
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
            let content = try String(contentsOf: url, encoding: .utf8)
            let document = MarkdownDocument(url: url, content: content)
            openDocuments.append(document)
            selectedDocumentId = document.id

            // Add to recent files
            addToRecentFiles(url: url)
        } catch {
            print("Error loading file: \(error)")
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

    func closeDocument(_ document: MarkdownDocument) {
        if let index = openDocuments.firstIndex(where: { $0.id == document.id }) {
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
    let id = UUID()
    let url: URL
    let content: String

    var name: String {
        url.lastPathComponent
    }
}
