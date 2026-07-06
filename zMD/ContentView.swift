import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var documentManager: DocumentManager
    @EnvironmentObject var folderManager: FolderManager
    @EnvironmentObject var settings: SettingsManager
    @AppStorage(DefaultsKeys.showOutline) private var showOutline = false
    @State private var selectedHeadingId: String?
    @State private var showQuickOpen = false
    @State private var showCommandPalette = false
    @State private var showFocusExitPill = false
    @State private var magnifyMonitor: Any?
    @State private var baseZoomForGesture: CGFloat = 1.0

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if !documentManager.openDocuments.isEmpty {
                    // Tab bar (hidden in focus mode)
                    if !documentManager.isFocusModeActive {
                        TabBar(showOutline: $showOutline)
                            .environmentObject(documentManager)

                        Divider()
                    }

                    // Search bar
                    if documentManager.isSearching && !documentManager.isFocusModeActive {
                        Group {
                            if documentManager.showReplace && documentManager.viewMode != .preview {
                                SearchBar(
                                    searchText: $documentManager.searchText,
                                    isSearching: $documentManager.isSearching,
                                    currentMatch: documentManager.searchControlMatchCount > 0 ? documentManager.currentMatchIndex + 1 : 0,
                                    totalMatches: documentManager.searchControlMatchCount,
                                    onNext: { documentManager.nextMatch() },
                                    onPrevious: { documentManager.previousMatch() },
                                    onClose: { documentManager.endSearch() },
                                    showReplace: true,
                                    replaceText: $documentManager.replaceText,
                                    isRegex: documentManager.isRegexSearch,
                                    isCaseSensitive: documentManager.isCaseSensitive,
                                    onToggleRegex: { documentManager.isRegexSearch.toggle(); documentManager.performSearch() },
                                    onToggleCaseSensitive: { documentManager.isCaseSensitive.toggle(); documentManager.performSearch() },
                                    onReplace: { documentManager.replaceCurrentMatch() },
                                    onReplaceAll: { documentManager.replaceAllMatches() }
                                )
                            } else {
                                SearchBar(
                                    searchText: $documentManager.searchText,
                                    isSearching: $documentManager.isSearching,
                                    currentMatch: documentManager.searchControlMatchCount > 0 ? documentManager.currentMatchIndex + 1 : 0,
                                    totalMatches: documentManager.searchControlMatchCount,
                                    onNext: { documentManager.nextMatch() },
                                    onPrevious: { documentManager.previousMatch() },
                                    onClose: { documentManager.endSearch() }
                                )
                            }
                        }
                        .padding(8)
                        .transition(.move(edge: .top).combined(with: .opacity))

                        Divider()
                    }

                    // Content area
                    if documentManager.isFocusModeActive {
                        // Focus mode: centered content, no sidebars
                        focusModeContent()
                    } else {
                        // Normal mode: sidebars and outline
                        normalContent()
                    }

                    // Status bar (hidden in focus mode)
                    if !documentManager.isFocusModeActive {
                        Divider()
                        StatusBarView()
                            .environmentObject(documentManager)
                    }
                } else {
                    WelcomeView()
                }
            }
            .animation(.easeInOut(duration: 0.3), value: documentManager.isFocusModeActive)
            .animation(.easeInOut(duration: 0.15), value: documentManager.isSearching)
            .frame(minWidth: 600, minHeight: 400)

            // Focus mode exit pill + Escape handler. Attach a hidden cancelAction button so
            // Escape triggers `isFocusModeActive = false` without needing a local NSEvent monitor.
            if documentManager.isFocusModeActive {
                // Invisible Escape-to-exit button; accessibility: labeled for screen readers.
                Button("Exit Focus Mode") {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        documentManager.isFocusModeActive = false
                    }
                }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityLabel("Exit Focus Mode")

                VStack {
                    if showFocusExitPill {
                        Button(action: {
                            documentManager.isFocusModeActive = false
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.left.and.arrow.up.right")
                                    .font(.system(size: 10, weight: .medium))
                                Text("Exit Focus Mode")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    Spacer()
                }
                .padding(.top, 12)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFocusExitPill = hovering
                    }
                }
                .allowsHitTesting(true)
            }
        }
        .overlay {
            QuickOpenOverlay(isPresented: $showQuickOpen, selectedHeadingId: $selectedHeadingId)
                .environmentObject(documentManager)
        }
        .overlay {
            if showCommandPalette {
                CommandPaletteOverlay(isPresented: $showCommandPalette)
                    .environmentObject(documentManager)
                    .environmentObject(folderManager)
            }
        }
        .overlay {
            ToastOverlay()
        }
        // The `.keyboardShortcut("o", [.command, .shift])` previously attached here was dead —
        // SwiftUI's .keyboardShortcut only binds to an interactable control (Button, MenuItem).
        // Without a control it was never wired to anything; the real Quick Open shortcut lives
        // on the File menu. Removed.
        // Live search: every keystroke in the find bar must rebuild searchMatches, otherwise
        // Replace operates on stale ranges (or empty array) and silently no-ops or — worse —
        // corrupts the doc by applying replacement at offsets that no longer match. Mirroring
        // the same trigger to regex/case toggles keeps the highlight + replace target in sync.
        .onChange(of: documentManager.searchText) { _ in
            documentManager.performSearch()
        }
        .onChange(of: documentManager.isRegexSearch) { _ in
            documentManager.performSearch()
        }
        .onChange(of: documentManager.isCaseSensitive) { _ in
            documentManager.performSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showQuickOpen)) { _ in
            showCommandPalette = false
            showQuickOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in
            showQuickOpen = false
            showCommandPalette = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFocusMode)) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                documentManager.isFocusModeActive.toggle()
            }
        }
        .onAppear {
            magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
                if event.phase == .began {
                    baseZoomForGesture = SettingsManager.shared.zoomLevel
                }
                // Accumulate delta magnification
                baseZoomForGesture += event.magnification
                let clamped = min(2.0, max(0.5, baseZoomForGesture))
                // Snap to 10% increments on gesture end
                if event.phase == .ended || event.phase == .cancelled {
                    SettingsManager.shared.zoomLevel = (clamped * 10).rounded() / 10
                    baseZoomForGesture = SettingsManager.shared.zoomLevel
                } else {
                    SettingsManager.shared.zoomLevel = clamped
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = magnifyMonitor {
                NSEvent.removeMonitor(monitor)
                magnifyMonitor = nil
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            DropHandler.handle(providers: providers, documentManager: documentManager)
            return true
        }
    }

    @ViewBuilder
    private func normalContent() -> some View {
        HStack(spacing: 0) {
            if folderManager.isShowingFolderSidebar {
                FolderSidebarView()
                    .environmentObject(documentManager)
                    .environmentObject(folderManager)
                    .transition(.move(edge: .leading))
                Divider()
            }

            if let selectedId = documentManager.selectedDocumentId,
               let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                HStack(spacing: 0) {
                    if showOutline {
                        // .id(document.id) forces SwiftUI to create a fresh OutlineView when the
                        // active document changes, so the @State `headings` cache resets and gets
                        // rebuilt from onAppear. Without this, switching tabs sometimes left the
                        // outline showing the previous document's headings (onChange-of-content
                        // doesn't fire reliably across tab swaps on macOS 13).
                        OutlineView(content: document.content, selectedHeadingId: $selectedHeadingId)
                            .id(document.id)
                            .transition(.move(edge: .trailing))
                        Divider()
                    }

                    if documentManager.isSplitViewActive,
                       let secondaryId = documentManager.secondaryDocumentId,
                       let secondaryDoc = documentManager.openDocuments.first(where: { $0.id == secondaryId }) {
                        HSplitView {
                            // Primary (left) pane
                            VStack(spacing: 0) {
                                splitPaneHeader(
                                    name: document.name,
                                    mode: $documentManager.splitPrimaryMode,
                                    onClose: nil
                                )
                                Divider()
                                switch documentManager.splitPrimaryMode {
                                case .rendered:
                                    markdownPreview(for: document)
                                case .edit:
                                    sourceEditor(for: document)
                                }
                            }

                            // Secondary (right) pane
                            VStack(spacing: 0) {
                                splitPaneHeader(
                                    name: secondaryDoc.name,
                                    mode: $documentManager.splitSecondaryMode,
                                    onClose: { documentManager.closeSplitView() }
                                )
                                Divider()
                                switch documentManager.splitSecondaryMode {
                                case .rendered:
                                    MarkdownTextView(
                                        content: secondaryDoc.content,
                                        baseURL: secondaryDoc.url,
                                        directoryBookmark: secondaryDoc.directoryBookmarkData,
                                        scrollToHeadingId: .constant(nil),
                                        searchText: "",
                                        currentMatchIndex: 0,
                                        fontStyle: settings.fontStyle,
                                        zoomLevel: settings.zoomLevel,
                                        initialScrollPosition: documentManager.getScrollPosition(for: secondaryDoc.url),
                                        onScrollPositionChanged: { position in
                                            documentManager.setScrollPosition(position, for: secondaryDoc.url)
                                        },
                                        onMatchCountChanged: nil
                                    )
                                case .edit:
                                    sourceEditor(for: secondaryDoc)
                                }
                            }
                        }
                    } else {
                        viewModeContent(for: document)
                            .animation(.easeInOut(duration: 0.15), value: documentManager.viewMode)
                    }
                }
            } else {
                EmptyDocumentView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: folderManager.isShowingFolderSidebar)
        .animation(.easeInOut(duration: 0.2), value: showOutline)
    }

    @ViewBuilder
    private func focusModeContent() -> some View {
        if let selectedId = documentManager.selectedDocumentId,
           let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                viewModeContent(for: document)
                    .frame(maxWidth: 720)
                Spacer(minLength: 0)
            }
            .background(Color(NSColor.textBackgroundColor).opacity(0.3))
        }
    }
}

