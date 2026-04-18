import Foundation

class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: () -> Void
    private var debounceTimer: Timer?

    /// Explicit retained self reference given to the FSEvents stream.
    /// The stream's `info` pointer is a raw opaque pointer — without this, the Unmanaged
    /// `passUnretained` pattern is a use-after-free hazard if the owner drops us before
    /// calling `stopWatching()`. We retain here and balance in `stopWatching()`.
    /// Consequence: owners MUST call `stopWatching()` explicitly (deinit cannot run while
    /// we hold our own retained reference). FolderManager.closeFolder already does.
    private var retainedInfo: Unmanaged<DirectoryWatcher>?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    deinit {
        // If stopWatching was never called the retainedInfo never released and deinit
        // would never fire. Reaching deinit implies stopWatching already ran, so this is
        // just defensive cleanup for timers.
        debounceTimer?.invalidate()
    }

    func startWatching() {
        guard stream == nil else { return }

        let pathsToWatch = [path] as CFArray
        let retained = Unmanaged.passRetained(self)
        retainedInfo = retained
        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, _, _, _, _ in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                watcher.handleChange()
            }
        }

        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Timing.directoryWatcherLatency,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )

        guard let stream = stream else {
            // Creation failed — release the retained info to avoid a leak.
            retained.release()
            retainedInfo = nil
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stopWatching() {
        debounceTimer?.invalidate()
        debounceTimer = nil

        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream) // synchronous: no further callbacks after this returns
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        retainedInfo?.release()
        retainedInfo = nil
    }

    private func handleChange() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: Timing.directoryWatcherDebounce, repeats: false) { [weak self] _ in
            self?.onChange()
        }
    }
}
