import Foundation

/// Instant in-memory application catalog watched via debounced filesystem events without CPU polling.
public final class AppScanner: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let localizedName: String
        public let alternateNames: [String]
        public let url: URL

        public init(name: String, localizedName: String, alternateNames: [String] = [], url: URL) {
            self.name = name
            self.localizedName = localizedName
            self.alternateNames = alternateNames
            self.url = url
        }
    }

    private static let roots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications",
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
        NSHomeDirectory() + "/Applications",
        NSHomeDirectory() + "/Applications (Parallels)"
    ]

    private static let watchedDirectories = [
        "/Applications",
        NSHomeDirectory() + "/Applications",
        NSHomeDirectory() + "/Applications (Parallels)"
    ]

    private let lock = NSLock()
    private let frecency: FrecencyStore
    private let watcherQueue = DispatchQueue(label: "com.quickspot.appscanner.watch", qos: .utility)
    private var entries: [Entry] = []
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var pendingReload: DispatchWorkItem?

    public init(frecency: FrecencyStore = FrecencyStore()) {
        self.frecency = frecency
        reload()
        startWatching()
    }

    deinit {
        pendingReload?.cancel()
        watchers.forEach { $0.cancel() }
    }

    public func reload() {
        let fm = FileManager.default
        var seenPaths = Set<String>()
        var collected: [Entry] = []

        for root in Self.roots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            scan(dir: rootURL, depth: 0, maxDepth: 2, fm: fm, seen: &seenPaths, into: &collected)
        }
        collected.sort { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }

        lock.lock()
        entries = collected
        lock.unlock()
    }

    public func search(query: String, limit: Int = 10) -> [SearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }

        lock.lock()
        let snapshot = entries
        lock.unlock()

        let home = NSHomeDirectory()
        var hits: [SearchItem] = []
        for entry in snapshot {
            var base = max(
                FuzzyMatcher.score(query: trimmed, candidate: entry.localizedName) ?? 0,
                FuzzyMatcher.score(query: trimmed, candidate: entry.name) ?? 0
            )
            for alias in entry.alternateNames {
                if let aliasScore = FuzzyMatcher.score(query: trimmed, candidate: alias), aliasScore > base {
                    base = aliasScore
                }
            }
            guard base > 0 else { continue }

            let path = entry.url.standardizedFileURL.path
            let boost = frecency.boost(for: path, query: trimmed)
            hits.append(SearchItem(
                id: "app:\(path)",
                title: entry.localizedName,
                subtitle: entry.url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~"),
                category: .application,
                iconPath: path,
                score: base + boost,
                action: .openFile(entry.url),
                previewURL: entry.url,
                matchSource: .name
            ))
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    public func topFrequentApps(limit: Int = 6) -> [SearchItem] {
        guard limit > 0 else { return [] }
        lock.lock()
        let byPath = Dictionary(
            entries.map { ($0.url.standardizedFileURL.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        lock.unlock()

        let home = NSHomeDirectory()
        let candidateIDs = frecency.topIDs(limit: max(limit * 8, 64))
        var results: [SearchItem] = []
        results.reserveCapacity(limit)

        for path in candidateIDs {
            guard let entry = byPath[path] else { continue }
            let folder = entry.url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            results.append(SearchItem(
                id: "app:\(path)",
                title: entry.localizedName,
                subtitle: L10n.format("subtitle.frequent", folder),
                category: .application,
                iconPath: path,
                score: 900 - results.count,
                action: .openFile(entry.url),
                previewURL: entry.url,
                matchSource: .recent
            ))
            if results.count >= limit { break }
        }
        return results
    }

    private func scan(
        dir: URL,
        depth: Int,
        maxDepth: Int,
        fm: FileManager,
        seen: inout Set<String>,
        into result: inout [Entry]
    ) {
        guard depth <= maxDepth,
              let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .localizedNameKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        for item in items {
            let resolved = item.resolvingSymlinksInPath()
            if item.pathExtension.lowercased() == "app" {
                guard seen.insert(resolved.path).inserted else { continue }
                let rawName = item.deletingPathExtension().lastPathComponent
                let localized = stripAppSuffix(
                    (try? item.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? rawName
                )
                let alternates = extractAlternateNames(for: item, rawName: rawName, localizedName: localized)
                result.append(Entry(
                    name: rawName,
                    localizedName: localized,
                    alternateNames: alternates,
                    url: item
                ))
            } else if depth < maxDepth {
                let isDir = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    scan(dir: item, depth: depth + 1, maxDepth: maxDepth, fm: fm, seen: &seen, into: &result)
                }
            }
        }
    }

    private func extractAlternateNames(for appURL: URL, rawName: String, localizedName: String) -> [String] {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return []
        }

        var known = Set<String>([
            FuzzyMatcher.normalize(rawName),
            FuzzyMatcher.normalize(localizedName)
        ])
        var alternates: [String] = []

        for key in ["CFBundleDisplayName", "CFBundleName"] {
            guard let value = plist[key] as? String else { continue }
            let cleaned = stripAppSuffix(value.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !cleaned.isEmpty else { continue }
            let norm = FuzzyMatcher.normalize(cleaned)
            if known.insert(norm).inserted {
                alternates.append(cleaned)
            }
        }
        return alternates
    }

    private func stripAppSuffix(_ name: String) -> String {
        if name.lowercased().hasSuffix(".app") {
            return String(name.dropLast(4))
        }
        return name
    }

    private func startWatching() {
        for path in Self.watchedDirectories {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: watcherQueue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleDebouncedReload()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    private func scheduleDebouncedReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        pendingReload = work
        watcherQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