extension Notification.Name {
    static let showQuickOpen = Notification.Name("showQuickOpen")
    static let showCommandPalette = Notification.Name("showCommandPalette")
    static let toggleFocusMode = Notification.Name("toggleFocusMode")
}

/// Drop handler for `.fileURL` providers dropped onto the main window.
/// Recurses one level into dropped folders, caps the open-count to avoid the previous
/// 5,000-tabs-at-once footgun, and toasts the skipped-count so the user gets feedback when
/// non-markdown drops or over-cap drops are silently dropped.
enum DropHandler {
    static let maxOpenOnDrop = 20

    static func handle(providers: [NSItemProvider], documentManager: DocumentManager) {
        let group = DispatchGroup()
        var collectedURLs: [URL] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock()
                collectedURLs.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            // Expand folders to immediate-child .md files (no deep recursion — a dropped folder
            // structure shouldn't blow up into thousands of tabs).
            var expanded: [URL] = []
            var nonMarkdownSkipped = 0
            for url in collectedURLs {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        for child in children where Self.isMarkdown(child) {
                            expanded.append(child)
                        }
                    }
                } else if Self.isMarkdown(url) {
                    expanded.append(url)
                } else {
                    nonMarkdownSkipped += 1
                }
            }

            let toOpen = Array(expanded.prefix(maxOpenOnDrop))
            let overCapSkipped = max(0, expanded.count - toOpen.count)

            for url in toOpen {
                documentManager.loadDocument(from: url)
            }

            if toOpen.isEmpty && nonMarkdownSkipped > 0 {
                ToastManager.shared.show("No markdown files found in drop", style: .warning)
            } else if overCapSkipped > 0 {
                ToastManager.shared.show("Opened \(toOpen.count) files; skipped \(overCapSkipped) (cap \(maxOpenOnDrop))", style: .warning)
            } else if nonMarkdownSkipped > 0 {
                ToastManager.shared.show("Opened \(toOpen.count); skipped \(nonMarkdownSkipped) non-markdown", style: .warning)
            }
        }
    }

    private static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }
}

