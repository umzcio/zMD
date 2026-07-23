import SwiftUI

/// Presents one document in the app's selected mode, or in an explicitly selected split-pane mode.
struct DocumentViewModeContent: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @EnvironmentObject private var settings: SettingsManager

    let document: MarkdownDocument
    @Binding var selectedHeadingId: String?
    var paneMode: SplitPaneMode?
    var previewSupportsSearch = true

    @ViewBuilder
    var body: some View {
        if let paneMode {
            switch paneMode {
            case .rendered:
                preview(searchEnabled: previewSupportsSearch, scrollSyncEnabled: false)
            case .edit:
                sourceEditor(scrollSyncEnabled: false)
            }
        } else {
            switch documentManager.viewMode {
            case .preview:
                preview(searchEnabled: true, scrollSyncEnabled: false)
            case .source:
                VStack(spacing: 0) {
                    editorToolbar
                    sourceEditor(scrollSyncEnabled: false)
                }
            case .split:
                VStack(spacing: 0) {
                    editorToolbar
                    HSplitView {
                        sourceEditor(scrollSyncEnabled: true)
                        preview(searchEnabled: true, scrollSyncEnabled: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var editorToolbar: some View {
        if settings.showEditorToolbar {
            MarkdownToolbarView()
            Divider()
        }
    }

    private func sourceBinding() -> Binding<String> {
        Binding(
            get: {
                documentManager.openDocuments.first(where: { $0.id == document.id })?.content ?? ""
            },
            set: { newValue in
                documentManager.updateContent(for: document.id, newContent: newValue)
            }
        )
    }

    private func sourceEditor(scrollSyncEnabled: Bool) -> some View {
        SourceEditorWithMinimap(
            content: sourceBinding(),
            onContentChange: { newContent in
                documentManager.updateContent(for: document.id, newContent: newContent)
            },
            documentId: document.id,
            zoomLevel: settings.zoomLevel,
            onScrollPercentChanged: scrollSyncEnabled && documentManager.isScrollSyncEnabled ? { percent in
                guard documentManager.scrollSyncOrigin != .preview else { return }
                documentManager.scrollSyncOrigin = .source
                documentManager.scrollSyncPreviewPercent = percent
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.scrollSyncResetDelay) {
                    if documentManager.scrollSyncOrigin == .source {
                        documentManager.scrollSyncOrigin = .none
                    }
                }
            } : nil,
            scrollToPercent: scrollSyncEnabled
                && documentManager.isScrollSyncEnabled
                && documentManager.scrollSyncOrigin == .preview
                ? documentManager.scrollSyncSourcePercent
                : nil,
            searchText: documentManager.isSearching ? documentManager.searchText : "",
            searchMatches: documentManager.isSearching ? documentManager.searchMatches : [],
            currentMatchIndex: documentManager.currentMatchIndex
        )
    }

    private func preview(searchEnabled: Bool, scrollSyncEnabled: Bool) -> some View {
        MarkdownTextView(
            content: document.content,
            baseURL: document.url,
            directoryBookmark: document.directoryBookmarkData,
            documentId: document.id,
            scrollToHeadingId: searchEnabled ? $selectedHeadingId : .constant(nil),
            searchText: searchEnabled && documentManager.isSearching ? documentManager.searchText : "",
            currentMatchIndex: searchEnabled ? documentManager.currentMatchIndex : 0,
            fontStyle: settings.fontStyle,
            zoomLevel: settings.zoomLevel,
            initialScrollPosition: documentManager.getScrollPosition(for: document.url),
            onScrollPositionChanged: { position in
                documentManager.setScrollPosition(position, for: document.url)
            },
            onMatchCountChanged: searchEnabled ? { count in
                documentManager.setRenderedMatchCount(count)
            } : nil,
            onScrollPercentChanged: scrollSyncEnabled && documentManager.isScrollSyncEnabled ? { percent in
                guard documentManager.scrollSyncOrigin != .source else { return }
                documentManager.scrollSyncOrigin = .preview
                documentManager.scrollSyncSourcePercent = percent
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.scrollSyncResetDelay) {
                    if documentManager.scrollSyncOrigin == .preview {
                        documentManager.scrollSyncOrigin = .none
                    }
                }
            } : nil,
            scrollToPercent: scrollSyncEnabled
                && documentManager.isScrollSyncEnabled
                && documentManager.scrollSyncOrigin == .source
                ? documentManager.scrollSyncPreviewPercent
                : nil,
            isRegexSearch: searchEnabled && documentManager.isRegexSearch,
            isCaseSensitive: searchEnabled && documentManager.isCaseSensitive
        )
    }
}
