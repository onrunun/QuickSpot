import Foundation

/// Persistent preferences controlling which folders and power conditions are used for image OCR indexing.
public struct IndexSettings: Equatable, Sendable {
    public var folders: [String]
    public var excludedFolders: [String]
    public var indexOnBattery: Bool
    public var isOCREnabled: Bool

    public init(
        folders: [String],
        indexOnBattery: Bool = false,
        isOCREnabled: Bool = true,
        excludedFolders: [String] = []
    ) {
        self.folders = folders
        self.excludedFolders = excludedFolders
        self.indexOnBattery = indexOnBattery
        self.isOCREnabled = isOCREnabled
    }
}

/// Thread-safe UserDefaults store for image OCR folder and power settings.
public final class IndexSettingsStore: @unchecked Sendable {
    private static let foldersKey = "QuickSpot.ocr.folders"
    private static let excludedFoldersKey = "QuickSpot.ocr.excludedFolders"
    private static let batteryKey = "QuickSpot.ocr.indexOnBattery"
    private static let enabledKey = "QuickSpot.ocr.enabled"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func defaultFolders() -> [String] {
        let home = NSHomeDirectory()
        let candidates = ["Desktop", "Downloads", "Pictures", "Documents"]
            .map { (home as NSString).appendingPathComponent($0) }
        return candidates.filter { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    public func load() -> IndexSettings {
        lock.lock()
        defer { lock.unlock() }

        let folders: [String]
        if defaults.object(forKey: Self.foldersKey) != nil {
            folders = defaults.stringArray(forKey: Self.foldersKey) ?? []
        } else {
            folders = Self.defaultFolders()
        }

        let excluded = defaults.stringArray(forKey: Self.excludedFoldersKey) ?? []
        let onBattery = defaults.bool(forKey: Self.batteryKey)
        let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        return IndexSettings(
            folders: deduplicated(folders),
            indexOnBattery: onBattery,
            isOCREnabled: enabled,
            excludedFolders: deduplicated(excluded)
        )
    }

    public func save(_ settings: IndexSettings) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(deduplicated(settings.folders), forKey: Self.foldersKey)
        defaults.set(deduplicated(settings.excludedFolders), forKey: Self.excludedFoldersKey)
        defaults.set(settings.indexOnBattery, forKey: Self.batteryKey)
        defaults.set(settings.isOCREnabled, forKey: Self.enabledKey)
    }

    @discardableResult
    public func addFolder(_ path: String) -> IndexSettings {
        var current = load()
        let normalized = (path as NSString).standardizingPath
        if !current.folders.contains(normalized) {
            current.folders.append(normalized)
            save(current)
        }
        return current
    }

    @discardableResult
    public func removeFolder(_ path: String) -> IndexSettings {
        var current = load()
        let normalized = (path as NSString).standardizingPath
        current.folders.removeAll { ($0 as NSString).standardizingPath == normalized }
        save(current)
        return current
    }

    @discardableResult
    public func addExcludedFolder(_ path: String) -> IndexSettings {
        var current = load()
        let normalized = (path as NSString).standardizingPath
        if !current.excludedFolders.contains(normalized) {
            current.excludedFolders.append(normalized)
            save(current)
        }
        return current
    }

    @discardableResult
    public func removeExcludedFolder(_ path: String) -> IndexSettings {
        var current = load()
        let normalized = (path as NSString).standardizingPath
        current.excludedFolders.removeAll { ($0 as NSString).standardizingPath == normalized }
        save(current)
        return current
    }

    private func deduplicated(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in paths {
            let std = (raw as NSString).standardizingPath
            guard !std.isEmpty, seen.insert(std).inserted else { continue }
            result.append(std)
        }
        return result
    }
}
