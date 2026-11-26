import CoreServices
import Foundation

/// Coalesced filesystem change notification emitted by `FSEventFolderWatcher`.
struct FolderChangeBatch: Sendable {
    let paths: [String]
    let requiresFullScan: Bool
}

/// Recursively watches user-selected folders via macOS FSEvents while filtering noisy cache/VCS/package paths.
final class FSEventFolderWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "QuickSpot.FSEvents", qos: .utility)
    private let watchedRoots: [String]
    private let excludedPaths: [String]
    private let onBatch: @Sendable (FolderChangeBatch) -> Void
    private var stream: FSEventStreamRef?

    convenience init?(
        folders: [String],
        excludedPaths: [String] = [],
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        self.init(folders: folders, excludedPaths: excludedPaths) { batch in
            onChange(batch.paths)
        }
    }

    init?(
        folders: [String],
        excludedPaths: [String] = [],
        onBatch: @escaping @Sendable (FolderChangeBatch) -> Void
    ) {
        let valid = folders
            .map { raw -> String in
                let std = (raw as NSString).standardizingPath
                return std.count > 1 && std.hasSuffix("/") ? String(std.dropLast()) : std
            }
            .filter {
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
            }
        guard !valid.isEmpty else { return nil }
        self.watchedRoots = valid
        self.excludedPaths = excludedPaths.compactMap { raw in
            let std = (raw as NSString).standardizingPath
            guard !std.isEmpty else { return nil }
            return std.count > 1 && std.hasSuffix("/") ? String(std.dropLast()) : std
        }
        self.onBatch = onBatch

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let created = FSEventStreamCreate(
            nil, fsEventStreamCallback, &context, valid as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5, flags
        ) else { return nil }

        self.stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    deinit {
        stop()
    }

    func stop() {
        lock.lock()
        guard let active = stream else { lock.unlock(); return }
        stream = nil
        lock.unlock()
        FSEventStreamStop(active)
        FSEventStreamSetDispatchQueue(active, nil)
        FSEventStreamInvalidate(active)
        FSEventStreamRelease(active)
    }

    fileprivate func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        let scanAllMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount
        )
        let structuralDirMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed
        )
        let dirFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        let fileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)

        var relevant: [String] = []
        relevant.reserveCapacity(paths.count)
        var requiresFullScan = false

        for (index, rawPath) in paths.enumerated() {
            let stdPath = (rawPath as NSString).standardizingPath
            if ImageFolderCrawler.shouldIgnoreEventPath(
                stdPath,
                watchedRoots: watchedRoots,
                excludedPaths: excludedPaths
            ) {
                continue
            }

            let eventFlag = index < flags.count ? flags[index] : 0
            let needsFullScan = (eventFlag & scanAllMask) != 0
            let isDirEvent = (eventFlag & dirFlag) != 0
            let isFileEvent = (eventFlag & fileFlag) != 0

            if needsFullScan {
                requiresFullScan = true
                relevant.append(stdPath)
                continue
            }

            if isDirEvent && !isFileEvent {
                // Ignore non-structural directory metadata touches (e.g. Finder/.DS_Store/xattr mtime updates).
                if (eventFlag & structuralDirMask) != 0 {
                    requiresFullScan = true
                    relevant.append(stdPath)
                }
                continue
            }

            if isFileEvent {
                let url = URL(fileURLWithPath: stdPath)
                if url.lastPathComponent.hasPrefix(".") || !VisionTextExtractor.isSupportedDocument(url) {
                    continue
                }
                relevant.append(stdPath)
                continue
            }

            // Fallback when neither file nor dir flag is set: inspect extension or escalate.
            let url = URL(fileURLWithPath: stdPath)
            if VisionTextExtractor.isSupportedDocument(url) {
                relevant.append(stdPath)
            } else if (eventFlag & structuralDirMask) != 0 {
                requiresFullScan = true
                relevant.append(stdPath)
            }
        }

        if !relevant.isEmpty || requiresFullScan {
            onBatch(FolderChangeBatch(paths: relevant, requiresFullScan: requiresFullScan))
        }
    }
}

private func fsEventStreamCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else { return }
    let watcher = Unmanaged<FSEventFolderWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
    let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let paths = (cfArray as NSArray).compactMap { $0 as? String }
    let count = min(numEvents, paths.count)
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
    watcher.handleEvents(paths: Array(paths.prefix(count)), flags: flags)
}
