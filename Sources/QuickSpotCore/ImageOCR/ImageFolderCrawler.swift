import Darwin
import Foundation

/// Live indexing state exposed to the Settings & Indexing window.
public struct IndexProgress: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case scanning
        case indexing(done: Int, total: Int)
        case paused(reason: String)
    }

    public let state: State
    public let indexedCount: Int
    public let withTextCount: Int

    public init(state: State, indexedCount: Int, withTextCount: Int) {
        self.state = state
        self.indexedCount = indexedCount
        self.withTextCount = withTextCount
    }
}

struct DiscoveredImage: Sendable {
    let url: URL
    let mtime: Double
    let size: Int64
}

/// Crawls user-selected folders for supported image and PDF files while skipping caches, packages, and noisy asset folders.
enum ImageFolderCrawler {
    private static let ignoredDirectories: Set<String> = [
        "node_modules", ".git", ".build", ".next", ".turbo", ".expo",
        ".svelte-kit", ".astro", ".pytest_cache", "__pycache__", ".venv",
        "venv", ".Trash", "Library", ".cache", "build.noindex",
        "DerivedData", "Pods", ".xcodeproj", ".xcassets",
        "Arduino", "Unity", "Unreal", "Unreal Projects",
        ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
        "Carthage", "vendor", "dist", "target", ".gradle", ".idea", ".vscode",
        "Steam", "Epic Games", "Parallels", "Virtual Machines.localized"
    ]

