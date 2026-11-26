import Foundation
import UniformTypeIdentifiers

/// Thread-safe in-memory shallow cache of recent files and folders for 0ms instant search and empty-state suggestions.
public final class RecentFilesProvider: @unchecked Sendable {
    private struct CachedEntry: Sendable {
        let url: URL
        let standardizedPath: String
        let fileName: String
        let localizedName: String
        let parentSubtitle: String
        let isFolder: Bool
        let modifiedAt: Date
        let isImage: Bool
        let isPDF: Bool
        let isShowcaseRoot: Bool
    }

    private struct ScanRoot {
        let relativePath: String
        let maxDepth: Int
        let isShowcaseRoot: Bool
    }

    private static let scanRoots: [ScanRoot] = [
        ScanRoot(relativePath: "Desktop", maxDepth: 2, isShowcaseRoot: true),
        ScanRoot(relativePath: "Downloads", maxDepth: 2, isShowcaseRoot: true),
        ScanRoot(relativePath: "Documents", maxDepth: 2, isShowcaseRoot: true),
        ScanRoot(relativePath: "Library/Mobile Documents/com~apple~CloudDocs", maxDepth: 2, isShowcaseRoot: true),
        ScanRoot(relativePath: "Projects", maxDepth: 2, isShowcaseRoot: false)
    ]

