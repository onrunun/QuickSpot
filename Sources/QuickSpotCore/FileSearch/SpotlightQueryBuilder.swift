import Foundation

/// Pure predicate, path-filtering, Turkish-variant, and calibrated file-scoring helpers shared by file search providers.
enum SpotlightQueryBuilder {
    private static let excludedDirectoryNames: Set<Substring> = [
        ".git", "node_modules", ".build", ".next", ".turbo", ".venv",
        "__pycache__", ".cache", ".Trash", ".npm", ".gemini", ".vscode",
        ".cursor", ".omp", "DerivedData", "Pods", "build.noindex"
    ]
    private static let skippedVolumeNames: Set<String> = ["recovery", "preboot", "vm", ".timemachine"]
    private static let dotSensitiveChars: Set<Character> = ["i", "I", "ı", "İ"]

    /// Excludes system/build/cache directories and `.app` bundles while always protecting `~/Library/Mobile Documents/`.
    static func isExcludedPath(_ path: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        let home = normalizedDirectory(homeDirectory)
        if path == "/Library" || path.hasPrefix("/Library/")
            || path == "/System/Library" || path.hasPrefix("/System/Library/") {
            return true
        }

        let userLibrary = home + "/Library"
        let iCloudRoot = userLibrary + "/Mobile Documents"
        if path == userLibrary || path.hasPrefix(userLibrary + "/") {
            let isICloud = (path == iCloudRoot || path.hasPrefix(iCloudRoot + "/"))
            if !isICloud { return true }
        }

        for component in path.split(separator: "/") {
            if excludedDirectoryNames.contains(component) { return true }
            if component.hasSuffix(".app") || component.lowercased().hasSuffix(".app") { return true }
        }
        return false
    }

    /// Expands Turkish `ı` ↔ `i` variants (up to 4) so Spotlight `LIKE[cd]` matches both dotted and dotless forms.
    static func turkishSearchVariants(for word: String) -> [String] {
        guard !word.isEmpty else { return [] }
        let chars = Array(word)
        let dotIndices = chars.indices.filter { dotSensitiveChars.contains(chars[$0]) }
        guard !dotIndices.isEmpty else { return [word] }

        var variants: [String] = []
        var seen = Set<String>()
        func appendUnique(_ candidate: String) {
            if seen.insert(candidate).inserted { variants.append(candidate) }
        }

        if dotIndices.count <= 2 {
            for mask in 0..<(1 << dotIndices.count) {
                var copy = chars
                for (bit, idx) in dotIndices.enumerated() where (mask & (1 << bit)) != 0 {
                    copy[idx] = (copy[idx] == "ı") ? "i" : "ı"
                }
                appendUnique(String(copy))
            }
        } else {
            appendUnique(word)
            appendUnique(String(chars.map { dotSensitiveChars.contains($0) ? Character("i") : $0 }))
            appendUnique(String(chars.map { dotSensitiveChars.contains($0) ? Character("ı") : $0 }))
        }
        return Array(variants.prefix(4))
    }

