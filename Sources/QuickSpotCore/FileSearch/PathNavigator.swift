import Foundation

/// Zero-latency filesystem navigator for `~`, `~/...`, and `/...` launcher queries with Tab path completion.
public enum PathNavigator {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .contentModificationDateKey
    ]

    /// Lists or fuzzy-filters filesystem entries for a path query (`~`, `~/...`, `/...`).
    public static func search(rawPath: String, limit: Int = 24) -> [SearchItem] {
        search(rawPath: rawPath, limit: limit, homeDirectory: NSHomeDirectory())
    }

    /// Returns a tilde-shortened path with trailing `/` for directories (Tab drill-down) or without `/` for files.
    public static func autocompletePath(for item: SearchItem) -> String? {
        autocompletePath(for: item, homeDirectory: NSHomeDirectory())
    }

    static func search(rawPath: String, limit: Int, homeDirectory: String) -> [SearchItem] {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }

        let home = normalizedDirectory(homeDirectory)
        guard let expanded = expandPath(trimmed, home: home) else { return [] }
        let fm = FileManager.default

        if trimmed == "~" {
            let homeURL = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
            var results: [SearchItem] = []
            if let exact = makeExactMatchItem(for: homeURL, home: home, fm: fm) { results.append(exact) }
            let remaining = max(0, limit - results.count)
            if remaining > 0 {
                results.append(contentsOf: listDirectoryEntries(at: homeURL, includeHidden: false, home: home, fm: fm, limit: remaining))
            }
            return results
        }

        if trimmed.hasSuffix("/") {
            let dirURL = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            return listDirectoryEntries(at: dirURL, includeHidden: false, home: home, fm: fm, limit: limit)
        }

        guard let lastSlash = expanded.lastIndex(of: "/") else { return [] }
        let parentPath = (lastSlash == expanded.startIndex) ? "/" : String(expanded[..<lastSlash])
        let filterTerm = String(expanded[expanded.index(after: lastSlash)...])
        let parentURL = URL(fileURLWithPath: parentPath, isDirectory: true).standardizedFileURL

        var results: [SearchItem] = []
        var seenPaths = Set<String>()

        if filterTerm != ".", filterTerm != ".." {
            let exactURL = URL(fileURLWithPath: expanded).standardizedFileURL
            if let exactItem = makeExactMatchItem(for: exactURL, home: home, fm: fm) {
                results.append(exactItem)
                seenPaths.insert(exactURL.path)
            }
        }

        let matches = filterDirectoryEntries(
            at: parentURL, filterTerm: filterTerm, includeHidden: filterTerm.hasPrefix("."),
            excluding: seenPaths, home: home, fm: fm
        )
        results.append(contentsOf: matches)
        return Array(results.prefix(limit))
    }

    static func autocompletePath(for item: SearchItem, homeDirectory: String) -> String? {
        guard let url = item.previewURL, url.isFileURL else { return nil }
        let standardized = url.standardizedFileURL.path
        let isDir = isDirectoryItem(url: url, category: item.category)
        let shortened = tildeShortened(standardized, home: normalizedDirectory(homeDirectory))
        return isDir ? (shortened.hasSuffix("/") ? shortened : shortened + "/") : shortened
    }

    private static func makeExactMatchItem(for url: URL, home: String, fm: FileManager) -> SearchItem? {
        var isDirFlag: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirFlag) else { return nil }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isApp = url.pathExtension.lowercased() == "app"
        let isFolder = (values?.isDirectory ?? isDirFlag.boolValue) && !(values?.isPackage ?? false) && !isApp
        let category: SearchCategory = isApp ? .application : (isFolder ? .folder : .file)

        return SearchItem(
            id: "file:\(url.path)",
            title: url.path == "/" ? "/" : url.lastPathComponent,
            subtitle: tildeShortened(url.path, home: home),
            category: category,
            iconPath: url.path,
            score: 1050,
            action: .openFile(url),
            previewURL: url,
            matchSource: .path
        )
    }

    private static func listDirectoryEntries(
        at directory: URL, includeHidden: Bool, home: String, fm: FileManager, limit: Int
    ) -> [SearchItem] {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue,
              let rawEntries = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: resourceKeys, options: []
              ) else { return [] }

        var entries: [(url: URL, name: String, isFolder: Bool, isApp: Bool, modifiedAt: Date)] = []
        for entry in rawEntries {
            let name = entry.lastPathComponent
            if !includeHidden, name.hasPrefix(".") { continue }
            let values = try? entry.resourceValues(forKeys: Set(resourceKeys))
            let isApp = entry.pathExtension.lowercased() == "app"
            let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false) && !isApp
            entries.append((entry.standardizedFileURL, name, isFolder, isApp, values?.contentModificationDate ?? .distantPast))
        }

        entries.sort { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            if lhs.isFolder { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let parentSubtitle = tildeShortened(directory.path, home: home)
        return entries.prefix(limit).enumerated().map { idx, entry in
            let category: SearchCategory = entry.isApp ? .application : (entry.isFolder ? .folder : .file)
            return SearchItem(
                id: "file:\(entry.url.path)",
                title: entry.name,
                subtitle: parentSubtitle,
                category: category,
                iconPath: entry.url.path,
                score: (entry.isFolder ? 920 : 760) - idx,
                action: .openFile(entry.url),
                previewURL: entry.url,
                matchSource: .path
            )
        }
    }

    private static func filterDirectoryEntries(
        at directory: URL, filterTerm: String, includeHidden: Bool,
        excluding: Set<String>, home: String, fm: FileManager
    ) -> [SearchItem] {
        guard !filterTerm.isEmpty,
              let rawEntries = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: resourceKeys, options: []
              ) else { return [] }

        let parentSubtitle = tildeShortened(directory.path, home: home)
        var scored: [(item: SearchItem, isFolder: Bool)] = []

        for entry in rawEntries {
            let standardized = entry.standardizedFileURL
            guard !excluding.contains(standardized.path) else { continue }
            let name = standardized.lastPathComponent
            if !includeHidden, name.hasPrefix(".") { continue }

            let matchedScore = FuzzyMatcher.scoreFilename(query: filterTerm, fileName: name)
                ?? (filterTerm == "." && name.hasPrefix(".") ? 750 : nil)
            guard let baseScore = matchedScore else { continue }

            let values = try? entry.resourceValues(forKeys: Set(resourceKeys))
            let isApp = standardized.pathExtension.lowercased() == "app"
            let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false) && !isApp
            let category: SearchCategory = isApp ? .application : (isFolder ? .folder : .file)
            scored.append((SearchItem(
                id: "file:\(standardized.path)",
                title: name,
                subtitle: parentSubtitle,
                category: category,
                iconPath: standardized.path,
                score: min(1040, baseScore + (isFolder ? 30 : 0)),
                action: .openFile(standardized),
                previewURL: standardized,
                matchSource: .path
            ), isFolder))
        }

        scored.sort { lhs, rhs in
            if lhs.item.score != rhs.item.score { return lhs.item.score > rhs.item.score }
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title) == .orderedAscending
        }
        return scored.map(\.item)
    }

    private static func expandPath(_ trimmed: String, home: String) -> String? {
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home + String(trimmed.dropFirst(1)) }
        return trimmed.hasPrefix("/") ? trimmed : nil
    }

    private static func isDirectoryItem(url: URL, category: SearchCategory) -> Bool {
        if category == .application || url.pathExtension.lowercased() == "app" { return false }
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
           let isDir = values.isDirectory {
            return isDir && !(values.isPackage ?? false)
        }
        return category == .folder
    }

    private static func tildeShortened(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static func normalizedDirectory(_ path: String) -> String {
        (path.count > 1 && path.hasSuffix("/")) ? String(path.dropLast()) : path
    }
}
