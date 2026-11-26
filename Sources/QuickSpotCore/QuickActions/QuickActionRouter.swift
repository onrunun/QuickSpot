import AppKit
import Foundation

/// Combines launcher quick-action reflexes (Terminal, Calc, Converters, URL, System, Web) and executes item actions.
public enum QuickActionRouter {
    public static func generate(
        for query: String,
        localHits: [SearchItem],
        frecency: FrecencyStore? = nil
    ) -> [SearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let terminalItem = WebAndTerminalAction.detectTerminal(trimmed) {
            return [terminalItem]
        }

        var actions: [SearchItem] = []
        actions.append(contentsOf: SystemCommandAction.match(query: trimmed, frecency: frecency))
        actions.append(contentsOf: SystemSettingsAction.match(query: trimmed, frecency: frecency))
        if let calcItem = CalculatorAction.item(for: trimmed) {
            actions.append(calcItem)
        }
        if let convItem = ConverterAction.item(for: trimmed) {
            actions.append(convItem)
        }
        if let urlItem = WebAndTerminalAction.urlItem(for: trimmed) {
            actions.append(urlItem)
        }

        let hasStrongLocalHit = localHits.contains { $0.score >= 720 }
        let hasURL = actions.contains {
            if case .openURL = $0.action { return true }
            return false
        }
        if !hasStrongLocalHit, !hasURL, let googleItem = WebAndTerminalAction.googleSearchItem(for: trimmed) {
            actions.append(googleItem)
        }
        return actions
    }

    /// Executes non-AI item actions; returns true when the launcher panel should close.
    @discardableResult
    public static func execute(
        _ action: ItemAction,
        frecency: FrecencyStore? = nil,
        itemID: String? = nil,
        query: String? = nil
    ) -> Bool {
        executeWithFeedback(action, frecency: frecency, itemID: itemID, query: query).shouldHide
    }

    /// Executes non-AI item actions and returns panel hide intent plus optional user-facing error feedback.
    public static func executeWithFeedback(
        _ action: ItemAction,
        frecency: FrecencyStore? = nil,
        itemID: String? = nil,
        query: String? = nil
    ) -> (shouldHide: Bool, feedbackMessage: String?) {
        switch action {
        case .openFile(let url):
            let standardizedPath = url.standardizedFileURL.path
            frecency?.record(id: standardizedPath, query: query)
            if NSWorkspace.shared.open(url) {
                return (true, nil)
            }
            return (false, L10n.format("router.error.open_file", url.lastPathComponent))
        case .openURL(let url):
            if let id = itemID, id.hasPrefix("pref:") {
                frecency?.record(id: id, query: query)
            }
            if NSWorkspace.shared.open(url) {
                return (true, nil)
            }
            return (false, L10n.format("router.error.open_url", url.absoluteString))
        case .copyText(let text):
            if let id = itemID, id.hasPrefix("sys:") {
                frecency?.record(id: id, query: query)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return (true, nil)
        case .runTerminal(let cmd):
            WebAndTerminalAction.runInTerminal(cmd)
            return (true, nil)
        case .systemCommand(let cmd):
            frecency?.record(id: "sys:\(cmd)", query: query)
            if let errorMessage = SystemCommandExecutor.executeWithError(cmd) {
                return (false, errorMessage)
            }
            return (true, nil)
        case .openSettings:
            frecency?.record(id: "sys:settings", query: query)
            return (false, nil)
        }
    }
}