    private static let ignoredDirectoryExtensions: Set<String> = [
        "xcodeproj", "xcassets", "xcworkspace", "playground",
        "framework", "bundle", "kext", "app",
        "photoslibrary", "musiclibrary", "tvlibrary", "vmwarevm", "pvm"
    ]

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
        .contentModificationDateKey, .fileSizeKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
    ]

    private static let minImageBytes: Int64 = 4_096
    private static let minPDFBytes: Int64 = 1_024
    private static let maxDepth = 6

    static func crawl(
        folders: [String],
        excludedPaths: [String] = [],
        excludedFolderNames: Set<String> = [],
        throttleDelayProvider: (() -> TimeInterval)? = nil,
        shouldCancel: (() -> Bool)? = nil
    ) -> [DiscoveredImage] {
        let fm = FileManager.default
        let keySet = Set(resourceKeys)
        let normalizedExcluded = normalizePaths(excludedPaths)
        let cancelCheck = shouldCancel ?? { Task.isCancelled }
        var seen = Set<String>()
        var results: [DiscoveredImage] = []
        var inspectedCount = 0

        for folder in folders {
            if cancelCheck() { return [] }
            let rootPath = normalizePath(folder)
            guard !rootPath.isEmpty, !isExcludedPath(rootPath, excludedPaths: normalizedExcluded) else { continue }
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles]
            ) else { continue }

            while let next = enumerator.nextObject() as? URL {
                inspectedCount &+= 1
                if (inspectedCount & 63) == 0 && cancelCheck() { return [] }
                if (inspectedCount & 255) == 0, let delay = throttleDelayProvider?(), delay > 0.0005 {
                    Thread.sleep(forTimeInterval: delay)
                    if cancelCheck() { return [] }
                }

                let values: URLResourceValues
                do {
                    values = try next.resourceValues(forKeys: keySet)
                } catch {
                    continue
                }
                let isDir = values.isDirectory ?? false
                let isPackage = values.isPackage ?? false
                let path = normalizePath(next.path)

                if isDir || isPackage {
                    let shouldSkip = isPackage
                        || isExcludedPath(path, excludedPaths: normalizedExcluded)
                        || isIgnoredDirectory(name: next.lastPathComponent, excludedFolderNames: excludedFolderNames)
                        || enumerator.level >= maxDepth
                    if shouldSkip { enumerator.skipDescendants() }
                    continue
                }

                guard !isExcludedPath(path, excludedPaths: normalizedExcluded) else { continue }
                guard values.isSymbolicLink != true,
                      !isCloudDataless(url: next, values: values),
                      VisionTextExtractor.isSupportedDocument(next) else { continue }

                let size = Int64(values.fileSize ?? 0)
                let minBytes = next.pathExtension.lowercased() == "pdf" ? minPDFBytes : minImageBytes
                guard size >= minBytes, seen.insert(path).inserted else { continue }
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                results.append(DiscoveredImage(url: URL(fileURLWithPath: path), mtime: mtime, size: size))
            }
        }
        results.sort { $0.mtime > $1.mtime }
        return results
    }

    static func inspectSingleFile(
        at path: String,
        allowedRoots: [String],
        excludedPaths: [String],
        excludedFolderNames: Set<String> = []
    ) -> DiscoveredImage? {
        let stdPath = normalizePath(path)
        guard !stdPath.isEmpty else { return nil }

        let normalizedExcluded = normalizePaths(excludedPaths)
        guard !isExcludedPath(stdPath, excludedPaths: normalizedExcluded) else { return nil }

        let normalizedRoots = normalizePaths(allowedRoots)
        guard let matchingRoot = normalizedRoots
            .filter({ root in
                let prefix = root == "/" ? "/" : root + "/"
                return stdPath.hasPrefix(prefix) && stdPath != root
            })
            .max(by: { $0.count < $1.count })
        else { return nil }

        let rootPrefix = matchingRoot == "/" ? "/" : matchingRoot + "/"
        let relative = String(stdPath.dropFirst(rootPrefix.count))
        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.count <= maxDepth else { return nil }
        guard !components.contains(where: { $0.hasPrefix(".") }) else { return nil }

        var cursorURL = URL(fileURLWithPath: matchingRoot, isDirectory: true)
        for dirName in components.dropLast() {
            if isIgnoredDirectory(name: dirName, excludedFolderNames: excludedFolderNames) {
                return nil
            }
            cursorURL.appendPathComponent(dirName, isDirectory: true)
            if isExcludedPath(normalizePath(cursorURL.path), excludedPaths: normalizedExcluded) {
                return nil
            }
            do {
                let dirValues = try cursorURL.resourceValues(forKeys: [.isPackageKey])
                if dirValues.isPackage == true { return nil }
            } catch {
                return nil
            }
        }

        let url = URL(fileURLWithPath: stdPath)
        guard VisionTextExtractor.isSupportedDocument(url) else { return nil }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Set(resourceKeys))
        } catch {
            return nil
        }
        guard values.isDirectory != true,
              values.isPackage != true,
              values.isSymbolicLink != true,
              !isCloudDataless(url: url, values: values) else {
            return nil
        }

        let size = Int64(values.fileSize ?? 0)
        let minBytes = url.pathExtension.lowercased() == "pdf" ? minPDFBytes : minImageBytes
        guard size >= minBytes else { return nil }
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return DiscoveredImage(url: url, mtime: mtime, size: size)
    }

    /// Unified ignore check shared by FSEvents watcher and crawler so cache/VCS/bundle paths (e.g. `.photoslibrary`) never trigger thrashing.
    static func shouldIgnoreEventPath(
        _ rawPath: String,
        watchedRoots: [String] = [],
        excludedPaths: [String] = [],
        excludedFolderNames: Set<String> = []
    ) -> Bool {
        let stdPath = normalizePath(rawPath)
        guard !stdPath.isEmpty else { return true }
        let normalizedExcluded = normalizePaths(excludedPaths)
        if isExcludedPath(stdPath, excludedPaths: normalizedExcluded) {
            return true
        }

        let normalizedRoots = normalizePaths(watchedRoots)
        let relativePath: String
        if let root = normalizedRoots
            .filter({ stdPath == $0 || stdPath.hasPrefix($0 == "/" ? "/" : $0 + "/") })
            .max(by: { $0.count < $1.count }) {
            if stdPath == root { return false }
            let prefix = root == "/" ? "/" : root + "/"
            relativePath = String(stdPath.dropFirst(prefix.count))
        } else {
            relativePath = stdPath
        }

        let components = relativePath.split(separator: "/").map(String.init)
        for component in components {
            if component.hasPrefix(".") || isIgnoredDirectory(name: component, excludedFolderNames: excludedFolderNames) {
                return true
            }
        }
        return false
    }

    /// Returns true if a file is an evicted iCloud / FileProvider dataless placeholder whose read would trigger a cloud download.
    static func isCloudDataless(url: URL, values: URLResourceValues) -> Bool {
        if values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus == .notDownloaded {
            return true
        }
        var st = stat()
        if lstat(url.path, &st) == 0, (st.st_flags & UInt32(SF_DATALESS)) != 0 {
            return true
        }
        return false
    }

    static func canHandleIncrementally(_ paths: [String], maxBatch: Int = 30) -> Bool {
        guard !paths.isEmpty, paths.count <= maxBatch else { return false }
        let fm = FileManager.default
        for path in paths {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir) {
                if isDir.boolValue { return false }
            } else if !VisionTextExtractor.isSupportedDocument(URL(fileURLWithPath: path)) {
                return false
            }
        }
        return true
    }

    private static func isIgnoredDirectory(name: String, excludedFolderNames: Set<String>) -> Bool {
        if ignoredDirectories.contains(name) || excludedFolderNames.contains(name) {
            return true
        }
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && ignoredDirectoryExtensions.contains(ext)
    }

    private static func isExcludedPath(_ path: String, excludedPaths: [String]) -> Bool {
        excludedPaths.contains { excluded in
            path == excluded || path.hasPrefix(excluded + "/")
        }
    }

    private static func normalizePaths(_ paths: [String]) -> [String] {
        paths.map(normalizePath).filter { !$0.isEmpty }
    }

    private static func normalizePath(_ raw: String) -> String {
        let std = (raw as NSString).standardizingPath
        if std.count > 1 && std.hasSuffix("/") {
            return String(std.dropLast())
        }
        return std
    }
}
