import SwiftUI

@main
struct zMDApp: App {
    @ObservedObject private var documentManager = DocumentManager.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var folderManager = FolderManager.shared
    @ObservedObject private var updateManager = UpdateManager.shared
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

                    // Auto-check for updates (silent, once per 24h)
                    updateManager.checkOnLaunchIfNeeded()
                }
                .sheet(isPresented: $showingHelp) {
                    HelpView()
                        .preferredColorScheme(settings.colorScheme)
                }
                // Update-available prompt is a sheet, not an .alert, because SwiftUI alerts
                // have no scrollable message area — long release notes would push the buttons
                // off the bottom of the screen and users couldn't actually click "Update Now".
                // The sheet has a fixed-height ScrollView for notes and keeps the button row
                // pinned to the bottom regardless of note length.
                .sheet(isPresented: $updateManager.showingUpdateAlert) {
                    UpdateAvailableSheet(
                        updateManager: updateManager,
                        onViewOnGitHub: {
                            if let url = URL(string: "https://github.com/umzcio/zMD/releases/latest") {
                                NSWorkspace.shared.open(url)
                            }
                        },
                        onLater: {
                            updateManager.showingUpdateAlert = false
                            // Reset to idle unconditionally so reopening the sheet starts at
                            // release notes. Previously this only reset on `.failed`, so
                            // clicking "Later" from `.ready` left `stage` stuck there forever —
                            // downloadAndInstall()'s re-entrancy guard (`stage == .idle`) then
                            // permanently no-oped "Update Now" for the rest of the app session.
                            updateManager.stage = .idle
                        }
                    )
                }
        }
        .commands {
            FormatCommands()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updateManager.checkForUpdates()
                }
                .disabled(updateManager.isChecking)
            }

            // Remove the default Close Window command to prevent ⌘W from closing the window
            CommandGroup(replacing: .appTermination) {
                Button("Quit zMD") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }

            CommandGroup(replacing: .newItem) {
                Button("New File...") {
                    documentManager.createNewFile()
                }
                .keyboardShortcut("n", modifiers: .command)

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

                // L13: macOS reflex is ⌘⇧S = Save As. We don't have a true Save-As (the
                // duplicate flow does the same thing) but at least the menu label and shortcut
                // should match user expectation. "Save As..." routes through duplicateDocument
                // which presents an NSSavePanel — equivalent UX.
                Button("Save As...") {
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
                            ExportManager.shared.exportToPDF(content: document.content, fileName: document.name, baseURL: document.url)
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
                            ExportManager.shared.exportToDOCX(content: document.content, fileName: document.name, baseURL: document.url)
                        }
                    }
                    .disabled(documentManager.openDocuments.isEmpty)

                    Button("Word (.rtf)...") {
                        if let selectedId = documentManager.selectedDocumentId,
                           let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                            ExportManager.shared.exportToWord(content: document.content, fileName: document.name, baseURL: document.url)
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

                Button(SettingsManager.shared.showLineNumbers ? "Hide Line Numbers" : "Show Line Numbers") {
                    SettingsManager.shared.showLineNumbers.toggle()
                }

                Button(SettingsManager.shared.showMinimap ? "Hide Minimap" : "Show Minimap") {
                    SettingsManager.shared.showMinimap.toggle()
                }

                Button(SettingsManager.shared.showEditorToolbar ? "Hide Editor Toolbar" : "Show Editor Toolbar") {
                    SettingsManager.shared.showEditorToolbar.toggle()
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

                Divider()

                Button("Refresh") {
                    documentManager.refreshCurrentDocument()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(documentManager.openDocuments.isEmpty)

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

                // Refresh Tab is reachable via this menu for discoverability, but the ⌘R
                // keyboard shortcut lives solely on View → Refresh to avoid duplicate binding.
                Button("Refresh Tab") {
                    documentManager.refreshCurrentDocument()
                }
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

                Button("Find and Replace...") {
                    documentManager.startFindAndReplace()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(documentManager.openDocuments.isEmpty || documentManager.viewMode == .preview)

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

// MARK: - Format Menu Commands

struct FormatCommands: Commands {
    var body: some Commands {
        CommandMenu("Format") {
            Button("Bold") {
                NotificationCenter.default.post(name: .editorFormatBold, object: nil)
            }
            .keyboardShortcut("b", modifiers: .command)

            Button("Italic") {
                NotificationCenter.default.post(name: .editorFormatItalic, object: nil)
            }
            .keyboardShortcut("i", modifiers: .command)

            Button("Strikethrough") {
                NotificationCenter.default.post(name: .editorFormatStrikethrough, object: nil)
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])

            Button("Inline Code") {
                NotificationCenter.default.post(name: .editorFormatInlineCode, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])

            Divider()

            Button("Insert Link") {
                NotificationCenter.default.post(name: .editorInsertLink, object: nil)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("Insert Image") {
                NotificationCenter.default.post(name: .editorInsertImage, object: nil)
            }

            Divider()

            Button("Toggle Heading") {
                NotificationCenter.default.post(name: .editorToggleHeading, object: nil)
            }

            Button("Code Block") {
                NotificationCenter.default.post(name: .editorFormatCodeBlock, object: nil)
            }

            Button("Horizontal Rule") {
                NotificationCenter.default.post(name: .editorInsertHR, object: nil)
            }
        }
    }
}

// AppDelegate to prevent app from quitting when window closes
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch DocumentManager.shared.prepareForTermination(completion: { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }) {
        case .terminateNow:
            return .terminateNow
        case .terminateLater:
            return .terminateLater
        case .cancel:
            return .terminateCancel
        }
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
            // Case-insensitive: Finder happily hands us README.MD; the case-sensitive compare
            // silently ignored it (DropHandler already lowercases — keep the paths consistent).
            let ext = url.pathExtension.lowercased()
            if ext == "md" || ext == "markdown" {
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
                    let ext = url.pathExtension.lowercased()
                    if ext == "md" || ext == "markdown" {
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
                documentManager.closeDocument(document)
            }
            // Don't close the window, just closed the document
            return false
        }

        // If no documents are open, also don't close (show welcome screen)
        return false
    }
}

// MARK: - Update Available Sheet

/// Replaces a SwiftUI `.alert` for update prompts — alerts have no scrollable message area,
/// so long release notes pushed the action buttons off the screen (v2.5 regression).
/// This sheet caps at 520x480, scrolls the release notes, and pins the button row to the bottom.
/// Stateful update wizard sheet. The body switches on `updateManager.stage` so the user sees
/// one dialog whose contents change as the install progresses (release notes → downloading
/// → installing → relaunch). Replaces a stack of separate AlertManager dialogs that the user
/// could double-click into duplicate downloads.
struct UpdateAvailableSheet: View {
    @ObservedObject var updateManager: UpdateManager
    let onViewOnGitHub: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — same for every stage.
            VStack(alignment: .leading, spacing: 8) {
                Text(headerTitle)
                    .font(.system(size: 16, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // Stage-dependent body.
            switch updateManager.stage {
            case .idle:
                if !updateManager.releaseNotes.isEmpty {
                    ScrollView {
                        Text(updateManager.releaseNotes)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }
                    .frame(maxHeight: 280)
                    Divider()
                }
            case .downloading:
                stageContent(label: "Downloading update…", spinner: true)
            case .installing:
                stageContent(label: "Installing to /Applications…", spinner: true)
            case .ready:
                stageContent(label: "Update installed. Relaunch zMD to start using \(updateManager.latestVersion).", spinner: false)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Update failed").font(.system(size: 13, weight: .semibold)).foregroundStyle(.red)
                    Text(message).font(.system(size: 12)).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
                Divider()
            }

            // Stage-dependent button row.
            HStack {
                switch updateManager.stage {
                case .idle:
                    Button("Later", action: onLater)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("View on GitHub", action: onViewOnGitHub)
                    if updateManager.downloadURL != nil {
                        Button("Update Now") { updateManager.downloadAndInstall() }
                            .keyboardShortcut(.defaultAction)
                    }
                case .downloading, .installing:
                    Spacer()
                    Button("Update Now") {}
                        .disabled(true) // visible-but-disabled so the user sees progress is happening
                case .ready:
                    Button("Later", action: onLater)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Relaunch zMD") { updateManager.relaunchAfterUpdate() }
                        .keyboardShortcut(.defaultAction)
                case .failed:
                    Spacer()
                    Button("Close") {
                        updateManager.stage = .idle
                        onLater()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
        .frame(minHeight: 200, maxHeight: 480)
    }

    private var headerTitle: String {
        switch updateManager.stage {
        case .idle: return "Update Available"
        case .downloading: return "Downloading Update"
        case .installing: return "Installing Update"
        case .ready: return "Update Ready"
        case .failed: return "Update Failed"
        }
    }

    private var headerSubtitle: String {
        "zMD \(updateManager.latestVersion) (you have \(updateManager.currentVersion))"
    }

    @ViewBuilder
    private func stageContent(label: String, spinner: Bool) -> some View {
        VStack(alignment: .center, spacing: 12) {
            if spinner {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 32)
        Divider()
    }
}
