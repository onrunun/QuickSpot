import AppKit
import Foundation

/// Fuzzy-matched multilingual macOS system commands and local IP inspection.
public enum SystemCommandAction {
    private struct Definition {
        let id: String
        let titleKey: String
        let subtitleKey: String
        let symbol: String
        let aliases: [String]
        let isDestructive: Bool

        init(
            id: String,
            titleKey: String,
            subtitleKey: String,
            symbol: String,
            aliases: [String],
            isDestructive: Bool = false
        ) {
            self.id = id
            self.titleKey = titleKey
            self.subtitleKey = subtitleKey
            self.symbol = symbol
            self.aliases = aliases
            self.isDestructive = isDestructive
        }
    }

    private static let commands: [Definition] = [
        Definition(
            id: "lock",
            titleKey: "sys.lock.title",
            subtitleKey: "sys.lock.subtitle",
            symbol: "lock.fill",
            aliases: [
                "lock", "lock screen", "kilitle", "ekrani kilitle",
                "sperren", "bildschirm sperren", "bloquear", "bloquear pantalla",
                "verrouiller", "ロック", "画面ロック", "锁屏", "锁定屏幕", "bloquear tela"
            ]
        ),
        Definition(
            id: "sleep",
            titleKey: "sys.sleep.title",
            subtitleKey: "sys.sleep.subtitle",
            symbol: "moon.fill",
            aliases: [
                "sleep", "sleep mac", "uyut", "uyku",
                "ruhezustand", "reposo", "veille", "mettre en veille",
                "スリープ", "睡眠", "休眠", "repouso"
            ]
        ),
        Definition(
            id: "darkmode",
            titleKey: "sys.darkmode.title",
            subtitleKey: "sys.darkmode.subtitle",
            symbol: "circle.lefthalf.filled",
            aliases: [
                "dark mode", "toggle dark mode", "karanlik mod", "tema", "gece modu",
                "dunkelmodus", "modo oscuro", "mode sombre",
                "ダークモード", "深色模式", "暗黑模式", "modo escuro"
            ]
        ),
        Definition(
            id: "trash",
            titleKey: "sys.trash.title",
            subtitleKey: "sys.trash.subtitle",
            symbol: "trash.fill",
            aliases: [
                "empty trash", "copu bosalt", "cop kutusunu bosalt",
                "papierkorb leeren", "vaciar papelera", "vider la corbeille",
                "ゴミ箱を空にする", "清倒废纸篓", "清空废纸篓", "esvaziar lixo"
            ],
            isDestructive: true
        ),
        Definition(
            id: "ip",
            titleKey: "sys.ip.title",
            subtitleKey: "sys.ip.subtitle",
            symbol: "network",
            aliases: [
                "ip", "my ip", "local ip", "ip adresim", "yerel ip",
                "lokale ip", "mi ip", "ip local", "adresse ip", "ローカルip", "本地ip"
            ]
        ),
        Definition(
            id: "restart",
            titleKey: "sys.restart.title",
            subtitleKey: "sys.restart.subtitle",
            symbol: "arrow.clockwise",
            aliases: [
                "restart", "reboot", "yeniden baslat",
                "neustart", "neu starten", "reiniciar", "redemarrer",
                "再起動", "重新启动", "重启"
            ],
            isDestructive: true
        ),
        Definition(
            id: "shutdown",
            titleKey: "sys.shutdown.title",
            subtitleKey: "sys.shutdown.subtitle",
            symbol: "power",
            aliases: [
                "shutdown", "shut down", "bilgisayari kapat", "kapat",
                "ausschalten", "herunterfahren", "apagar", "eteindre",
                "システム終了", "シャットダウン", "关机", "desligar"
            ],
            isDestructive: true
        ),
        Definition(
            id: "settings",
            titleKey: "sys.settings.title",
            subtitleKey: "sys.settings.subtitle",
            symbol: "gearshape.fill",
            aliases: [
                "ayarlar", "settings", "preferences", "indeks", "index", "ocr",
                "einstellungen", "ajustes", "reglages", "設定", "设置", "configuracoes"
            ]
        ),
        Definition(
            id: "mute",
            titleKey: "sys.mute.title",
            subtitleKey: "sys.mute.subtitle",
            symbol: "speaker.slash.fill",
            aliases: [
                "mute", "toggle mute", "sesi kapat", "sessiz", "ses ac",
                "stumm", "stummschalten", "silenciar", "muet", "消音", "ミュート", "静音"
            ]
        ),
        Definition(
            id: "screenshot",
            titleKey: "sys.screenshot.title",
            subtitleKey: "sys.screenshot.subtitle",
            symbol: "camera.viewfinder",
            aliases: [
                "screenshot", "ekran goruntusu", "ss",
                "bildschirmfoto", "captura", "capture", "スクリーンショット", "截图"
            ]
        ),
        Definition(
            id: "caffeinate",
            titleKey: "sys.caffeinate.title",
            subtitleKey: "sys.caffeinate.subtitle",
            symbol: "cup.and.saucer.fill",
            aliases: [
                "caffeinate", "prevent sleep", "keep awake", "uykuyu engelle", "uyanik tut",
                "wach halten", "evitar reposo", "empecher veille", "スリープ防止", "防止睡眠", "evitar repouso"
            ]
        )
    ]

