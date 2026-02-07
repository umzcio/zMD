import SwiftUI

struct TabBar: View {
    @EnvironmentObject var documentManager: DocumentManager
    @Binding var showOutline: Bool

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    ForEach(documentManager.openDocuments) { document in
                        TabItem(
                            document: document,
                            isSelected: documentManager.selectedDocumentId == document.id
                        )
                    }
                }
            }

            Spacer()

            // Add new tab button
            Button(action: {
                documentManager.openFile()
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.horizontal, 4)
            .help("Open File")

            // Outline toggle button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showOutline.toggle()
                }
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
        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
    }
}

struct TabItem: View {
    @EnvironmentObject var documentManager: DocumentManager
    let document: MarkdownDocument
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(document.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundColor(isSelected ? .primary : .secondary)

            Button(action: {
                documentManager.closeDocument(document)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .help(document.url.path)
        .onTapGesture {
            documentManager.selectedDocumentId = document.id
        }
        .contextMenu {
            Button("Refresh") {
                documentManager.reloadDocument(document)
            }

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
