import Foundation

public extension Notification.Name {
    static let quickSpotLanguageDidChange = Notification.Name("QuickSpot.languageDidChange")
}

/// Supported UI and search languages, with automatic macOS system language resolution.
public enum AppLanguage: String, CaseIterable, Equatable, Sendable {
    case system = "system"
    case en = "en"
    case tr = "tr"
    case de = "de"
    case es = "es"
    case fr = "fr"
    case ja = "ja"
    case zhHans = "zh-Hans"
    case ptBR = "pt-BR"

    /// Concrete languages bundled as `.lproj` localization tables.
    public static let concreteLanguages: [AppLanguage] = [
        .en, .tr, .de, .es, .fr, .ja, .zhHans, .ptBR
    ]

    /// Native display name shown in the language picker (endonym so users can always navigate back).
    public var displayName: String {
        switch self {
        case .system: return L10n.tr("settings.general.language_system")
        case .en: return "English"
        case .tr: return "Türkçe"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .fr: return "Français"
        case .ja: return "日本語"
        case .zhHans: return "简体中文"
        case .ptBR: return "Português (Brasil)"
        }
    }

    /// `.lproj` folder name inside the localization bundle.
    public var lprojCode: String? {
        self == .system ? nil : rawValue
    }

    /// Primary Apple Vision OCR BCP-47 language tag for this language.
    public var visionLanguageCode: String {
        switch self {
        case .system, .en: return "en-US"
        case .tr: return "tr-TR"
        case .de: return "de-DE"
        case .es: return "es-ES"
        case .fr: return "fr-FR"
        case .ja: return "ja-JP"
        case .zhHans: return "zh-Hans"
        case .ptBR: return "pt-BR"
        }
    }

    /// Locale identifier used for localized date formatting.
    public var localeIdentifier: String {
        switch self {
        case .system: return Locale.current.identifier
        case .en: return "en_US"
        case .tr: return "tr_TR"
        case .de: return "de_DE"
        case .es: return "es_ES"
        case .fr: return "fr_FR"
        case .ja: return "ja_JP"
        case .zhHans: return "zh_Hans"
        case .ptBR: return "pt_BR"
        }
    }

    /// Resolves a BCP-47 identifier (e.g. `de-AT`, `zh-CN`, `pt-PT`, `tr-TR`) to a bundled concrete language.
    public static func match(identifier: String) -> AppLanguage? {
        let normalized = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
        if normalized == "zh-hans" || normalized.hasPrefix("zh-hans-") || normalized == "zh-cn" || normalized == "zh-sg" || normalized == "zh" {
            return .zhHans
        }
        if normalized == "pt-br" || normalized.hasPrefix("pt-") || normalized == "pt" {
            return .ptBR
        }
        let prefix = normalized.split(separator: "-").first.map(String.init) ?? normalized
        switch prefix {
        case "en": return .en
        case "tr": return .tr
        case "de": return .de
        case "es": return .es
        case "fr": return .fr
        case "ja": return .ja
        default: return nil
        }
    }
}

private final class BundleToken {}

/// Thread-safe localization engine resolving `.lproj` tables across signed `.app` bundles and SwiftPM tests.
public enum L10n {
    private static let storageKey = "QuickSpot.appLanguage"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrideLanguage: AppLanguage?
    nonisolated(unsafe) private static var bundleCache: [String: Bundle] = [:]

    /// Resource bundle located safely in `.app/Contents/Resources` first, falling back to SwiftPM `Bundle.module`.
    public static let resourceBundle: Bundle = {
        let bundleNames = ["QuickSpot_QuickSpotCore.bundle", "QuickSpotCore_QuickSpotCore.bundle"]
        for bundleName in bundleNames {
            let candidates: [URL?] = [
                Bundle.main.resourceURL?.appendingPathComponent(bundleName),
                Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(bundleName)"),
                Bundle.main.bundleURL.appendingPathComponent(bundleName),
                Bundle(for: BundleToken.self).resourceURL?.appendingPathComponent(bundleName)
            ]
            for case let url? in candidates {
                if let bundle = Bundle(url: url) {
                    return bundle
                }
            }
        }
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle(for: BundleToken.self)
        #endif
    }()

