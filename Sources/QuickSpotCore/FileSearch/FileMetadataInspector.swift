import Foundation
import UniformTypeIdentifiers

/// Structured metadata summary displayed in the right-side preview pane for files and apps.
public struct FilePreviewMetadata: Equatable, Sendable {
    public let kindLabel: String
    public let sizeLabel: String?
    public let modifiedLabel: String?
    public let appVersion: String?
    public let bundleIdentifier: String?

    public var detailsLine: String {
        [kindLabel, appVersion, bundleIdentifier, sizeLabel, modifiedLabel]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// Extracts Finder/bundle metadata and safe UTF-8 text snippets without blocking the UI thread.
public enum FileMetadataInspector {
    private static let codeAndTextExtensions: Set<String> = [
        "swift", "py", "js", "ts", "tsx", "jsx", "md", "txt", "json", "yaml", "yml",
        "toml", "sh", "bash", "zsh", "rs", "go", "c", "cpp", "h", "m", "java", "kt",
        "rb", "html", "css", "scss", "sql", "xml", "csv", "log", "gitignore",
        "dockerfile", "makefile", "conf", "ini", "plist"
    ]

    private static let specialTextFilenames: Set<String> = [
        "dockerfile", "makefile", ".gitignore", ".zshrc", ".bashrc", "readme", "license"
    ]

    private static let sensitiveExtensions: Set<String> = [
        "env", "pem", "key", "p12", "pfx", "cer", "der", "kdbx"
    ]

    private static let sensitiveFilenames: Set<String> = [
        ".env", ".npmrc", ".netrc", ".pypirc", "id_rsa", "id_ed25519", "id_ecdsa", "credentials"
    ]

    public static func inspect(_ url: URL) -> FilePreviewMetadata {
        if url.pathExtension.lowercased() == "app" {
            let info = Bundle(url: url)?.infoDictionary
            let rawVersion = (info?["CFBundleShortVersionString"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let version = (rawVersion?.isEmpty == false) ? "v\(rawVersion!)" : nil
            let bundleID = (info?["CFBundleIdentifier"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return FilePreviewMetadata(
                kindLabel: L10n.tr("kind.application"),
                sizeLabel: nil,
                modifiedLabel: nil,
                appVersion: version,
                bundleIdentifier: (bundleID?.isEmpty == false) ? bundleID : nil
            )
        }

        let keys: Set<URLResourceKey> = [
            .contentTypeKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let isDir = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
        let kindLabel = isDir
            ? L10n.tr("kind.folder")
            : (values?.contentType?.localizedDescription?.localizedCapitalized ?? L10n.tr("kind.file"))

        let sizeLabel: String?
        if !isDir, let bytes = values?.fileSize {
            sizeLabel = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } else {
            sizeLabel = nil
        }

        let modifiedLabel = values?.contentModificationDate.map { formatDate($0) }
        return FilePreviewMetadata(
            kindLabel: kindLabel,
            sizeLabel: sizeLabel,
            modifiedLabel: modifiedLabel,
            appVersion: nil,
            bundleIdentifier: nil
        )
    }

    public static func isSensitiveFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if sensitiveFilenames.contains(name) || sensitiveExtensions.contains(ext) { return true }
        if name.hasPrefix(".env.") || name.hasSuffix(".env") { return true }
        return false
    }

    public static func isTextOrCode(_ url: URL) -> Bool {
        guard !isSensitiveFile(url) else { return false }
        let ext = url.pathExtension.lowercased()
        guard ext != "app" else { return false }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard !isDir else { return false }

        if codeAndTextExtensions.contains(ext) { return true }
        if specialTextFilenames.contains(url.lastPathComponent.lowercased()) { return true }
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            return utType.conforms(to: .sourceCode) || utType.conforms(to: .plainText)
        }
        return false
    }

    public static func loadTextSnippet(_ url: URL, maxLines: Int = 45, maxBytes: Int = 16_384) -> [String]? {
        guard isTextOrCode(url),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: maxBytes),
              !data.isEmpty,
              !data.contains(0) else { return nil }

        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" {
            lines.removeLast()
        }
        let clipped = Array(lines.prefix(maxLines))
        guard clipped.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        return clipped
    }

    private static func formatDate(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(L10n.currentLocale)
        )
    }
}
