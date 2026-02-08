import SwiftUI

struct TabBar: View {
    @EnvironmentObject var documentManager: DocumentManager
    @Binding var showOutline: Bool
    @State private var addButtonHovered = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    ForEach(documentManager.openDocuments) { document in
                        TabItem(
                            document: document,
                            isSelected: documentManager.selectedDocumentId == document.id
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.8)),
                            removal: .opacity.combined(with: .scale(scale: 0.8))
                        ))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: documentManager.openDocuments.map(\.id))
            }

            Spacer()

            // Add new tab button
            Button(action: {
                documentManager.openFile()
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(addButtonHovered ? .primary : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(addButtonHovered ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                    )
                    .scaleEffect(addButtonHovered ? 1.1 : 1.0)
            }
            .buttonStyle(PlainButtonStyle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    addButtonHovered = hovering
                }
            }
            .padding(.horizontal, 4)
            .help("Open File")

            // View mode picker
            Picker("", selection: $documentManager.viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.icon)
                        .help(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 100)
            .padding(.horizontal, 4)

            // Outline toggle button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showOutline.toggle()
                }
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14))
                    .foregroundColor(showOutline ? .accentColor : .secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Toggle Outline")
            .padding(.horizontal, 8)
        }
        .frame(height: 32)
        .background(.ultraThinMaterial)
    }
}

struct TabItem: View {
    @EnvironmentObject var documentManager: DocumentManager
    let document: MarkdownDocument
    let isSelected: Bool
    @State private var isDragTarget = false
    @State private var isHovered = false
    @State private var dirtyPulse = false

    var body: some View {
        HStack(spacing: 4) {
            if document.isDirty {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .scaleEffect(dirtyPulse ? 1.5 : 1.0)
                    .opacity(dirtyPulse ? 0.6 : 1.0)
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.4)) {
                            dirtyPulse = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            withAnimation(.easeIn(duration: 0.2)) {
                                dirtyPulse = false
                            }
                        }
                    }
            }

            Text(document.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundColor(isSelected ? .primary : (isHovered ? .primary.opacity(0.8) : .secondary))

            Button(action: {
                if document.isDirty {
                    let shouldSave = AlertManager.shared.showConfirmation(
                        title: "Save Changes?",
                        message: "Do you want to save changes to \"\(document.name)\" before closing?",
                        confirmButton: "Save",
                        cancelButton: "Don't Save"
                    )
                    if shouldSave {
                        documentManager.saveDocument(id: document.id)
                    }
                }
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                withAnimation(.easeInOut(duration: 0.2)) {
                    documentManager.closeDocument(document)
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .frame(width: 14, height: 14)
            .opacity(isHovered || isSelected ? 1.0 : 0.0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isDragTarget ? Color.accentColor.opacity(0.25) : (isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.accentColor.opacity(0.08) : Color.clear)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isDragTarget ? Color.accentColor.opacity(0.6) : (isSelected ? Color.accentColor.opacity(0.3) : Color.clear), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .help(document.url.path)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            documentManager.selectedDocumentId = document.id
        }
        .onDrag {
            documentManager.draggingDocumentId = document.id
            return NSItemProvider(object: document.id.uuidString as NSString)
        }
        .onDrop(of: [.text], isTargeted: $isDragTarget) { _ in
            guard let sourceId = documentManager.draggingDocumentId,
                  let targetIndex = documentManager.openDocuments.firstIndex(where: { $0.id == document.id }) else { return false }
            withAnimation(.easeInOut(duration: 0.2)) {
                documentManager.moveDocument(withId: sourceId, toIndex: targetIndex)
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            documentManager.draggingDocumentId = nil
            return true
        }
        .contextMenu {
            Button("Refresh") {
                documentManager.reloadDocument(document)
            }

            Divider()

            Button("Open in Split View") {
                documentManager.openInSplitView(documentId: document.id)
            }
            .disabled(document.id == documentManager.selectedDocumentId || documentManager.openDocuments.count < 2)

            Divider()

            Button("Close Tab") {
                documentManager.closeDocument(document)
            }

            Button("Close Other Tabs") {
                documentManager.closeOtherDocuments(except: document)
            }

            Divider()

            Button("Reveal in Finder") {
                documentManager.revealInFinder(document: document)
            }
        }
    }
}

#Preview {
    TabBar(showOutline: .constant(false))
        .environmentObject({
            let manager = DocumentManager()
            manager.openDocuments = [
                MarkdownDocument(url: URL(fileURLWithPath: "/test1.md"), content: ""),
                MarkdownDocument(url: URL(fileURLWithPath: "/test2.md"), content: "")
            ]
            manager.selectedDocumentId = manager.openDocuments.first?.id
            return manager
        }())
}
