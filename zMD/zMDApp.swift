import SwiftUI

@main
struct zMDApp: App {
    @StateObject private var documentManager = DocumentManager()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Pass the document manager to the app delegate
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(documentManager)
                .onAppear {
                    // Set up window delegate after window is created
                    DispatchQueue.main.async {
                        if let window = NSApplication.shared.windows.first {
                            let delegate = WindowCloseDelegate.shared
                            delegate.documentManager = documentManager
                            window.delegate = delegate
                        }
                    }
                }
        }
        .commands {
            // Remove the default Close Window command to prevent ⌘W from closing the window
            CommandGroup(replacing: .appTermination) {
                Button("Quit zMD") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }

            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    documentManager.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    if documentManager.recentFileURLs.isEmpty {
                        Text("No Recent Files")
                            .disabled(true)
                    } else {
                        ForEach(documentManager.recentFileURLs, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                documentManager.loadDocument(from: url)
                            }
                        }

                        Divider()

                        Button("Clear Items") {
                            documentManager.clearRecentFiles()
                        }
                    }
                }

                Divider()

                Button("Open File Location") {
                    if let selectedId = documentManager.selectedDocumentId,
                       let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                        documentManager.revealInFinder(document: document)
                    }
                }
                .disabled(documentManager.openDocuments.isEmpty)

                Divider()

                Button("Duplicate...") {
                    if let selectedId = documentManager.selectedDocumentId,
                       let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                        documentManager.duplicateDocument(document: document)
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(documentManager.openDocuments.isEmpty)

                Button("Rename...") {
                    if let selectedId = documentManager.selectedDocumentId,
                       let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                        documentManager.renameDocument(document: document)
                    }
                }
                .disabled(documentManager.openDocuments.isEmpty)

                Button("Move To...") {
                    if let selectedId = documentManager.selectedDocumentId,
                       let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                        documentManager.moveDocument(document: document)
                    }
                }
                .disabled(documentManager.openDocuments.isEmpty)
            }

            CommandGroup(after: .importExport) {
                Menu("Export") {
                    Button("PDF...") {
                        if let selectedId = documentManager.selectedDocumentId,
                           let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                            ExportManager.shared.exportToPDF(content: document.content, fileName: document.name)
                        }
                    }
                    .disabled(documentManager.openDocuments.isEmpty)

                    Divider()

                    Button("HTML...") {
                        if let selectedId = documentManager.selectedDocumentId,
                           let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                            ExportManager.shared.exportToHTML(content: document.content, fileName: document.name, includeStyles: true)
                        }
                    }
                    .disabled(documentManager.openDocuments.isEmpty)

                    Button("HTML (without styles)...") {
                        if let selectedId = documentManager.selectedDocumentId,
                           let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                            ExportManager.shared.exportToHTML(content: document.content, fileName: document.name, includeStyles: false)
                        }
                    }
                    .disabled(documentManager.openDocuments.isEmpty)

                    Divider()

                    Button("Word (.docx)...") {
                        if let selectedId = documentManager.selectedDocumentId,
                           let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                            ExportManager.shared.exportToDOCX(content: document.content, fileName: document.name)
                        }
                    }
                    .disabled(documentManager.openDocuments.isEmpty)

                    Button("Word (.rtf)...") {
                        if let selectedId = documentManager.selectedDocumentId,
                           let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                            ExportManager.shared.exportToWord(content: document.content, fileName: document.name)
                        }
                    }
                    .disabled(documentManager.openDocuments.isEmpty)
                }
            }

            CommandMenu("Tab") {
                Button("Close Tab") {
                    if let selectedId = documentManager.selectedDocumentId,
                       let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                        documentManager.closeDocument(document)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(documentManager.openDocuments.isEmpty)

                Divider()

                Button("Next Tab") {
                    documentManager.selectNextTab()
                }
                .keyboardShortcut(.tab, modifiers: .control)

                Button("Previous Tab") {
                    documentManager.selectPreviousTab()
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            }

            // Enable standard Edit menu commands
            CommandGroup(after: .textEditing) {
                // This ensures standard copy/paste/select all commands work
            }
        }
    }
}

// AppDelegate to prevent app from quitting when window closes
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// Window delegate to handle window close events
class WindowCloseDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowCloseDelegate()
    weak var documentManager: DocumentManager?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let documentManager = documentManager else {
            return true
        }

        // If there are open documents, close the current one but keep window open
        if !documentManager.openDocuments.isEmpty {
            if let selectedId = documentManager.selectedDocumentId,
               let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                documentManager.closeDocument(document)
            }
            // Don't close the window, just closed the document
            return false
        }

        // If no documents are open, also don't close (show welcome screen)
        return false
    }
}
