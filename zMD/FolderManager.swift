import SwiftUI

struct FileTreeItem: Identifiable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileTreeItem]?
}

class FolderManager: ObservableObject {
    static let shared = FolderManager()

    @Published var folderURL: URL?
    @Published var fileTree: [FileTreeItem] = []
    @Published var isShowingFolderSidebar: Bool = false

    private var directoryWatcher: DirectoryWatcher?
    private var securityScopedAccess = false
    private let bookmarkKey = "FolderBookmarkData"

    private init() {}

    // MARK: - Open/Close Folder

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to open"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setFolder(url)
        }
    }

    func setFolder(_ url: URL) {
        // Stop watching previous folder
        closeFolder()

        // Save bookmark for restoration
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        }

        // Start security-scoped access
        securityScopedAccess = url.startAccessingSecurityScopedResource()
        folderURL = url
        isShowingFolderSidebar = true

        refreshFileTree()

        // Start watching
        directoryWatcher = DirectoryWatcher(path: url.path) { [weak self] in
            self?.refreshFileTree()
        }
        directoryWatcher?.startWatching()
    }

    func closeFolder() {
        directoryWatcher?.stopWatching()
        directoryWatcher = nil

        if securityScopedAccess, let url = folderURL {
            url.stopAccessingSecurityScopedResource()
            securityScopedAccess = false
        }

        folderURL = nil
        fileTree = []
        isShowingFolderSidebar = false
    }

    func restoreFolder() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else { return }

        if isStale {
            // Re-save bookmark
            if let newBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(newBookmark, forKey: bookmarkKey)
            }
        }

        setFolder(url)
    }

    // MARK: - File Tree

    func refreshFileTree() {
        guard let folderURL = folderURL else { return }
        fileTree = buildTree(at: folderURL, relativeTo: folderURL)
    }

    private func buildTree(at url: URL, relativeTo root: URL) -> [FileTreeItem] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var directories: [FileTreeItem] = []
        var files: [FileTreeItem] = []

        for item in contents {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let relativePath = item.path.replacingOccurrences(of: root.path, with: "")

            if isDir {
                let children = buildTree(at: item, relativeTo: root)
                // Only include directories that contain markdown files (directly or nested)
                if containsMarkdownFiles(children) {
                    directories.append(FileTreeItem(
                        id: relativePath,
                        url: item,
                        name: item.lastPathComponent,
                        isDirectory: true,
                        children: children
                    ))
                }
            } else {
                let ext = item.pathExtension.lowercased()
                if ext == "md" || ext == "markdown" {
                    files.append(FileTreeItem(
                        id: relativePath,
                        url: item,
                        name: item.lastPathComponent,
                        isDirectory: false,
                        children: nil
                    ))
                }
            }
        }

        // Sort: directories first (alpha), then files (alpha)
        directories.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        files.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return directories + files
    }

    private func containsMarkdownFiles(_ items: [FileTreeItem]) -> Bool {
        for item in items {
            if !item.isDirectory { return true }
            if let children = item.children, containsMarkdownFiles(children) { return true }
        }
        return false
    }

    // MARK: - All Markdown Files (flat list for Quick Switcher)

    var allMarkdownFiles: [URL] {
        var result: [URL] = []
        collectFiles(from: fileTree, into: &result)
        return result
    }

    private func collectFiles(from items: [FileTreeItem], into result: inout [URL]) {
        for item in items {
            if item.isDirectory, let children = item.children {
                collectFiles(from: children, into: &result)
            } else {
                result.append(item.url)
            }
        }
    }
}
