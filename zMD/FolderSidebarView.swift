import SwiftUI

struct FolderSidebarView: View {
    @EnvironmentObject var documentManager: DocumentManager
    @EnvironmentObject var folderManager: FolderManager
    @State private var expandedDirectories: Set<String> = []
    @State private var closeButtonHovered = false

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
                Button(action: {
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        folderManager.closeFolder()
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(closeButtonHovered ? .primary : .secondary)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(closeButtonHovered ? Color(NSColor.controlBackgroundColor) : Color.clear)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        closeButtonHovered = hovering
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

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
        .background(.ultraThinMaterial)
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
    @State private var isHovered = false

    private var isExpanded: Bool {
        expandedDirectories.contains(item.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                if item.isDirectory {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedDirectories.remove(item.id)
                        } else {
                            expandedDirectories.insert(item.id)
                        }
                    }
                } else {
                    onFileSelected(item.url)
                }
            }) {
                HStack(spacing: 4) {
                    if item.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                            .frame(width: 12)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
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
                        .foregroundColor(isActive ? .primary : (isHovered ? .primary.opacity(0.8) : .secondary))

                    Spacer()
                }
                .padding(.leading, CGFloat(8 + depth * 16))
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isActive ? Color.accentColor.opacity(0.12) : (isHovered ? Color.accentColor.opacity(0.06) : Color.clear))
                )
            }
            .buttonStyle(PlainButtonStyle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var isActive: Bool {
        guard let activeURL = activeURL else { return false }
        return item.url == activeURL
    }
}
