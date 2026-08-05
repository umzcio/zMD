import SwiftUI

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
                    // Uses content.count as a cheap monotonic proxy — MinimapView debounces
                    // its re-render internally, so false positives from count-collisions are benign.
                    contentVersion: content.count
                )
                .frame(width: 80)
            }
        }
    }
}
