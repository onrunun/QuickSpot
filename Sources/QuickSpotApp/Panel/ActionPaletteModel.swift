import Foundation
import QuickSpotCore

/// Action executable from the `⌘K` secondary action palette.
enum PaletteActionKind: Equatable {
    case open
    case enterFolder
    case openWith(URL)
    case revealInFinder
    case openInTerminal
    case quickLook
    case copyItem
    case copyPath
    case copyOCRText
    case moveToTrash
    case deleteClipboardEntry(String)
    case clearClipboardHistory
}

/// One row displayed inside the `⌘K` action palette overlay.
struct PaletteActionItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let sfSymbol: String?
    let iconPath: String?
    let shortcutHint: String?
    let kind: PaletteActionKind
    let isDestructive: Bool

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        sfSymbol: String? = nil,
        iconPath: String? = nil,
        shortcutHint: String? = nil,
        kind: PaletteActionKind,
        isDestructive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.sfSymbol = sfSymbol
        self.iconPath = iconPath
        self.shortcutHint = shortcutHint
        self.kind = kind
        self.isDestructive = isDestructive
    }
}

/// Builds context-aware secondary actions (`Open With`, Terminal, Trash, Clipboard management) for any result.
enum ActionPaletteBuilder {
    static func buildActions(for item: SearchItem, fullOCRText: String?) -> [PaletteActionItem] {
        if item.matchSource == .clipboard, item.id.hasPrefix("clip:") {
            let entryID = String(item.id.dropFirst(5))
            return [
                PaletteActionItem(
                    id: "act:copy",
                    title: L10n.tr("palette.copy_to_clipboard"),
                    sfSymbol: "doc.on.clipboard",
                    shortcutHint: "⏎",
                    kind: .open
                ),
                PaletteActionItem(
                    id: "act:clip-delete",
                    title: L10n.tr("palette.delete_from_history"),
                    sfSymbol: "trash",
                    shortcutHint: "⌫",
                    kind: .deleteClipboardEntry(entryID),
                    isDestructive: false
                ),
                PaletteActionItem(
                    id: "act:clip-clear",
                    title: L10n.tr("palette.clear_clipboard"),
                    subtitle: L10n.tr("row.requires_confirmation_help"),
                    sfSymbol: "trash.slash",
                    kind: .clearClipboardHistory,
                    isDestructive: true
                )
            ]
        }

        if let url = item.previewURL, url.isFileURL {
            return buildFileActions(item: item, url: url, fullOCRText: fullOCRText)
        }

        return [
            PaletteActionItem(
                id: "act:primary",
                title: item.primaryActionTitle,
                sfSymbol: item.sfSymbol ?? "return",
                shortcutHint: "⏎",
                kind: .open
            ),
            PaletteActionItem(
                id: "act:copy",
                title: L10n.tr("context.copy"),
                sfSymbol: "doc.on.doc",
                shortcutHint: "⌘C",
                kind: .copyItem
            )
        ]
    }

    private static func buildFileActions(
        item: SearchItem,
        url: URL,
        fullOCRText: String?
    ) -> [PaletteActionItem] {
        var actions: [PaletteActionItem] = [
            PaletteActionItem(
                id: "act:open",
                title: item.primaryActionTitle,
                sfSymbol: "arrow.up.forward.app",
                shortcutHint: "⏎",
                kind: .open
            )
        ]

        if item.category == .folder {
            actions.append(PaletteActionItem(
                id: "act:enter-folder",
                title: L10n.tr("palette.enter_folder"),
                sfSymbol: "folder.badge.arrow.right",
                shortcutHint: "⇥",
                kind: .enterFolder
            ))
        }

        actions.append(PaletteActionItem(
            id: "act:reveal",
            title: L10n.tr("context.reveal_in_finder"),
            sfSymbol: "finder",
            shortcutHint: "⌘⏎",
            kind: .revealInFinder
        ))

        actions.append(PaletteActionItem(
            id: "act:terminal",
            title: item.category == .folder
                ? L10n.tr("palette.open_in_terminal")
                : L10n.tr("palette.open_folder_in_terminal"),
            sfSymbol: "terminal",
            kind: .openInTerminal
        ))

        let isApp = url.pathExtension.lowercased() == "app"
        if !isApp {
            actions.append(PaletteActionItem(
                id: "act:quicklook",
                title: L10n.tr("palette.quick_look_preview"),
                sfSymbol: "eye",
                shortcutHint: "⌘Y",
                kind: .quickLook
            ))

            let openWithApps = FileActionService.applicationsForOpening(url, limit: 5)
            for app in openWithApps {
                actions.append(PaletteActionItem(
                    id: "act:openwith:\(app.id)",
                    title: L10n.format("palette.open_with", app.name),
                    iconPath: app.appURL.path,
                    kind: .openWith(app.appURL)
                ))
            }
        }

        actions.append(PaletteActionItem(
            id: "act:copy",
            title: L10n.tr("context.copy"),
            sfSymbol: "doc.on.doc",
            shortcutHint: "⌘C",
            kind: .copyItem
        ))
        actions.append(PaletteActionItem(
            id: "act:copy-path",
            title: L10n.tr("context.copy_path"),
            sfSymbol: "link",
            shortcutHint: "⌥⌘C",
            kind: .copyPath
        ))

        if let text = fullOCRText, !text.isEmpty {
            actions.append(PaletteActionItem(
                id: "act:copy-ocr",
                title: L10n.tr("palette.copy_ocr_text"),
                sfSymbol: "doc.text.viewfinder",
                kind: .copyOCRText
            ))
        }

        if canSafelyTrash(url) {
            actions.append(PaletteActionItem(
                id: "act:trash",
                title: L10n.tr("palette.move_to_trash"),
                subtitle: L10n.tr("palette.move_to_trash_subtitle"),
                sfSymbol: "trash",
                kind: .moveToTrash,
                isDestructive: true
            ))
        }

        return actions
    }

    private static func canSafelyTrash(_ url: URL) -> Bool {
        let std = url.standardizedFileURL.path
        if std == "/" || std == NSHomeDirectory() { return false }
        if std.hasPrefix("/System/") || std.hasPrefix("/Applications/") || std.hasPrefix("/usr/") {
            return false
        }
        return true
    }
}
