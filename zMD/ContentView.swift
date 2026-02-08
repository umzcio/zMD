import SwiftUI

struct ContentView: View {
    @EnvironmentObject var documentManager: DocumentManager
    @EnvironmentObject var folderManager: FolderManager
    @State private var showOutline = false
    @State private var selectedHeadingId: String?
    @State private var showQuickOpen = false
    @State private var showCommandPalette = false
    @State private var showFocusExitPill = false

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
                        SearchBar(
                            searchText: $documentManager.searchText,
                            isSearching: $documentManager.isSearching,
                            currentMatch: documentManager.renderedMatchCount > 0 ? documentManager.currentMatchIndex + 1 : 0,
                            totalMatches: documentManager.renderedMatchCount,
                            onSearch: { },
                            onNext: {
                                documentManager.nextMatch()
                            },
                            onPrevious: {
                                documentManager.previousMatch()
                            },
                            onClose: {
                                documentManager.endSearch()
                            }
                        )
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

            // Focus mode exit pill
            if documentManager.isFocusModeActive {
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
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .onReceive(NotificationCenter.default.publisher(for: .showQuickOpen)) { _ in
            showQuickOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in
            showCommandPalette = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFocusMode)) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                documentManager.isFocusModeActive.toggle()
            }
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
                        OutlineView(content: document.content, selectedHeadingId: $selectedHeadingId)
                            .transition(.move(edge: .trailing))
                        Divider()
                    }

                    if documentManager.isSplitViewActive,
                       let secondaryId = documentManager.secondaryDocumentId,
                       let secondaryDoc = documentManager.openDocuments.first(where: { $0.id == secondaryId }) {
                        HSplitView {
                            markdownPreview(for: document)

                            VStack(spacing: 0) {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Text(secondaryDoc.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Spacer()
                                    Button(action: { documentManager.closeSplitView() }) {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
                                Divider()

                                MarkdownTextView(
                                    content: secondaryDoc.content,
                                    baseURL: secondaryDoc.url,
                                    scrollToHeadingId: .constant(nil),
                                    searchText: "",
                                    currentMatchIndex: 0,
                                    searchMatches: [],
                                    fontStyle: SettingsManager.shared.fontStyle,
                                    initialScrollPosition: documentManager.getScrollPosition(for: secondaryDoc.url),
                                    onScrollPositionChanged: { position in
                                        documentManager.setScrollPosition(position, for: secondaryDoc.url)
                                    },
                                    onMatchCountChanged: nil
                                )
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

            // Button
            Button(action: {
                documentManager.openFile()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 14))
                    Text("Open Markdown File")
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 24)
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
                    Text("RECENT FILES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
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
            scrollToHeadingId: $selectedHeadingId,
            searchText: documentManager.isSearching ? documentManager.searchText : "",
            currentMatchIndex: documentManager.currentMatchIndex,
            searchMatches: documentManager.searchMatches,
            fontStyle: SettingsManager.shared.fontStyle,
            initialScrollPosition: documentManager.getScrollPosition(for: document.url),
            onScrollPositionChanged: { position in
                documentManager.setScrollPosition(position, for: document.url)
            },
            onMatchCountChanged: { count in
                documentManager.setRenderedMatchCount(count)
            }
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
        SourceEditorView(
            content: sourceEditorBinding(for: document.id),
            onContentChange: { newContent in
                documentManager.updateContent(for: document.id, newContent: newContent)
            }
        )
    }

    @ViewBuilder
    func syncedSourceEditor(for document: MarkdownDocument) -> some View {
        SourceEditorView(
            content: sourceEditorBinding(for: document.id),
            onContentChange: { newContent in
                documentManager.updateContent(for: document.id, newContent: newContent)
            },
            onScrollPercentChanged: documentManager.isScrollSyncEnabled ? { percent in
                guard documentManager.scrollSyncOrigin != .preview else { return }
                documentManager.scrollSyncOrigin = .source
                documentManager.scrollSyncPreviewPercent = percent
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if documentManager.scrollSyncOrigin == .source {
                        documentManager.scrollSyncOrigin = .none
                    }
                }
            } : nil,
            scrollToPercent: documentManager.isScrollSyncEnabled && documentManager.scrollSyncOrigin == .preview ? documentManager.scrollSyncSourcePercent : nil
        )
    }

    @ViewBuilder
    func syncedPreview(for document: MarkdownDocument) -> some View {
        MarkdownTextView(
            content: document.content,
            baseURL: document.url,
            scrollToHeadingId: $selectedHeadingId,
            searchText: documentManager.isSearching ? documentManager.searchText : "",
            currentMatchIndex: documentManager.currentMatchIndex,
            searchMatches: documentManager.searchMatches,
            fontStyle: SettingsManager.shared.fontStyle,
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if documentManager.scrollSyncOrigin == .preview {
                        documentManager.scrollSyncOrigin = .none
                    }
                }
            } : nil,
            scrollToPercent: documentManager.isScrollSyncEnabled && documentManager.scrollSyncOrigin == .source ? documentManager.scrollSyncPreviewPercent : nil
        )
    }

    @ViewBuilder
    func viewModeContent(for document: MarkdownDocument) -> some View {
        switch documentManager.viewMode {
        case .preview:
            markdownPreview(for: document)
        case .source:
            sourceEditor(for: document)
        case .split:
            HSplitView {
                syncedSourceEditor(for: document)
                syncedPreview(for: document)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DocumentManager())
        .environmentObject(FolderManager.shared)
}