    public static func match(query: String, frecency: FrecencyStore? = nil) -> [SearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        var matches: [SearchItem] = []
        for cmd in commands {
            let bestScore = cmd.aliases.compactMap { FuzzyMatcher.score(query: trimmed, candidate: $0) }.max() ?? 0
            // Require exact, prefix, or word-start prefix match so short substrings never trigger commands.
            guard bestScore >= 700 else { continue }
            if cmd.isDestructive && trimmed.count < 3 && bestScore < 1000 {
                continue
            }

            let calibratedBase: Int
            if bestScore == 1000 {
                calibratedBase = cmd.isDestructive ? 860 : 960
            } else {
                calibratedBase = bestScore - 60
            }

            let itemID = "sys:\(cmd.id)"
            let rawBoost = frecency?.boost(for: itemID, query: trimmed) ?? 0
            let boostCap = cmd.isDestructive ? 40 : 100
            let finalScore = calibratedBase + min(rawBoost, boostCap)

            if cmd.id == "ip" {
                let ip = localIPv4() ?? L10n.tr("sys.ip.not_found")
                matches.append(SearchItem(
                    id: itemID,
                    title: L10n.format("sys.ip.title_value", ip),
                    subtitle: L10n.tr("sys.ip.subtitle_copy"),
                    category: .quickAction,
                    sfSymbol: cmd.symbol,
                    score: finalScore,
                    action: .copyText(ip),
                    matchSource: .quickAction
                ))
            } else if cmd.id == "settings" {
                matches.append(SearchItem(
                    id: itemID,
                    title: L10n.tr(cmd.titleKey),
                    subtitle: L10n.tr(cmd.subtitleKey),
                    category: .quickAction,
                    sfSymbol: cmd.symbol,
                    score: finalScore,
                    action: .openSettings,
                    matchSource: .quickAction
                ))
            } else {
                matches.append(SearchItem(
                    id: itemID,
                    title: L10n.tr(cmd.titleKey),
                    subtitle: L10n.tr(cmd.subtitleKey),
                    category: .quickAction,
                    sfSymbol: cmd.symbol,
                    score: finalScore,
                    action: .systemCommand(cmd.id),
                    matchSource: .quickAction,
                    requiresConfirmation: cmd.isDestructive
                ))
            }
        }
        matches.sort { $0.score > $1.score }
        return matches
    }

    public static func execute(_ commandID: String) {
        SystemCommandExecutor.execute(commandID)
    }

    public static func executeWithError(_ commandID: String) -> String? {
        SystemCommandExecutor.executeWithError(commandID)
    }

    public static func localIPv4() -> String? {
        SystemCommandExecutor.localIPv4()
    }
}
