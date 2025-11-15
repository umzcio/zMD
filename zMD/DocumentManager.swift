import SwiftUI
import UniformTypeIdentifiers

class DocumentManager: ObservableObject {
    @Published var openDocuments: [MarkdownDocument] = []
    @Published var selectedDocumentId: UUID?

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
        } catch {
            print("Error loading file: \(error)")
        }
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
}

struct MarkdownDocument: Identifiable {
    let id = UUID()
    let url: URL
    let content: String

    var name: String {
        url.lastPathComponent
    }
}
