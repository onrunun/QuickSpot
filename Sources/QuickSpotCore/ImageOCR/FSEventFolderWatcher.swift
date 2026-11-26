import CoreServices
import Foundation

/// Recursively watches user-selected folders via macOS FSEvents while filtering noisy cache/VCS paths.
final class FSEventFolderWatcher: @unchecked Sendable {
    private static let ignoredFragments = [
        "/.git/", "/node_modules/", "/.build/", "/.next/", "/.Trash/", "/Library/",
        "/DerivedData/", "/Pods/", "/.Spotlight-V100/", "/.fseventsd/",
        "/.cache/", "/__pycache__/", "/.venv/", "/build.noindex/",
        ".xcodeproj/", ".xcassets/"
    ]

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "QuickSpot.FSEvents", qos: .utility)
    private let excludedPaths: [String]
    private let onChange: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?

    init?(
        folders: [String],
        excludedPaths: [String] = [],
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        let valid = folders.filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
        guard !valid.isEmpty else { return nil }
        self.excludedPaths = excludedPaths.compactMap { raw in
            let std = (raw as NSString).standardizingPath
            guard !std.isEmpty else { return nil }
            return std.count > 1 && std.hasSuffix("/") ? String(std.dropLast()) : std
        }
        self.onChange = onChange

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
        let dirFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        let fileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)

        var relevant: [String] = []
        relevant.reserveCapacity(paths.count)

        for (index, rawPath) in paths.enumerated() {
            if Self.ignoredFragments.contains(where: { rawPath.contains($0) }) { continue }
            let stdPath = (rawPath as NSString).standardizingPath
            if excludedPaths.contains(where: { stdPath == $0 || stdPath.hasPrefix($0 + "/") }) { continue }

            let eventFlag = index < flags.count ? flags[index] : 0
            let needsFullScan = (eventFlag & scanAllMask) != 0
            let isDirEvent = (eventFlag & dirFlag) != 0
            let isFileEvent = (eventFlag & fileFlag) != 0

            if !needsFullScan && isFileEvent && !isDirEvent {
                let url = URL(fileURLWithPath: stdPath)
                if url.lastPathComponent.hasPrefix(".") || !VisionTextExtractor.isSupportedDocument(url) {
                    continue
                }
            }
            relevant.append(stdPath)
        }

        if !relevant.isEmpty {
            onChange(relevant)
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
