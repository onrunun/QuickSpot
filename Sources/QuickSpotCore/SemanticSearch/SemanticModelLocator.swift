import Foundation
import Metal

/// Persistent user preferences for local EmbeddingGemma 2 multimodal semantic search.
public struct SemanticSettings: Equatable, Sendable {
    public var isEnabled: Bool
    public var customModelsDirectory: String?

    public init(isEnabled: Bool = true, customModelsDirectory: String? = nil) {
        self.isEnabled = isEnabled
        self.customModelsDirectory = customModelsDirectory
    }
}

/// Thread-safe UserDefaults store for semantic search preferences.
public final class SemanticSettingsStore: @unchecked Sendable {
    private static let enabledKey = "QuickSpot.semantic.enabled"
    private static let modelsDirKey = "QuickSpot.semantic.modelsDirectory"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SemanticSettings {
        lock.lock()
        defer { lock.unlock() }
        let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        let rawDir = defaults.string(forKey: Self.modelsDirKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = (rawDir?.isEmpty == false) ? (rawDir! as NSString).standardizingPath : nil
        return SemanticSettings(isEnabled: enabled, customModelsDirectory: dir)
    }

    public func save(_ settings: SemanticSettings) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(settings.isEnabled, forKey: Self.enabledKey)
        if let dir = settings.customModelsDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            defaults.set((dir as NSString).standardizingPath, forKey: Self.modelsDirKey)
        } else {
            defaults.removeObject(forKey: Self.modelsDirKey)
        }
    }
}

/// Resolution outcome for local EmbeddingGemma 2 GGUF weight files.
public enum SemanticModelStatus: Equatable, Sendable {
    case ready(textURL: URL, mmprojURL: URL, directory: URL)
    case missing(directory: URL, missingFiles: [String])

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var directory: URL {
        switch self {
        case .ready(_, _, let dir), .missing(let dir, _):
            return dir
        }
    }
}

/// Locates local EmbeddingGemma 2 GGUF files without making any network requests.
public enum SemanticModelLocator {
    public static let textModelFileName = "embeddinggemma-2-Q8_0.gguf"
    public static let mmprojModelFileName = "mmproj-embeddinggemma-2-Q8_0.gguf"
    public static let modelIdentifier = "embeddinggemma-2-q8_0:256t:768d"
    public static let embeddingDimension = 768
    public static let maxImageTokens = 256
    public static let downloadPageURL = URL(string: "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF")!

    /// EmbeddingGemma 2 Metal kernels rely on Apple Silicon `simdgroup_float8x8` (`apple7`+ GPU family).
    public static var isHardwareSupported: Bool {
        #if arch(arm64)
        return MTLCreateSystemDefaultDevice()?.supportsFamily(.apple7) ?? false
        #else
        return false
        #endif
    }

    /// Resolves just the 310 MB text GGUF so semantic PDF/OCR text search works even without the optional `mmproj` file.
    public static func resolveTextModelURL(customDirectory: String? = nil) -> URL? {
        let dirURL: URL
        if let customDirectory, !customDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dirURL = URL(fileURLWithPath: (customDirectory as NSString).standardizingPath, isDirectory: true)
        } else {
            dirURL = defaultModelsDirectory()
        }
        return resolveTextModelURL(in: dirURL)
    }

    public static func resolveTextModelURL(in directory: URL) -> URL? {
        let textURL = directory.appendingPathComponent(textModelFileName)
        return isReadableFile(at: textURL, fileManager: FileManager.default)
            ? textURL.resolvingSymlinksInPath()
            : nil
    }

    public static func defaultModelsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("QuickSpot/Models", isDirectory: true)
    }

    public static func resolve(customDirectory: String? = nil) -> SemanticModelStatus {
        let dirURL: URL
        if let customDirectory, !customDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dirURL = URL(fileURLWithPath: (customDirectory as NSString).standardizingPath, isDirectory: true)
        } else {
            dirURL = defaultModelsDirectory()
        }
        return resolve(in: dirURL)
    }

    public static func resolve(in directory: URL) -> SemanticModelStatus {
        let fm = FileManager.default
        let textURL = directory.appendingPathComponent(textModelFileName)
        let mmprojURL = directory.appendingPathComponent(mmprojModelFileName)

        var missing: [String] = []
        if !isReadableFile(at: textURL, fileManager: fm) {
            missing.append(textModelFileName)
        }
        if !isReadableFile(at: mmprojURL, fileManager: fm) {
            missing.append(mmprojModelFileName)
        }

        if missing.isEmpty {
            return .ready(
                textURL: textURL.resolvingSymlinksInPath(),
                mmprojURL: mmprojURL.resolvingSymlinksInPath(),
                directory: directory
            )
        }
        return .missing(directory: directory, missingFiles: missing)
    }

    private static func isReadableFile(at url: URL, fileManager: FileManager) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        guard let attrs = try? fileManager.attributesOfItem(atPath: resolved.path),
              let size = attrs[.size] as? NSNumber,
              size.int64Value > 1_000_000 else {
            return false
        }
        return hasValidGGUFHeader(at: resolved)
    }

    private static func hasValidGGUFHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return false }
        // Magic bytes: "GGUF" (0x47, 0x47, 0x55, 0x46) followed by little-endian UInt32 format version (2 or 3).
        guard header[0] == 0x47, header[1] == 0x47, header[2] == 0x55, header[3] == 0x46 else {
            return false
        }
        let version = UInt32(header[4])
            | (UInt32(header[5]) << 8)
            | (UInt32(header[6]) << 16)
            | (UInt32(header[7]) << 24)
        return version == 2 || version == 3
    }
}
