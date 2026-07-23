import SwiftUI

struct FocusModeContentView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @Binding var selectedHeadingId: String?

    @ViewBuilder
    var body: some View {
        if let selectedId = documentManager.selectedDocumentId,
           let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                DocumentViewModeContent(
                    document: document,
                    selectedHeadingId: $selectedHeadingId
                )
                .frame(maxWidth: 720)
                Spacer(minLength: 0)
            }
            .background(Color(NSColor.textBackgroundColor).opacity(0.3))
        }
    }
}
