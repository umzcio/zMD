import SwiftUI

struct ContentView: View {
    @EnvironmentObject var documentManager: DocumentManager
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
                        currentMatch: documentManager.currentMatchIndex + 1,
                        totalMatches: documentManager.searchMatches.count,
                        onSearch: {
                            documentManager.performSearch()
                        },
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
                    .task(id: documentManager.searchText) {
                        // Debounce search - wait for user to stop typing
                        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                        if !Task.isCancelled {
                            documentManager.performSearch()
                        }
                    }

                    Divider()
                }

                // Content area with optional outline
                if let selectedId = documentManager.selectedDocumentId,
                   let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                    HStack(spacing: 0) {
                        if showOutline {
                            OutlineView(content: document.content, selectedHeadingId: $selectedHeadingId)
                            Divider()
                        }
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
                            }
                        )
                    }
                } else {
                    EmptyDocumentView()
                }
            } else {
                WelcomeView()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .overlay {
            QuickOpenOverlay(isPresented: $showQuickOpen)
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

#Preview {
    ContentView()
        .environmentObject(DocumentManager())
}