    /// Currently persisted language selection (`.system` by default).
    public static var selectedLanguage: AppLanguage {
        lock.lock()
        let activeOverride = overrideLanguage
        lock.unlock()
        if let activeOverride { return activeOverride }
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let parsed = AppLanguage(rawValue: raw) {
            return parsed
        }
        return .system
    }

    /// Concrete bundled language active right now (never `.system`).
    public static var effectiveLanguage: AppLanguage {
        let selected = selectedLanguage
        if selected != .system { return selected }
        return resolveSystemLanguage(preferredLanguages: Locale.preferredLanguages)
    }

    /// Locale matching the active language selection for dates and formatting.
    public static var currentLocale: Locale {
        let selected = selectedLanguage
        if selected == .system {
            return Locale.current
        }
        return Locale(identifier: selected.localeIdentifier)
    }

    /// Updates persisted language preference and notifies UI observers on the main queue.
    public static func setLanguage(_ language: AppLanguage) {
        lock.lock()
        overrideLanguage = nil
        lock.unlock()
        UserDefaults.standard.set(language.rawValue, forKey: storageKey)
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .quickSpotLanguageDidChange, object: language)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .quickSpotLanguageDidChange, object: language)
            }
        }
    }

    /// Resolves the best bundled language from an ordered list of BCP-47 preferred language codes.
    public static func resolveSystemLanguage(preferredLanguages: [String]) -> AppLanguage {
        for identifier in preferredLanguages {
            if let matched = AppLanguage.match(identifier: identifier) {
                return matched
            }
        }
        return .en
    }

    /// Looks up a localized string for the current (or explicitly specified) language, falling back to English.
    public static func tr(_ key: String, language: AppLanguage? = nil) -> String {
        let target: AppLanguage
        if let language {
            target = (language == .system) ? resolveSystemLanguage(preferredLanguages: Locale.preferredLanguages) : language
        } else {
            target = effectiveLanguage
        }
        let code = target.lprojCode ?? "en"
        if let bundle = localizedBundle(for: code) {
            let value = bundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
            if value != "__MISSING__" {
                return value
            }
        }
        if code != "en", let fallback = localizedBundle(for: "en") {
            let value = fallback.localizedString(forKey: key, value: "__MISSING__", table: nil)
            if value != "__MISSING__" {
                return value
            }
        }
        return key
    }

    /// Looks up a localized format string and interpolates `arguments` using the active locale.
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let template = tr(key)
        return String(format: template, locale: currentLocale, arguments: arguments)
    }

    /// Temporarily overrides the active language in-process (intended for deterministic unit tests).
    public static func withLanguage<T>(_ language: AppLanguage, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        let previous = overrideLanguage
        overrideLanguage = language
        lock.unlock()
        defer {
            lock.lock()
            overrideLanguage = previous
            lock.unlock()
        }
        return try body()
    }

    /// Returns the raw key-value dictionary for a bundled `.lproj` code (useful for completeness tests).
    public static func allStrings(for language: AppLanguage) -> [String: String]? {
        guard let code = language.lprojCode,
              let url = resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(code).lproj"),
              let dict = NSDictionary(contentsOf: url) as? [String: String] else {
            return nil
        }
        return dict
    }

    /// Prioritized Apple Vision OCR language list scoped to the user's active & system languages plus English fallback.
    public static func preferredVisionLanguages() -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func append(_ code: String) {
            if seen.insert(code).inserted {
                ordered.append(code)
            }
        }
        append(effectiveLanguage.visionLanguageCode)
        for pref in Locale.preferredLanguages {
            if let matched = AppLanguage.match(identifier: pref) {
                append(matched.visionLanguageCode)
            }
        }
        append("en-US")
        return ordered
    }

    private static func localizedBundle(for code: String) -> Bundle? {
        lock.lock()
        if let cached = bundleCache[code] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved: Bundle?
        if let path = resourceBundle.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            resolved = bundle
        } else {
            resolved = nil
        }

        if let resolved {
            lock.lock()
            bundleCache[code] = resolved
            lock.unlock()
        }
        return resolved
    }
}
