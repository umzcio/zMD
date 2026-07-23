import SwiftUI

/// Composes the source editor with its optional minimap.
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
                onViewsReady: { textView, scrollView in
                    capturedTextView = textView
                    capturedScrollView = scrollView
                },
                searchText: searchText,
                searchMatches: searchMatches,
                currentMatchIndex: currentMatchIndex
            )

            if settings.showMinimap, capturedTextView != nil {
                MinimapViewRepresentable(
                    textView: capturedTextView,
                    scrollView: capturedScrollView,
                    contentVersion: content.count
                )
                .frame(width: 80)
            }
        }
    }
}