    /// Returns `[NSMetadataQueryUserHomeScope]` plus mounted non-system external volumes under `/Volumes`.
    static func buildSearchScopes(fileManager: FileManager = .default) -> [Any] {
        var scopes: [Any] = [NSMetadataQueryUserHomeScope]
        let volumesRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: volumesRoot,
            includingPropertiesForKeys: [.volumeIsRootFileSystemKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return scopes }

        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") || skippedVolumeNames.contains(name.lowercased()) { continue }
            if entry.resolvingSymlinksInPath().standardizedFileURL.path == "/" { continue }
            let values = try? entry.resourceValues(forKeys: [.volumeIsRootFileSystemKey, .isDirectoryKey])
            if values?.volumeIsRootFileSystem == true || values?.isDirectory == false { continue }
            scopes.append(entry)
        }
        return scopes
    }

    /// Builds a Spotlight predicate for either filename-only Phase 1 or content-only Phase 2 searches.
    static func buildPredicate(term: String, filter: SearchKindFilter?, contentOnly: Bool) -> NSPredicate {
        let rawWords = term.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let words = rawWords.isEmpty ? [term] : rawWords

        var predicates: [NSPredicate] = words.compactMap { word in
            let subpredicates: [NSPredicate] = turkishSearchVariants(for: word).map { variant in
                let pattern = "*\(escapeSpotlightPattern(variant))*"
                return contentOnly
                    ? NSPredicate(format: "kMDItemTextContent LIKE[cd] %@", pattern)
                    : NSPredicate(format: "(kMDItemFSName LIKE[cd] %@ OR kMDItemDisplayName LIKE[cd] %@)", pattern, pattern)
            }
            guard !subpredicates.isEmpty else { return nil }
            return subpredicates.count == 1 ? subpredicates[0] : NSCompoundPredicate(orPredicateWithSubpredicates: subpredicates)
        }

        switch filter {
        case .imagesOnly: predicates.append(NSPredicate(format: "kMDItemContentTypeTree == 'public.image'"))
        case .pdfOnly: predicates.append(NSPredicate(format: "kMDItemContentTypeTree == 'com.adobe.pdf'"))
        case .foldersOnly: predicates.append(NSPredicate(format: "kMDItemContentType == 'public.folder'"))
        case .filesOnly, .contentOnly: predicates.append(NSPredicate(format: "kMDItemContentType != 'public.folder'"))
        case .appsOnly, .clipboard: break
        case nil:
            if contentOnly { predicates.append(NSPredicate(format: "kMDItemContentType != 'public.folder'")) }
        }

        guard !predicates.isEmpty else { return NSPredicate(value: false) }
        return predicates.count == 1 ? predicates[0] : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    /// Calibrated score for filename matches (`FuzzyMatcher.scoreFilename` + recency + location + frecency).
    static func scoreFilenameMatch(
        query: String,
        fileName: String,
        displayName: String? = nil,
        standardizedPath: String,
        referenceDate: Date?,
        frecencyBoost: Int,
        homeDirectory: String = NSHomeDirectory(),
        now: Date = Date()
    ) -> Int {
        let fsRaw = FuzzyMatcher.scoreFilename(query: query, fileName: fileName)
        let displayRaw = displayName.flatMap { name in
            (!name.isEmpty && name != fileName) ? FuzzyMatcher.scoreFilename(query: query, fileName: name) : nil
        }
        let bestRaw = max(fsRaw ?? 0, displayRaw ?? 0)
        let base = bestRaw > 0 ? mapFilenameBaseScore(bestRaw) : 500
        let recency = recencyBonus(for: referenceDate, now: now)
        let location = locationBonus(for: standardizedPath, homeDirectory: homeDirectory)
        return base + recency + location + min(max(frecencyBoost, 0), 180)
    }

    /// Calibrated score for content-only matches, strictly bounded to `360...520` so filename hits always win.
    static func scoreContentMatch(
        query: String,
        fileName: String,
        standardizedPath: String,
        referenceDate: Date?,
        frecencyBoost: Int,
        rankIndex: Int,
        homeDirectory: String = NSHomeDirectory(),
        now: Date = Date()
    ) -> Int {
        var score = 375
        if let date = referenceDate {
            let age = max(0, now.timeIntervalSince(date))
            if age < 86_400 { score += 45 }
            else if age < 604_800 { score += 30 }
            else if age < 2_592_000 { score += 15 }
            else if age < 7_776_000 { score += 5 }
        }
        let loc = locationBonus(for: standardizedPath, homeDirectory: homeDirectory)
        if loc >= 30 { score += 25 } else if loc >= 15 { score += 15 }
        if FuzzyMatcher.scoreFilename(query: query, fileName: fileName) != nil { score += 30 }
        score += min(max(frecencyBoost, 0) / 4, 40) - min(rankIndex * 2, 30)
        return max(360, min(520, score))
    }

    static func mapFilenameBaseScore(_ raw: Int) -> Int {
        if raw >= 1000 { return 900 }
        if raw >= 800 { return raw <= 880 ? 760 + (raw - 800) : 840 + ((raw - 880) * 40) / 119 }
        if raw >= 700 { return 680 + ((raw - 700) * 80) / 100 }
        if raw >= 240 { return 520 + ((raw - 240) * 140) / 459 }
        return 500
    }

    static func recencyBonus(for date: Date?, now: Date = Date()) -> Int {
        guard let date else { return 0 }
        let age = max(0, now.timeIntervalSince(date))
        if age < 86_400 { return 60 }
        if age < 604_800 { return 40 }
        if age < 2_592_000 { return 20 }
        if age < 7_776_000 { return 8 }
        return 0
    }

    static func locationBonus(for standardizedPath: String, homeDirectory: String = NSHomeDirectory()) -> Int {
        let home = normalizedDirectory(homeDirectory)
        let primaryRoots = [
            home + "/Desktop",
            home + "/Downloads",
            home + "/Documents",
            home + "/Library/Mobile Documents/com~apple~CloudDocs"
        ]
        for root in primaryRoots {
            if standardizedPath == root { return 40 }
            if standardizedPath.hasPrefix(root + "/") {
                let depth = standardizedPath.dropFirst(root.count + 1).split(separator: "/").count
                let shallowBonus = depth <= 2 ? 5 : 0
                let depthPenalty = depth > 5 ? min((depth - 5) * 6, 25) : 0
                return max(0, min(40, 35 + shallowBonus - depthPenalty))
            }
        }

        let projectsRoot = home + "/Projects"
        if standardizedPath == projectsRoot || standardizedPath.hasPrefix(projectsRoot + "/") {
            let depth = standardizedPath == projectsRoot
                ? 0
                : standardizedPath.dropFirst(projectsRoot.count + 1).split(separator: "/").count
            if depth <= 2 { return 25 }
            if depth <= 3 { return 20 }
            if depth <= 5 { return 10 }
            return max(-10, 10 - (depth - 5) * 5)
        }

        if standardizedPath.hasPrefix(home + "/") {
            let depth = standardizedPath.dropFirst(home.count + 1).split(separator: "/").count
            if depth <= 2 { return 10 }
            return depth <= 5 ? 0 : -min((depth - 5) * 5, 15)
        }

        if standardizedPath.hasPrefix("/Volumes/") {
            let depth = max(0, standardizedPath.dropFirst("/Volumes/".count).split(separator: "/").count - 1)
            if depth <= 2 { return 15 }
            return depth <= 5 ? 0 : -min((depth - 5) * 5, 15)
        }
        return 0
    }

    static func formatParentSubtitle(for url: URL, homeDirectory: String = NSHomeDirectory()) -> String {
        shortenPath(url.deletingLastPathComponent().standardizedFileURL.path, homeDirectory: homeDirectory)
    }

    static func shortenPath(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let home = normalizedDirectory(homeDirectory)
        let iCloudDocs = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if path == iCloudDocs { return "iCloud Drive" }
        if path.hasPrefix(iCloudDocs + "/") { return "iCloud Drive/" + path.dropFirst(iCloudDocs.count + 1) }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static func escapeSpotlightPattern(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
    }

    private static func normalizedDirectory(_ path: String) -> String {
        (path.count > 1 && path.hasSuffix("/")) ? String(path.dropLast()) : path
    }
}
