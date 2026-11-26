import Foundation

/// High-level grouping for launcher results in the QuickSpot panel.
public enum SearchCategory: String, Sendable, CaseIterable {
    case quickAction
    case application
    case folder
    case file

    public var sectionTitle: String {
        switch self {
        case .quickAction: return L10n.tr("category.quick_actions")
        case .application: return L10n.tr("category.applications")
        case .folder: return L10n.tr("category.folders")
        case .file: return L10n.tr("category.files")
        }
    }
}

/// Optional search scope/kind filter parsed from query prefixes (`img:`, `pdf:`, `f:`, `dir:`, `in:`, `app:`, `cb:`).
public enum SearchKindFilter: Equatable, Sendable {
    case imagesOnly
    case pdfOnly
    case filesOnly
    case foldersOnly
    case contentOnly
    case appsOnly
    case clipboard

    public var badgeTitle: String {
        switch self {
        case .imagesOnly: return L10n.tr("filter.images")
        case .pdfOnly: return L10n.tr("filter.pdf")
        case .filesOnly: return L10n.tr("filter.files")
        case .foldersOnly: return L10n.tr("filter.folders")
        case .contentOnly: return L10n.tr("filter.content")
        case .appsOnly: return L10n.tr("filter.apps")
        case .clipboard: return L10n.tr("filter.clipboard")
        }
    }
}

/// Provenance of a search hit so the ranker can calibrate filename vs. content vs. quick-action relevance.
public enum MatchSource: String, Equatable, Sendable {
    case name
    case recent
    case path
    case ocrContent
    case semanticVisual
    case semanticText
    case fileContent
    case quickAction
    case clipboard
}

/// Structured representation of a raw user query across terminal, filesystem path, filter prefix, and general modes.
public struct ParsedQuery: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case empty
        case terminal(command: String)
        case path(rawPath: String)
        case filtered(filter: SearchKindFilter, term: String)
        case general(term: String)
    }

    public let raw: String
    public let mode: Mode

    public init(raw: String, mode: Mode) {
        self.raw = raw
        self.mode = mode
    }
}

/// Single source of truth for parsing launcher input into modes and filters.
public enum QueryParser {
    private static let prefixMap: [(prefix: String, filter: SearchKindFilter)] = [
        ("img:", .imagesOnly),
        ("image:", .imagesOnly),
        ("resim:", .imagesOnly),
        ("gorsel:", .imagesOnly),
        ("görsel:", .imagesOnly),
        ("bild:", .imagesOnly),
        ("foto:", .imagesOnly),
        ("pdf:", .pdfOnly),
        ("file:", .filesOnly),
        ("dosya:", .filesOnly),
        ("datei:", .filesOnly),
        ("archivo:", .filesOnly),
        ("fichier:", .filesOnly),
        ("arquivo:", .filesOnly),
        ("f:", .filesOnly),
        ("dir:", .foldersOnly),
        ("folder:", .foldersOnly),
        ("klasor:", .foldersOnly),
        ("klasör:", .foldersOnly),
        ("ordner:", .foldersOnly),
        ("carpeta:", .foldersOnly),
        ("dossier:", .foldersOnly),
        ("pasta:", .foldersOnly),
        ("d:", .foldersOnly),
        ("icerik:", .contentOnly),
        ("içerik:", .contentOnly),
        ("inhalt:", .contentOnly),
        ("contenido:", .contentOnly),
        ("contenu:", .contentOnly),
        ("in:", .contentOnly),
        ("app:", .appsOnly),
        ("uyg:", .appsOnly),
        ("clipboard:", .clipboard),
        ("clip:", .clipboard),
        ("pano:", .clipboard),
        ("cb:", .clipboard)
    ]

    public static func parse(_ raw: String) -> ParsedQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedQuery(raw: raw, mode: .empty)
        }

        if trimmed.hasPrefix(">") || trimmed.hasPrefix("$") {
            let cmd = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            return ParsedQuery(raw: raw, mode: .terminal(command: cmd))
        }

        if trimmed == "~" || trimmed.hasPrefix("~/") || trimmed.hasPrefix("/") {
            return ParsedQuery(raw: raw, mode: .path(rawPath: trimmed))
        }

        let lower = trimmed.lowercased()
        for entry in prefixMap where lower.hasPrefix(entry.prefix) {
            let term = String(trimmed.dropFirst(entry.prefix.count)).trimmingCharacters(in: .whitespaces)
            return ParsedQuery(raw: raw, mode: .filtered(filter: entry.filter, term: term))
        }

        return ParsedQuery(raw: raw, mode: .general(term: trimmed))
    }
}

/// Executable action attached to a search result row.
public enum ItemAction: Equatable, Sendable {
    case openFile(URL)
    case openURL(URL)
    case copyText(String)
    case runTerminal(String)
    case systemCommand(String)
    case openSettings
}

/// Unified result model displayed by the QuickSpot panel and returned by all search slices.
public struct SearchItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let category: SearchCategory
    public let iconPath: String?
    public let sfSymbol: String?
    public let score: Int
    public let action: ItemAction
    public let previewURL: URL?
    public let matchedSnippet: String?
    public let matchSource: MatchSource
    public let requiresConfirmation: Bool

    public init(
        id: String,
        title: String,
        subtitle: String,
        category: SearchCategory,
        iconPath: String? = nil,
        sfSymbol: String? = nil,
        score: Int,
        action: ItemAction,
        previewURL: URL? = nil,
        matchedSnippet: String? = nil,
        matchSource: MatchSource = .name,
        requiresConfirmation: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.iconPath = iconPath
        self.sfSymbol = sfSymbol
        self.score = score
        self.action = action
        self.previewURL = previewURL
        self.matchedSnippet = matchedSnippet
        self.matchSource = matchSource
        self.requiresConfirmation = requiresConfirmation
    }

    public func withScore(_ newScore: Int, matchedSnippet newSnippet: String? = nil) -> SearchItem {
        SearchItem(
            id: id,
            title: title,
            subtitle: subtitle,
            category: category,
            iconPath: iconPath,
            sfSymbol: sfSymbol,
            score: newScore,
            action: action,
            previewURL: previewURL,
            matchedSnippet: newSnippet ?? matchedSnippet,
            matchSource: matchSource,
            requiresConfirmation: requiresConfirmation
        )
    }
}