    private static let maxCachedEntries = 600
    private static let maxSubdirectoriesPerRoot = 120
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "tif", "tiff", "bmp", "gif", "svg"
    ]

    private let lock = NSLock()
    private let frecency: FrecencyStore
    private let homeDirectory: String
    private var entries: [CachedEntry] = []
    private var isRefreshing = false
    private var refreshGeneration: UInt64 = 0
    private var appliedGeneration: UInt64 = 0

    public init(frecency: FrecencyStore = FrecencyStore(), homeDirectory: String = NSHomeDirectory()) {
        self.frecency = frecency
        self.homeDirectory = homeDirectory
        refreshAsync()
    }

    /// Triggers a coalesced asynchronous shallow refresh on a utility queue.
    public func refreshAsync() {
        lock.lock()
        guard !isRefreshing else {
            lock.unlock()
            return
        }
        isRefreshing = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.refresh()
            self.lock.lock()
            self.isRefreshing = false
            self.lock.unlock()
        }
    }

    /// Synchronously performs a fast shallow scan of key user folders, keeping the 600 most recent entries.
    public func refresh() {
        lock.lock()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        lock.unlock()

        let fm = FileManager.default
        let home = (homeDirectory.count > 1 && homeDirectory.hasSuffix("/"))
            ? String(homeDirectory.dropLast())
            : homeDirectory
        var seenPaths = Set<String>()
        var collected: [CachedEntry] = []
        collected.reserveCapacity(256)

        for root in Self.scanRoots {
            let rootURL = URL(fileURLWithPath: home + "/" + root.relativePath, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            var visitedDirs = 0
            scanDirectory(
                rootURL, depth: 1, maxDepth: root.maxDepth, isShowcaseRoot: root.isShowcaseRoot,
                home: home, fm: fm, visitedDirs: &visitedDirs, seenPaths: &seenPaths, into: &collected
            )
        }

        collected.sort { $0.modifiedAt > $1.modifiedAt }
        let trimmed = Array(collected.prefix(Self.maxCachedEntries))

        lock.lock()
        if generation >= appliedGeneration {
            entries = trimmed
            appliedGeneration = generation
        }
        lock.unlock()
    }

    /// Returns empty-state "Son Dosyalar" items combining top frecency file IDs and newest showcase files.
    public func recentItems(limit: Int = 6) -> [SearchItem] {
        guard limit > 0 else { return [] }
        let fm = FileManager.default
        var results: [SearchItem] = []
        var seenPaths = Set<String>()

        for rawPath in frecency.topFileIDs(limit: max(limit, 8)) {
            guard results.count < limit else { break }
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            let path = url.path
            guard !SpotlightQueryBuilder.isExcludedPath(path, homeDirectory: homeDirectory),
                  seenPaths.insert(path).inserted,
                  fm.fileExists(atPath: path) else { continue }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            let parent = SpotlightQueryBuilder.formatParentSubtitle(for: url, homeDirectory: homeDirectory)
            results.append(SearchItem(
                id: "file:\(path)",
                title: url.lastPathComponent,
                subtitle: L10n.format("subtitle.recent", parent),
                category: isFolder ? .folder : .file,
                iconPath: path,
                score: 850 - results.count * 5,
                action: .openFile(url),
                previewURL: url,
                matchSource: .recent
            ))
        }

        guard results.count < limit else { return results }
        lock.lock()
        let snapshot = entries
        lock.unlock()

        for entry in snapshot where entry.isShowcaseRoot && !entry.isFolder {
            guard results.count < limit else { break }
            guard seenPaths.insert(entry.standardizedPath).inserted else { continue }
            results.append(SearchItem(
                id: "file:\(entry.standardizedPath)",
                title: entry.fileName,
                subtitle: entry.parentSubtitle,
                category: .file,
                iconPath: entry.standardizedPath,
                score: 780 - results.count * 5,
                action: .openFile(entry.url),
                previewURL: entry.url,
                matchSource: .recent
            ))
        }
        return results
    }

    /// Zero-latency in-memory search over cached entries using the same calibrated scoring as `SpotlightFileSearch`.
    public func searchInstant(query: String, filter: SearchKindFilter? = nil, limit: Int = 10) -> [SearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0, filter != .appsOnly, filter != .contentOnly, filter != .clipboard else { return [] }

        lock.lock()
        let snapshot = entries
        lock.unlock()

        let now = Date()
        var scored: [(item: SearchItem, modifiedAt: Date)] = []

        for entry in snapshot {
            guard matchesFilter(entry, filter: filter) else { continue }
            let fsScore = FuzzyMatcher.scoreFilename(query: trimmed, fileName: entry.fileName)
            let locScore = (entry.localizedName != entry.fileName)
                ? FuzzyMatcher.scoreFilename(query: trimmed, fileName: entry.localizedName)
                : nil
            guard max(fsScore ?? 0, locScore ?? 0) > 0 else { continue }

            let totalScore = SpotlightQueryBuilder.scoreFilenameMatch(
                query: trimmed, fileName: entry.fileName, displayName: entry.localizedName,
                standardizedPath: entry.standardizedPath, referenceDate: entry.modifiedAt,
                frecencyBoost: frecency.boost(for: entry.standardizedPath, query: trimmed),
                homeDirectory: homeDirectory, now: now
            )
            scored.append((SearchItem(
                id: "file:\(entry.standardizedPath)",
                title: entry.fileName,
                subtitle: entry.parentSubtitle,
                category: entry.isFolder ? .folder : .file,
                iconPath: entry.standardizedPath,
                score: totalScore,
                action: .openFile(entry.url),
                previewURL: entry.url,
                matchSource: .name
            ), entry.modifiedAt))
        }

        scored.sort { lhs, rhs in
            if lhs.item.score != rhs.item.score { return lhs.item.score > rhs.item.score }
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title) == .orderedAscending
        }
        return scored.prefix(limit).map(\.item)
    }

    private func matchesFilter(_ entry: CachedEntry, filter: SearchKindFilter?) -> Bool {
        switch filter {
        case nil: return true
        case .imagesOnly: return entry.isImage
        case .pdfOnly: return entry.isPDF
        case .foldersOnly: return entry.isFolder
        case .filesOnly: return !entry.isFolder
        case .contentOnly, .appsOnly, .clipboard: return false
        }
    }

    private func scanDirectory(
        _ directory: URL, depth: Int, maxDepth: Int, isShowcaseRoot: Bool,
        home: String, fm: FileManager, visitedDirs: inout Int,
        seenPaths: inout Set<String>, into result: inout [CachedEntry]
    ) {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .localizedNameKey, .contentTypeKey
        ]
        guard let children = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }

        for child in children {
            let standardizedURL = child.standardizedFileURL
            let path = standardizedURL.path
            guard !SpotlightQueryBuilder.isExcludedPath(path, homeDirectory: home),
                  seenPaths.insert(path).inserted else { continue }

            let values = try? child.resourceValues(forKeys: Set(keys))
            let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            let fileName = standardizedURL.lastPathComponent
            let ext = standardizedURL.pathExtension.lowercased()
            let contentType = values?.contentType

            result.append(CachedEntry(
                url: standardizedURL,
                standardizedPath: path,
                fileName: fileName,
                localizedName: values?.localizedName ?? fileName,
                parentSubtitle: SpotlightQueryBuilder.formatParentSubtitle(for: standardizedURL, homeDirectory: home),
                isFolder: isFolder,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                isImage: !isFolder && (Self.imageExtensions.contains(ext) || contentType?.conforms(to: .image) == true),
                isPDF: !isFolder && (ext == "pdf" || contentType?.conforms(to: .pdf) == true),
                isShowcaseRoot: isShowcaseRoot
            ))

            if isFolder, !(values?.isSymbolicLink ?? false), depth < maxDepth, visitedDirs < Self.maxSubdirectoriesPerRoot {
                visitedDirs += 1
                scanDirectory(
                    standardizedURL, depth: depth + 1, maxDepth: maxDepth, isShowcaseRoot: isShowcaseRoot,
                    home: home, fm: fm, visitedDirs: &visitedDirs, seenPaths: &seenPaths, into: &result
                )
            }
        }
    }
}