struct WelcomeView: View {
    @EnvironmentObject var documentManager: DocumentManager
    @State private var showIcon = false
    @State private var showSubtitle = false
    @State private var showButton = false
    @State private var showHint = false
    @State private var showRecents = false
    @State private var iconBounce = false
    @State private var buttonHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .scaleEffect(iconBounce ? 1.0 : 0.5)
                .opacity(showIcon ? 1 : 0)
                .padding(.bottom, 16)

            // Subtitle
            Text("Markdown Editor & Viewer")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .opacity(showSubtitle ? 1 : 0)
                .offset(y: showSubtitle ? 0 : 8)

            // Buttons
            HStack(spacing: 12) {
                Button(action: {
                    documentManager.createNewFile()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 14))
                        Text("New File")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                    )
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: {
                    documentManager.openFile()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 14))
                        Text("Open File")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(buttonHovered ? Color.accentColor : Color.accentColor.opacity(0.85))
                    )
                    .foregroundColor(.white)
                    .scaleEffect(buttonHovered ? 1.03 : 1.0)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        buttonHovered = hovering
                    }
                }
            }
            .opacity(showButton ? 1 : 0)
            .offset(y: showButton ? 0 : 8)
            .padding(.top, 24)

            // Keyboard hint
            HStack(spacing: 4) {
                Text("or press")
                    .font(.system(size: 12))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                Text("⌘O")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                    )
            }
            .opacity(showHint ? 1 : 0)
            .padding(.top, 12)

            // Recent files
            if !documentManager.recentFileURLs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("RECENT FILES")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))

                        Spacer()

                        Button("Clear") {
                            withAnimation(.easeOut(duration: 0.2)) {
                                documentManager.clearRecentFiles()
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)

                    ForEach(documentManager.recentFileURLs.prefix(5), id: \.path) { url in
                        Button(action: {
                            documentManager.loadDocument(from: url)
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 12))
                                    .foregroundColor(.accentColor)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RecentFileButtonStyle())
                    }
                }
                .frame(width: 320)
                .padding(.top, 28)
                .opacity(showRecents ? 1 : 0)
                .offset(y: showRecents ? 0 : 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                showIcon = true
                iconBounce = true
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.15)) {
                showSubtitle = true
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.25)) {
                showButton = true
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.35)) {
                showHint = true
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.45)) {
                showRecents = true
            }
        }
    }
}

