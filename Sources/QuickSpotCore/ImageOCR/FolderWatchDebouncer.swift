import Foundation

/// Encapsulates a single `FSEventFolderWatcher` plus debounced batch coalescing for `IndexingCoordinator` and standalone indexers.
final class FolderWatchDebouncer: @unchecked Sendable {
    private let debounceSeconds: TimeInterval
    private let lock = NSLock()
    private var watcher: FSEventFolderWatcher?
    private var debounceWork: DispatchWorkItem?
    private var pendingPaths: Set<String> = []
    private var pendingRequiresFullScan = false
    private let onFlush: @Sendable (FolderChangeBatch) -> Void

    init(
        debounceSeconds: TimeInterval = 2.0,
        onFlush: @escaping @Sendable (FolderChangeBatch) -> Void
    ) {
        self.debounceSeconds = debounceSeconds
        self.onFlush = onFlush
    }

    deinit {
        stop()
    }

    func start(folders: [String], excludedPaths: [String]) {
        stop()
        let created = FSEventFolderWatcher(folders: folders, excludedPaths: excludedPaths) { [weak self] batch in
            self?.enqueue(batch)
        }
        lock.withLock { watcher = created }
    }

    func stop() {
        let current: FSEventFolderWatcher? = lock.withLock {
            let active = watcher
            watcher = nil
            debounceWork?.cancel()
            debounceWork = nil
            pendingPaths.removeAll()
            pendingRequiresFullScan = false
            return active
        }
        current?.stop()
    }

    private func enqueue(_ batch: FolderChangeBatch) {
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        lock.withLock {
            pendingPaths.formUnion(batch.paths)
            pendingRequiresFullScan = pendingRequiresFullScan || batch.requiresFullScan
            debounceWork?.cancel()
            debounceWork = work
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + debounceSeconds,
            execute: work
        )
    }

    private func flush() {
        let batch: FolderChangeBatch? = lock.withLock {
            let paths = Array(pendingPaths)
            let full = pendingRequiresFullScan
            pendingPaths.removeAll()
            pendingRequiresFullScan = false
            debounceWork = nil
            guard !paths.isEmpty || full else { return nil }
            return FolderChangeBatch(paths: paths, requiresFullScan: full)
        }
        if let batch {
            onFlush(batch)
        }
    }
}
