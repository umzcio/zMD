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

    init(url: URL) {
        self.url = url
        self.lastModificationDate = getModificationDate()
    }

    deinit {
        MainActor.assumeIsolated {
            stopWatching()
        }
    }

    // MARK: - Public Methods

    func startWatching() {
        guard fileDescriptor == -1 else { return }

        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor != -1 else {
            return
        }

        let watchedFileDescriptor = fileDescriptor
        dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedFileDescriptor,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: .main
        )

        dispatchSource?.setEventHandler { [weak self] in
            self?.handleFileChange()
        }

        dispatchSource?.setCancelHandler {
            close(watchedFileDescriptor)
        }

        dispatchSource?.resume()
    }

    func stopWatching() {
        dispatchSource?.cancel()
        dispatchSource = nil
        fileDescriptor = -1
    }

    // MARK: - Private Methods

    private func handleFileChange() {
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
        // L10: skip the upfront fileExists check — it's TOCTOU racy. The file could be removed
        // in the gap between exists-check and `open()`, leaving the watcher silently dead with
        // no error path. startWatching() already handles the missing-file case (open returns -1
        // and the function bails); just call it directly so any other error gets bubbled.
        stopWatching()
        startWatching()
    }

    /// L4: True if the file's modification date now differs from the one this watcher last
    /// recorded — i.e. an external write happened that the watcher has not yet delivered or
    /// reconciled. Used by the auto-save debounce to avoid overwriting an external edit whose
    /// change event is still queued behind the timer on the main queue.
    func hasPendingExternalChange() -> Bool {
        guard let last = lastModificationDate else { return false }
        return getModificationDate() != last
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
