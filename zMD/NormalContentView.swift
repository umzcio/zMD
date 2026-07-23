import SwiftUI

struct NormalContentView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @EnvironmentObject private var folderManager: FolderManager
    @Binding var showOutline: Bool
    @Binding var selectedHeadingId: String?

    var body: some View {
        HStack(spacing: 0) {
            if folderManager.isShowingFolderSidebar {
                FolderSidebarView()
                    .transition(Motion.slideOrFade(edge: .leading))
                Divider()
            }

            if let selectedId = documentManager.selectedDocumentId,
               let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
                HStack(spacing: 0) {
                    if showOutline {
                        OutlineView(content: document.content, selectedHeadingId: $selectedHeadingId)
                            .id(document.id)
                            .transition(Motion.slideOrFade(edge: .trailing))
                        Divider()
                    }

                    if documentManager.isSplitViewActive,
                       let secondaryId = documentManager.secondaryDocumentId,
                       let secondaryDocument = documentManager.openDocuments.first(where: { $0.id == secondaryId }) {
                        HSplitView {
                            VStack(spacing: 0) {
                                SplitPaneHeader(
                                    name: document.name,
                                    mode: $documentManager.splitPrimaryMode,
                                    onClose: nil
                                )
                                Divider()
                                DocumentViewModeContent(
                                    document: document,
                                    selectedHeadingId: $selectedHeadingId,
                                    paneMode: documentManager.splitPrimaryMode
                                )
                            }

                            VStack(spacing: 0) {
                                SplitPaneHeader(
                                    name: secondaryDocument.name,
                                    mode: $documentManager.splitSecondaryMode,
                                    onClose: documentManager.closeSplitView
                                )
                                Divider()
                                DocumentViewModeContent(
                                    document: secondaryDocument,
                                    selectedHeadingId: $selectedHeadingId,
                                    paneMode: documentManager.splitSecondaryMode,
                                    previewSupportsSearch: false
                                )
                            }
                        }
                    } else {
                        DocumentViewModeContent(
                            document: document,
                            selectedHeadingId: $selectedHeadingId
                        )
                        .animation(Motion.fast, value: documentManager.viewMode)
                    }
                }
            } else {
                EmptyDocumentView()
            }
        }
        .animation(Motion.standard, value: folderManager.isShowingFolderSidebar)
        .animation(Motion.standard, value: showOutline)
    }
}