struct RecentFileButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
                    .padding(.horizontal, 4)
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }
    }
}

struct EmptyDocumentView: View {
    var body: some View {
        VStack {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No document selected")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - Helper Views

extension ContentView {
    @ViewBuilder
    func markdownPreview(for document: MarkdownDocument) -> some View {
        MarkdownTextView(
            content: document.content,
            baseURL: document.url,
            directoryBookmark: document.directoryBookmarkData,
            scrollToHeadingId: $selectedHeadingId,
            searchText: documentManager.isSearching ? documentManager.searchText : "",
            currentMatchIndex: documentManager.currentMatchIndex,
            fontStyle: settings.fontStyle,
            zoomLevel: settings.zoomLevel,
            initialScrollPosition: documentManager.getScrollPosition(for: document.url),
            onScrollPositionChanged: { position in
                documentManager.setScrollPosition(position, for: document.url)
            },
            onMatchCountChanged: { count in
                documentManager.setRenderedMatchCount(count)
            },
            isRegexSearch: documentManager.isRegexSearch,
            isCaseSensitive: documentManager.isCaseSensitive
        )
    }

    func sourceEditorBinding(for documentId: UUID) -> Binding<String> {
        Binding<String>(
            get: {
                documentManager.openDocuments.first(where: { $0.id == documentId })?.content ?? ""
            },
            set: { newValue in
                documentManager.updateContent(for: documentId, newContent: newValue)
            }
        )
    }

    @ViewBuilder
    func sourceEditor(for document: MarkdownDocument) -> some View {
        SourceEditorWithMinimap(
            content: sourceEditorBinding(for: document.id),
            onContentChange: { newContent in
                documentManager.updateContent(for: document.id, newContent: newContent)
            },
            documentId: document.id,
            zoomLevel: settings.zoomLevel,
            searchText: documentManager.isSearching ? documentManager.searchText : "",
            searchMatches: documentManager.isSearching ? documentManager.searchMatches : [],
            currentMatchIndex: documentManager.currentMatchIndex
        )
    }

    /// Header bar for a two-file split pane: file name, a Rendered|Edit toggle bound to that
    /// pane's mode, and an optional close button (used only on the secondary pane).
    @ViewBuilder
    func splitPaneHeader(name: String, mode: Binding<SplitPaneMode>, onClose: (() -> Void)?) -> some View {
        HStack {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()
            Picker("", selection: mode) {
                Text("Rendered").tag(SplitPaneMode.rendered)
                Text("Edit").tag(SplitPaneMode.edit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            if let onClose = onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
    }

    @ViewBuilder
    func syncedSourceEditor(for document: MarkdownDocument) -> some View {
        SourceEditorWithMinimap(
            content: sourceEditorBinding(for: document.id),
            onContentChange: { newContent in
                documentManager.updateContent(for: document.id, newContent: newContent)
            },
            documentId: document.id,
            zoomLevel: settings.zoomLevel,
            onScrollPercentChanged: documentManager.isScrollSyncEnabled ? { percent in
                guard documentManager.scrollSyncOrigin != .preview else { return }
                documentManager.scrollSyncOrigin = .source
                documentManager.scrollSyncPreviewPercent = percent
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.scrollSyncResetDelay) {
                    if documentManager.scrollSyncOrigin == .source {
                        documentManager.scrollSyncOrigin = .none
                    }
                }
            } : nil,
            scrollToPercent: documentManager.isScrollSyncEnabled && documentManager.scrollSyncOrigin == .preview ? documentManager.scrollSyncSourcePercent : nil,
            searchText: documentManager.isSearching ? documentManager.searchText : "",
            searchMatches: documentManager.isSearching ? documentManager.searchMatches : [],
            currentMatchIndex: documentManager.currentMatchIndex
        )
    }
}

/// Composes SourceEditorView + an optional MinimapView side panel.
/// The minimap is gated on SettingsManager.shared.showMinimap. MinimapView needs live
/// NSTextView/NSScrollView references to draw the viewport indicator, so we capture them
/// via SourceEditorView's onViewsReady callback and pass them through once available.
struct SourceEditorWithMinimap: View {
    @Binding var content: String
    let onContentChange: ((String) -> Void)?
    let documentId: UUID
    var zoomLevel: CGFloat = 1.0
    var onScrollPercentChanged: ((CGFloat) -> Void)?
    var scrollToPercent: CGFloat?
    var searchText: String = ""
    var searchMatches: [SearchMatch] = []
    var currentMatchIndex: Int = 0

    @ObservedObject private var settings = SettingsManager.shared
    @State private var capturedTextView: NSTextView?
    @State private var capturedScrollView: NSScrollView?

    var body: some View {
        HStack(spacing: 0) {
            SourceEditorView(
                content: $content,
                onContentChange: onContentChange,
                documentId: documentId,
                zoomLevel: zoomLevel,
                onScrollPercentChanged: onScrollPercentChanged,
                scrollToPercent: scrollToPercent,
                onViewsReady: { tv, sv in
                    capturedTextView = tv
                    capturedScrollView = sv
                },
                searchText: searchText,
                searchMatches: searchMatches,
                currentMatchIndex: currentMatchIndex
            )

            if settings.showMinimap, capturedTextView != nil {
                MinimapViewRepresentable(
                    textView: capturedTextView,
                    scrollView: capturedScrollView,
                    // Uses content.count as a cheap monotonic proxy — MinimapView debounces
                    // its re-render internally, so false positives from count-collisions are benign.
                    contentVersion: content.count
                )
                .frame(width: 80)
            }
        }
    }
}

extension ContentView {
    @ViewBuilder
    func syncedPreview(for document: MarkdownDocument) -> some View {
        MarkdownTextView(
            content: document.content,
            baseURL: document.url,
            directoryBookmark: document.directoryBookmarkData,
            scrollToHeadingId: $selectedHeadingId,
            searchText: documentManager.isSearching ? documentManager.searchText : "",
            currentMatchIndex: documentManager.currentMatchIndex,
            fontStyle: settings.fontStyle,
            zoomLevel: settings.zoomLevel,
            initialScrollPosition: documentManager.getScrollPosition(for: document.url),
            onScrollPositionChanged: { position in
                documentManager.setScrollPosition(position, for: document.url)
            },
            onMatchCountChanged: { count in
                documentManager.setRenderedMatchCount(count)
            },
            onScrollPercentChanged: documentManager.isScrollSyncEnabled ? { percent in
                guard documentManager.scrollSyncOrigin != .source else { return }
                documentManager.scrollSyncOrigin = .preview
                documentManager.scrollSyncSourcePercent = percent
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.scrollSyncResetDelay) {
                    if documentManager.scrollSyncOrigin == .preview {
                        documentManager.scrollSyncOrigin = .none
                    }
                }
            } : nil,
            scrollToPercent: documentManager.isScrollSyncEnabled && documentManager.scrollSyncOrigin == .source ? documentManager.scrollSyncPreviewPercent : nil,
            isRegexSearch: documentManager.isRegexSearch,
            isCaseSensitive: documentManager.isCaseSensitive
        )
    }

    @ViewBuilder
    func viewModeContent(for document: MarkdownDocument) -> some View {
        switch documentManager.viewMode {
        case .preview:
            markdownPreview(for: document)
        case .source:
            VStack(spacing: 0) {
                if SettingsManager.shared.showEditorToolbar {
                    MarkdownToolbarView()
                    Divider()
                }
                sourceEditor(for: document)
            }
        case .split:
            VStack(spacing: 0) {
                if SettingsManager.shared.showEditorToolbar {
                    MarkdownToolbarView()
                    Divider()
                }
                HSplitView {
                    syncedSourceEditor(for: document)
                    syncedPreview(for: document)
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DocumentManager())
        .environmentObject(FolderManager.shared)
        .environmentObject(SettingsManager.shared)
}
