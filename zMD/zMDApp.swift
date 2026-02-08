import SwiftUI

@main
struct zMDApp: App {
    @StateObject private var documentManager = DocumentManager.shared
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var folderManager = FolderManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showingHelp = false

    init() {
        // DocumentManager.shared is now available immediately for file opening at launch
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(documentManager)
                .environmentObject(folderManager)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
                .frame(minWidth: 700, minHeight: 550)
                .onAppear {
                    // Set up window delegate after window is created
                    DispatchQueue.main.async {
                        if let window = NSApplication.shared.windows.first {
                            let delegate = WindowCloseDelegate.shared
                            delegate.documentManager = documentManager
                            window.delegate = delegate
                            // Set default window size on first launch
                            if window.frame.width < 900 || window.frame.height < 650 {
                                let screen = window.screen ?? NSScreen.main
                                let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                                let newSize = NSSize(width: 1000, height: 700)
                                let origin = NSPoint(
                                    x: screenFrame.midX - newSize.width / 2,
                                    y: screenFrame.midY - newSize.height / 2
                                )
                                window.setFrame(NSRect(origin: origin, size: newSize), display: true, animate: false)
                            }
                        }
                    }
                    // Restore last-opened folder
                    folderManager.restoreFolder()
                }
                .sheet(isPresented: $showingHelp) {
                    HelpView()
                        .preferredColorScheme(settings.colorScheme)
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

                Button("Quick Open...") {
                    NotificationCenter.default.post(name: .showQuickOpen, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Open Folder...") {
                    folderManager.openFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .option])

                Button("Close Folder") {
                    folderManager.closeFolder()
                }
                .disabled(folderManager.folderURL == nil)

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

            CommandGroup(replacing: .printItem) {
                Button("Print...") {
                    if let selectedId = documentManager.selectedDocumentId,
                       let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                        PrintManager.shared.print(content: document.content, fileName: document.name)
                    }
                }
                .keyboardShortcut("p", modifiers: .command)
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

            CommandGroup(after: .saveItem) {
                Button("Save") {
                    documentManager.saveCurrentDocument()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(documentManager.openDocuments.isEmpty)
            }

            CommandMenu("View") {
                Button("Preview Mode") {
                    documentManager.viewMode = .preview
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Source Mode") {
                    documentManager.viewMode = .source
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Split Mode") {
                    documentManager.viewMode = .split
                }
                .keyboardShortcut("3", modifiers: .command)

                Divider()

                Button(documentManager.isFocusModeActive ? "Exit Focus Mode" : "Focus Mode") {
                    NotificationCenter.default.post(name: .toggleFocusMode, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Divider()

                Button(documentManager.isScrollSyncEnabled ? "Disable Scroll Sync" : "Enable Scroll Sync") {
                    documentManager.isScrollSyncEnabled.toggle()
                }

                Divider()

                Button("Command Palette...") {
                    NotificationCenter.default.post(name: .showCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()

                Button("Zoom In") {
                    SettingsManager.shared.zoomIn()
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Zoom Out") {
                    SettingsManager.shared.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Zoom") {
                    SettingsManager.shared.resetZoom()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandGroup(replacing: .toolbar) {
                Button("Refresh") {
                    documentManager.refreshCurrentDocument()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(documentManager.openDocuments.isEmpty)

                Divider()

                Button("Resume File Watching") {
                    documentManager.resumeFileWatching()
                }
                .disabled(!documentManager.ignoreAllFileChanges)
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

                Button("Refresh Tab") {
                    documentManager.refreshCurrentDocument()
                }
                .keyboardShortcut("r", modifiers: .command)
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
                Divider()

                Button("Find...") {
                    documentManager.startSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(documentManager.openDocuments.isEmpty)

                Button("Find Next") {
                    documentManager.nextMatch()
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(documentManager.searchMatches.isEmpty)

                Button("Find Previous") {
                    documentManager.previousMatch()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(documentManager.searchMatches.isEmpty)
            }

            // Help menu
            CommandGroup(replacing: .help) {
                Button("zMD Help") {
                    showingHelp = true
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(settings.colorScheme)
        }
    }
}

// AppDelegate to prevent app from quitting when window closes
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register for Apple Events to handle file opening
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Handle files opened from Finder using shared DocumentManager
        let documentManager = DocumentManager.shared

        for url in urls {
            if url.pathExtension == "md" || url.pathExtension == "markdown" {
                documentManager.loadDocument(from: url)
            }
        }
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        let documentManager = DocumentManager.shared

        if let urlList = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) {
            for i in 1...urlList.numberOfItems {
                if let urlString = urlList.atIndex(i)?.stringValue,
                   let url = URL(string: urlString) {
                    if url.pathExtension == "md" || url.pathExtension == "markdown" {
                        documentManager.loadDocument(from: url)
                    }
                }
            }
        }
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
                // Warn about unsaved changes
                if document.isDirty {
                    let shouldSave = AlertManager.shared.showConfirmation(
                        title: "Save Changes?",
                        message: "Do you want to save changes to \"\(document.name)\" before closing?",
                        confirmButton: "Save",
                        cancelButton: "Don't Save"
                    )
                    if shouldSave {
                        documentManager.saveDocument(id: document.id)
                    }
                }
                documentManager.closeDocument(document)
            }
            // Don't close the window, just closed the document
            return false
        }

        // If no documents are open, also don't close (show welcome screen)
        return false
    }
}
