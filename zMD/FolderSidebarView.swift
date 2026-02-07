import SwiftUI

struct FolderSidebarView: View {
    @EnvironmentObject var documentManager: DocumentManager
    @EnvironmentObject var folderManager: FolderManager
    @State private var expandedDirectories: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                Text(folderManager.folderURL?.lastPathComponent ?? "Folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(action: { folderManager.closeFolder() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

            // File tree
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(folderManager.fileTree) { item in
                        FileTreeItemView(
                            item: item,
                            depth: 0,
                            expandedDirectories: $expandedDirectories,
                            onFileSelected: { url in
                                documentManager.loadDocument(from: url)
                            },
                            activeURL: activeDocumentURL
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 220)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    }

    private var activeDocumentURL: URL? {
        guard let selectedId = documentManager.selectedDocumentId else { return nil }
        return documentManager.openDocuments.first(where: { $0.id == selectedId })?.url
    }
}

struct FileTreeItemView: View {
    let item: FileTreeItem
    let depth: Int
    @Binding var expandedDirectories: Set<String>
    let onFileSelected: (URL) -> Void
    let activeURL: URL?

    private var isExpanded: Bool {
        expandedDirectories.contains(item.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                if item.isDirectory {
                    if isExpanded {
                        expandedDirectories.remove(item.id)
                    } else {
                        expandedDirectories.insert(item.id)
                    }
                } else {
                    onFileSelected(item.url)
                }
            }) {
                HStack(spacing: 4) {
                    if item.isDirectory {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                            .frame(width: 12)
                    } else {
                        Spacer()
                            .frame(width: 12)
                    }

                    Image(systemName: item.isDirectory ? (isExpanded ? "folder.fill" : "folder") : "doc.text")
                        .font(.system(size: 12))
                        .foregroundColor(item.isDirectory ? .accentColor : .secondary)

                    Text(item.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundColor(isActive ? .primary : .secondary)

                    Spacer()
                }
                .padding(.leading, CGFloat(8 + depth * 16))
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                .cornerRadius(4)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.horizontal, 4)

            // Show children if expanded
            if item.isDirectory && isExpanded, let children = item.children {
                ForEach(children) { child in
                    FileTreeItemView(
                        item: child,
                        depth: depth + 1,
                        expandedDirectories: $expandedDirectories,
                        onFileSelected: onFileSelected,
                        activeURL: activeURL
                    )
                }
            }
        }
    }

    private var isActive: Bool {
        guard let activeURL = activeURL else { return false }
        return item.url == activeURL
    }
}
