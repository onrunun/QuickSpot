import AppKit
import Foundation

/// Detects Terminal commands (`>` / `$`), web URLs/domains/localhost, and Google search fallbacks.
public enum WebAndTerminalAction {
    private static let fileExtensions: Set<String> = [
        "md", "txt", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "py", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "sh", "bash", "zsh",
        "swift", "c", "cpp", "h", "m", "rs", "go", "rb", "java", "kt", "html", "css", "scss",
        "png", "jpg", "jpeg", "gif", "svg", "webp", "mp4", "mov", "mp3", "wav", "m4a",
        "zip", "tar", "gz", "app", "dmg", "pkg", "iso", "csv", "sql", "sqlite", "db", "log", "env", "xml", "toml"
    ]

    private static let webTLDs: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int",
        "dev", "io", "ai", "co", "app", "tech", "me", "xyz", "info", "biz",
        "cloud", "online", "site", "store", "live", "space", "shop", "top", "club",
        "tr", "de", "uk", "fr", "ru", "jp", "ca", "au", "br", "in", "it", "es", "nl", "se", "no", "fi", "dk", "ch", "at", "be"
    ]

    public static func detectTerminal(_ query: String) -> SearchItem? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(">") || trimmed.hasPrefix("$") else { return nil }
        let cmd = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return nil }
        return SearchItem(
            id: "terminal:\(cmd)",
            title: L10n.format("action.terminal.title", cmd),
            subtitle: L10n.tr("action.terminal.subtitle"),
            category: .quickAction,
            sfSymbol: "terminal.fill",
            score: 1500,
            action: .runTerminal(cmd)
        )
    }

    public static func detectURL(_ query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if trimmed == "localhost" || trimmed.hasPrefix("localhost:") || trimmed.hasPrefix("localhost/") {
            return URL(string: "http://\(trimmed)")
        }
        guard trimmed.contains(".") else { return nil }

        let hostPart = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        let hostWithoutPort = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let parts = hostWithoutPort.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last?.lowercased() else { return nil }
        if fileExtensions.contains(tld) { return nil }
        guard webTLDs.contains(tld) || parts.count >= 3 else { return nil }
        return URL(string: "https://\(trimmed)")
    }

    public static func urlItem(for query: String) -> SearchItem? {
        guard let url = detectURL(query) else { return nil }
        let host = url.host ?? query
        return SearchItem(
            id: "url:\(url.absoluteString)",
            title: L10n.format("action.url.title", host),
            subtitle: L10n.format("action.url.subtitle", url.absoluteString),
            category: .quickAction,
            sfSymbol: "safari.fill",
            score: 1200,
            action: .openURL(url)
        )
    }

    public static func googleSearchItem(for query: String) -> SearchItem? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(encoded)") else { return nil }
        return SearchItem(
            id: "web:\(trimmed)",
            title: L10n.format("action.web_search.title", trimmed),
            subtitle: L10n.tr("action.web_search.subtitle"),
            category: .quickAction,
            sfSymbol: "globe",
            score: 120,
            action: .openURL(url)
        )
    }

    public static func sanitizeTerminalCommand(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .controlCharacters)
    }

    public static func runInTerminal(_ command: String) {
        let sanitized = sanitizeTerminalCommand(command)
        guard !sanitized.isEmpty else { return }
        let escaped = sanitized
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}
