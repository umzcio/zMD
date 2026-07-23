import SwiftUI

nonisolated struct FileTreeItem: Identifiable, Sendable {
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
    private let bookmarkKey = DefaultsKeys.folderBookmark

    // Self-write suppression. DocumentManager calls noteSelfWrite(at:) right after a save so
    // the directory watcher's resulting "something changed" event doesn't cause a full O(N)
    // tree rebuild — the FSEvents API doesn't tell us which path changed, so we use a recency
    // window: any directory change within 800ms of a self-write is assumed to be that
    // self-write echo and skipped (M8). External edits arriving in the same window will be
    // missed for one cycle; the next debounce will catch them.
    private var lastSelfWriteAt: Date = .distantPast
    private static let selfWriteSuppressionWindow: TimeInterval = 0.8

    // Coalesces a single deferred rescan for suppressed events (see refreshFileTreeAsync) so
    // rapid-fire suppressed events don't stack up multiple pending rescans.
    private var deferredRescanTimer: Timer?

    // Monotonic generation token: each performTreeScan(for:) call captures the current value
    // before dispatching, and the background scan's result is only published if that captured
    // generation still matches the latest one issued. Both setFolder and refreshFileTreeAsync
    // dispatch onto the *concurrent* global queue with no other ordering guarantee, so without
    // this guard a slower, older scan finishing after a newer one would win the race and leave
    // the sidebar showing stale contents.
    private var scanGeneration = 0

    func noteSelfWrite(at url: URL) {
        guard let folder = folderURL else { return }
        let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let folderPrefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard filePath == folderPath || filePath.hasPrefix(folderPrefix) else { return }
        lastSelfWriteAt = Date()
    }

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

        // Initial tree scan happens off-main so opening a folder with thousands of files doesn't
        // freeze the UI. We keep `refreshFileTree` callable synchronously for the
        // DirectoryWatcher change callback, which we also dispatch off-main below.
        performTreeScan(for: url)

        // Start watching — rebuild off-main on each event too.
        directoryWatcher = DirectoryWatcher(path: url.path) { [weak self] in
            self?.refreshFileTreeAsync()
        }
        directoryWatcher?.startWatching()
    }

    /// Rebuild file tree on a background queue; publish back to main.
    /// The DirectoryWatcher fires this after its 300ms debounce, so rapid-fire external edits
    /// produce one background rebuild each — still O(N) per event, but at least the main thread
    /// stays responsive.
    private func refreshFileTreeAsync() {
        guard let folderURL = folderURL else { return }
        let elapsed = Date().timeIntervalSince(lastSelfWriteAt)
        if elapsed < Self.selfWriteSuppressionWindow {
            // Suppressed because this is almost certainly an echo of our own save. But if this
            // FS event turns out to be the ONLY one in the suppression window (a genuine external
            // edit landing in the same ~800ms as our save), dropping it silently leaves the
            // sidebar stale with no future event to correct it. Schedule one rescan just past the
            // window to catch that case, coalescing if we're already scheduled.
            deferredRescanTimer?.invalidate()
            let remaining = Self.selfWriteSuppressionWindow - elapsed
            deferredRescanTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.performTreeScan(for: folderURL)
                }
            }
            return
        }
        performTreeScan(for: folderURL)
    }

    /// Single shared entry point for issuing a background tree scan. Both the initial scan in
    /// `setFolder` and the watcher-triggered rescan in `refreshFileTreeAsync` (including its
    /// deferred-rescan path) route through here so the generation-token guard below is
    /// meaningful for every scan in flight, not just some of them.
    private func performTreeScan(for folderURL: URL) {
        scanGeneration += 1
        let generation = scanGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self, folderURL] in
            let tree = Self.buildTree(at: folderURL, relativeTo: folderURL)
            DispatchQueue.main.async {
                // Both setFolder and refreshFileTreeAsync dispatch onto the concurrent global
                // queue, so an older scan can finish after a newer one. Only publish if no
                // newer scan has been issued since this one started.
                guard let self = self, generation == self.scanGeneration else { return }
                self.fileTree = tree
            }
        }
    }

    func closeFolder() {
        directoryWatcher?.stopWatching()
        directoryWatcher = nil

        // Cancel any pending deferred rescan (Step 1 fix) so a scan of the just-closed folder
        // can't fire after the fact and repopulate fileTree once the folder is no longer open.
        deferredRescanTimer?.invalidate()
        deferredRescanTimer = nil

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
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            // Folder was deleted or the volume is unavailable. Drop the bookmark so we don't
            // silently retry on every launch forever.
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return
        }

        if isStale {
            // Re-save bookmark
            if let newBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(newBookmark, forKey: bookmarkKey)
            }
        }

        setFolder(url)
    }

    // MARK: - File Tree

    private nonisolated static func buildTree(at url: URL, relativeTo root: URL) -> [FileTreeItem] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var directories: [FileTreeItem] = []
        var files: [FileTreeItem] = []

        for item in contents {
            let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDir = resourceValues?.isDirectory ?? false
            let isSymlink = resourceValues?.isSymbolicLink ?? false
            let relativePath = item.path.replacingOccurrences(of: root.path, with: "")

            if isDir {
                // Skip symlinked directories — buildTree resolves .isDirectoryKey through
                // symlinks with no cycle detection, so a directory symlink pointing back at
                // an ancestor (or itself) recurses until the stack overflows and the app
                // crashes. Since restoreFolder() re-opens the last folder on every launch,
                // an unguarded cycle here is a crash-on-launch loop a user can't self-fix.
                guard !isSymlink else { continue }
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

    private nonisolated static func containsMarkdownFiles(_ items: [FileTreeItem]) -> Bool {
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
