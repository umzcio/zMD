import Foundation

/// Watches for external file changes and notifies the delegate
class FileWatcher {
    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var lastModificationDate: Date?

    let url: URL
    weak var delegate: FileWatcherDelegate?

    /// Whether to ignore the next change (used after we reload the file)
    var ignoreNextChange = false

    /// Whether file watching is currently paused
    private var isPaused = false

    init(url: URL) {
        self.url = url
        self.lastModificationDate = getModificationDate()
    }

    deinit {
        stopWatching()
    }

    // MARK: - Public Methods

    func startWatching() {
        guard fileDescriptor == -1 else { return }

        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor != -1 else {
            return
        }

        dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: .main
        )

        dispatchSource?.setEventHandler { [weak self] in
            self?.handleFileChange()
        }

        dispatchSource?.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fileDescriptor != -1 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        dispatchSource?.resume()
    }

    func stopWatching() {
        dispatchSource?.cancel()
        dispatchSource = nil

        if fileDescriptor != -1 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
        // Update modification date to current
        lastModificationDate = getModificationDate()
    }

    // MARK: - Private Methods

    private func handleFileChange() {
        guard !isPaused else { return }

        // Capture event mask before anything else — the source may emit only one event per cycle.
        let events = dispatchSource?.data ?? []
        let inodeChanged = events.contains(.rename) || events.contains(.delete)

        if ignoreNextChange {
            ignoreNextChange = false
            lastModificationDate = getModificationDate()
            if inodeChanged { restartIfFileExists() }
            return
        }

        // Check if the modification date actually changed
        let currentModDate = getModificationDate()
        guard currentModDate != lastModificationDate else {
            if inodeChanged { restartIfFileExists() }
            return
        }

        lastModificationDate = currentModDate

        // Check if file still exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            delegate?.fileWatcher(self, fileWasDeleted: url)
            return
        }

        delegate?.fileWatcher(self, fileDidChange: url)

        // DispatchSourceFileSystemObject is bound to an inode, not a path. Editors that save via
        // atomic-rename (vim, VSCode, TextMate) write to a temp file then rename-over the target;
        // our original fd is now attached to an orphaned inode and would never see subsequent edits.
        // Re-open the watch on the same URL so future writes to the new inode keep firing.
        if inodeChanged { restartIfFileExists() }
    }

    private func restartIfFileExists() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        stopWatching()
        startWatching()
    }

    private func getModificationDate() -> Date? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.modificationDate] as? Date
        } catch {
            return nil
        }
    }
}

// MARK: - Delegate Protocol

protocol FileWatcherDelegate: AnyObject {
    func fileWatcher(_ watcher: FileWatcher, fileDidChange url: URL)
    func fileWatcher(_ watcher: FileWatcher, fileWasDeleted url: URL)
}
