import SwiftUI

@main
struct zMDApp: App {
    @StateObject private var documentManager = DocumentManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(documentManager)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Markdown File...") {
                    documentManager.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
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
