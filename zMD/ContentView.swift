import SwiftUI

struct ContentView: View {
    @EnvironmentObject var documentManager: DocumentManager
    @EnvironmentObject var folderManager: FolderManager
    @State private var showOutline = false
    @State private var selectedHeadingId: String?
    @State private var showQuickOpen = false

    var body: some View {
        VStack(spacing: 0) {
            if !documentManager.openDocuments.isEmpty {
                TabBar(showOutline: $showOutline)
                    .environmentObject(documentManager)

                Divider()

                // Search bar
                if documentManager.isSearching {
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

                    Divider()
                }

                // Content area with optional folder sidebar and outline
                HStack(spacing: 0) {
                    if folderManager.isShowingFolderSidebar {
                        FolderSidebarView()
                            .environmentObject(documentManager)
                            .environmentObject(folderManager)
                        Divider()
                    }

                    if let selectedId = documentManager.selectedDocumentId,
                       let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                        HStack(spacing: 0) {
                            if showOutline {
                                OutlineView(content: document.content, selectedHeadingId: $selectedHeadingId)
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
                            }
                        }
                    } else {
                        EmptyDocumentView()
                    }
                }
            } else {
                WelcomeView()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .overlay {
            QuickOpenOverlay(isPresented: $showQuickOpen, selectedHeadingId: $selectedHeadingId)
                .environmentObject(documentManager)
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .onReceive(NotificationCenter.default.publisher(for: .showQuickOpen)) { _ in
            showQuickOpen = true
        }
    }
}

extension Notification.Name {
    static let showQuickOpen = Notification.Name("showQuickOpen")
}

struct WelcomeView: View {
    @EnvironmentObject var documentManager: DocumentManager

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("zMD")
                .font(.system(size: 32, weight: .bold))

            Text("Zach's Simple Markdown Viewer")
                .font(.system(size: 16))
                .foregroundColor(.secondary)

            Button(action: {
                documentManager.openFile()
            }) {
                HStack {
                    Image(systemName: "folder")
                    Text("Open Markdown File")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)

            Text("or press ⌘O")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
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
    func viewModeContent(for document: MarkdownDocument) -> some View {
        switch documentManager.viewMode {
        case .preview:
            markdownPreview(for: document)
        case .source:
            sourceEditor(for: document)
        case .split:
            HSplitView {
                sourceEditor(for: document)
                markdownPreview(for: document)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DocumentManager())
        .environmentObject(FolderManager.shared)
}
