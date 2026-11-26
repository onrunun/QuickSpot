import AppKit
import Foundation

/// Represents an installed macOS application capable of opening a target file or folder.
public struct OpenWithApp: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let appURL: URL

    public init(name: String, appURL: URL) {
        self.id = appURL.standardizedFileURL.path
        self.name = name
        self.appURL = appURL
    }
}

/// Executes secondary file actions (`⌘K` palette): Open With, Open Folder in Terminal, and safe Move to Trash.
public enum FileActionService {
    /// Returns installed applications registered to open `url`, prioritizing the system default handler first.
    public static func applicationsForOpening(_ url: URL, limit: Int = 6) -> [OpenWithApp] {
        guard url.isFileURL, url.pathExtension.lowercased() != "app" else { return [] }
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)?.standardizedFileURL
        let rawApps = NSWorkspace.shared.urlsForApplications(toOpen: url)

        var seen = Set<String>()
        var ordered: [URL] = []
        if let defaultApp {
            seen.insert(defaultApp.path)
            ordered.append(defaultApp)
        }
        for appURL in rawApps {
            let std = appURL.standardizedFileURL
            guard seen.insert(std.path).inserted else { continue }
            ordered.append(std)
        }

        let sortedTail = ordered.dropFirst(defaultApp == nil ? 0 : 1).sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
        let combined = (defaultApp.map { [$0] } ?? []) + sortedTail
        return combined.prefix(limit).map { OpenWithApp(name: displayName(for: $0), appURL: $0) }
    }

    /// Opens `fileURL` using the chosen application bundle `appURL`.
    @discardableResult
    public static func open(_ fileURL: URL, withApplication appURL: URL) -> String? {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config) { _, _ in }
        return nil
    }

    /// Opens Terminal.app directly in `url` (if a directory) or its parent directory (if a file).
    public static func openInTerminal(_ url: URL) -> String? {
        guard url.isFileURL else { return L10n.tr("file_action.error.invalid_path") }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let targetDir = isDir ? url : url.deletingLastPathComponent()
        let sanitizedPath = targetDir.path
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let cdCommand = "cd \(shellQuote(sanitizedPath))"
        let escaped = cdCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var errorInfo: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                return L10n.tr("file_action.error.terminal_automation")
            }
            let detail = (errorInfo[NSAppleScript.errorBriefMessage] as? String)
                ?? (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? L10n.tr("file_action.error.unknown")
            return L10n.format("file_action.error.open_terminal_failed", detail)
        }
        return nil
    }

    /// Safely moves a file or folder to the user's Trash (reversible in Finder).
    public static func moveToTrash(_ url: URL) -> Result<URL?, Error> {
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return .success(resultingURL as URL?)
        } catch {
            return .failure(error)
        }
    }

    /// POSIX single-quote escaping safe for paths containing spaces, quotes, or Unicode characters.
    public static func shellQuote(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func displayName(for appURL: URL) -> String {
        if let localized = try? appURL.resourceValues(forKeys: [.localizedNameKey]).localizedName, !localized.isEmpty {
            return localized.replacingOccurrences(of: ".app", with: "")
        }
        return appURL.deletingPathExtension().lastPathComponent
    }
}
