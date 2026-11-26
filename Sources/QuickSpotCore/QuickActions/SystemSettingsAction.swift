import Foundation

/// Zero-overhead deep links into native macOS System Settings panes with multilingual fuzzy aliases.
public enum SystemSettingsAction {
    public struct Pane: Equatable, Sendable {
        public let id: String
        public let symbol: String
        public let urlString: String
        public let aliases: [String]

        public var title: String { L10n.tr("pref.\(id).title") }
        public var subtitle: String { L10n.tr("pref.\(id).subtitle") }
    }

    public static let panes: [Pane] = [
        Pane(
            id: "wifi",
            symbol: "wifi",
            urlString: "x-apple.systempreferences:com.apple.wifi-settings-extension",
            aliases: ["wifi", "wi-fi", "wlan", "kablosuz", "wireless", "internet", "无线局域网"]
        ),
        Pane(
            id: "bluetooth",
            symbol: "dot.radiowaves.left.and.right",
            urlString: "x-apple.systempreferences:com.apple.BluetoothSettings",
            aliases: ["bluetooth", "bt", "kulaklik", "airpods", "蓝牙", "ブルートゥース"]
        ),
        Pane(
            id: "network",
            symbol: "network",
            urlString: "x-apple.systempreferences:com.apple.Network-Settings.extension",
            aliases: ["network", "ag ayarlari", "netzwerk", "red", "reseau", "rede", "vpn", "ethernet", "dns", "ネットワーク", "网络"]
        ),
        Pane(
            id: "sound",
            symbol: "speaker.wave.2.fill",
            urlString: "x-apple.systempreferences:com.apple.Sound-Settings.extension",
            aliases: ["sound", "audio", "ses", "ses ayarlari", "mikrofon", "hoparlor", "ton", "sonido", "son", "som", "サウンド", "声音"]
        ),
        Pane(
            id: "displays",
            symbol: "display",
            urlString: "x-apple.systempreferences:com.apple.Displays-Settings.extension",
            aliases: ["display", "displays", "ekran", "ekranlar", "monitor", "cozunurluk", "parlaklik", "bildschirm", "pantalla", "moniteurs", "tela", "ディスプレイ", "显示器"]
        ),
        Pane(
            id: "battery",
            symbol: "battery.75percent",
            urlString: "x-apple.systempreferences:com.apple.Battery-Settings.extension",
            aliases: ["battery", "pil", "batarya", "guc", "power", "sarj", "batterie", "akku", "bateria", "バッテリー", "电池"]
        ),
        Pane(
            id: "privacy",
            symbol: "hand.raised.fill",
            urlString: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            aliases: ["privacy", "security", "gizlilik", "guvenlik", "izinler", "accessibility permission", "otomasyon", "datenschutz", "privacidad", "confidentialite", "privacidade", "プライバシー", "隐私"]
        ),
        Pane(
            id: "keyboard",
            symbol: "keyboard",
            urlString: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            aliases: ["keyboard", "klavye", "kisayol", "shortcuts", "tastatur", "teclado", "clavier", "キーボード", "键盘"]
        ),
        Pane(
            id: "trackpad",
            symbol: "rectangle.and.hand.point.up.left.filled",
            urlString: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
            aliases: ["trackpad", "izleme dortgeni", "touchpad", "トラックパッド", "触控板"]
        ),
        Pane(
            id: "mouse",
            symbol: "computermouse.fill",
            urlString: "x-apple.systempreferences:com.apple.Mouse-Settings.extension",
            aliases: ["mouse", "fare", "maus", "raton", "souris", "マウス", "鼠标"]
        ),
        Pane(
            id: "notifications",
            symbol: "bell.badge.fill",
            urlString: "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            aliases: ["notifications", "bildirim", "bildirimler", "mitteilungen", "notificaciones", "notificacoes", "通知"]
        ),
        Pane(
            id: "appearance",
            symbol: "paintbrush.fill",
            urlString: "x-apple.systempreferences:com.apple.Appearance-Settings.extension",
            aliases: ["appearance", "gorunum", "acik mod", "koyu mod", "erscheinungsbild", "aspecto", "apparence", "aparencia", "外観", "外观"]
        ),
        Pane(
            id: "desktop-dock",
            symbol: "dock.rectangle",
            urlString: "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
            aliases: ["dock", "masaustu ve dock", "desktop and dock", "stage manager", "schreibtisch", "escritorio", "bureau", "デスクトップ", "程序坞"]
        ),
        Pane(
            id: "control-center",
            symbol: "switch.2",
            urlString: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension",
            aliases: ["control center", "denetim merkezi", "menu bar", "menu cubugu", "kontrollzentrum", "centro de control", "centre de controle", "コントロールセンター", "控制中心"]
        ),
        Pane(
            id: "wallpaper",
            symbol: "photo.fill",
            urlString: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension",
            aliases: ["wallpaper", "duvar kagidi", "arka plan", "hintergrundbild", "fondo de pantalla", "fond d ecran", "壁紙", "墙纸"]
        ),
        Pane(
            id: "lock-screen",
            symbol: "lock.rectangle.fill",
            urlString: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension",
            aliases: ["lock screen settings", "kilit ekrani", "sperrbildschirm", "pantalla de bloqueo", "ecran verrouille", "ロック画面", "锁定屏幕"]
        ),
        Pane(
            id: "touch-id",
            symbol: "touchid",
            urlString: "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension",
            aliases: ["touch id", "touchid", "parmak izi", "parola", "passwort", "contrasena", "mot de passe", "senha", "パスワード", "触控id"]
        ),
        Pane(
            id: "general",
            symbol: "gearshape.fill",
            urlString: "x-apple.systempreferences:com.apple.systempreferences.GeneralSettings",
            aliases: ["general", "genel ayarlar", "hakkinda", "about mac", "allgemein", "geral", "一般", "通用"]
        ),
        Pane(
            id: "software-update",
            symbol: "arrow.triangle.2.circlepath",
            urlString: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
            aliases: ["software update", "update", "guncelleme", "yazilim guncelleme", "softwareupdate", "actualizacion", "mise a jour", "atualizacao", "ソフトウェアアップデート", "软件更新"]
        ),
        Pane(
            id: "storage",
            symbol: "internaldrive.fill",
            urlString: "x-apple.systempreferences:com.apple.settings.Storage",
            aliases: ["storage", "depolama", "disk alani", "speicher", "almacenamiento", "stockage", "armazenamento", "ストレージ", "储存空间", "存储"]
        ),
        Pane(
            id: "login-items",
            symbol: "person.badge.key.fill",
            urlString: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            aliases: ["login items", "oturum acma", "baslangic uygulamalari", "startup", "anmeldeobjekte", "items de inicio", "ログイン項目", "登录项"]
        ),
        Pane(
            id: "printers",
            symbol: "printer.fill",
            urlString: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension",
            aliases: ["printer", "printers", "yazici", "yazicilar", "tarayici", "drucker", "impresoras", "imprimantes", "impressoras", "プリンタ", "打印机"]
        ),
        Pane(
            id: "users",
            symbol: "person.2.fill",
            urlString: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension",
            aliases: ["users", "kullanicilar", "hesaplar", "benutzer", "usuarios", "utilisateurs", "ユーザ", "用户"]
        ),
        Pane(
            id: "accessibility",
            symbol: "accessibility",
            urlString: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
            aliases: ["accessibility", "erisilebilirlik", "bedienungshilfen", "accesibilidad", "accessibilite", "acessibilidade", "アクセシビリティ", "辅助功能"]
        ),
        Pane(
            id: "sharing",
            symbol: "folder.badge.person.crop",
            urlString: "x-apple.systempreferences:com.apple.Sharing-Settings.extension",
            aliases: ["sharing", "paylasma", "dosya paylasimi", "ssh", "teilen", "compartir", "partage", "compartilhamento", "共有", "共享"]
        ),
        Pane(
            id: "date-time",
            symbol: "clock.fill",
            urlString: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension",
            aliases: ["date and time", "tarih ve saat", "saat dilimi", "timezone", "datum", "fecha y hora", "date et heure", "data e hora", "日付と時刻", "日期与时间"]
        ),
        Pane(
            id: "time-machine",
            symbol: "clock.arrow.circlepath",
            urlString: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension",
            aliases: ["time machine", "yedekleme", "backup", "copia de seguridad", "sauvegarde", "バックアップ", "时间机器"]
        )
    ]

    public static func match(query: String, frecency: FrecencyStore? = nil) -> [SearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        var matches: [SearchItem] = []
        for pane in panes {
            let localizedTitle = pane.title
            let candidates = pane.aliases + [localizedTitle]
            let bestScore = candidates.compactMap { FuzzyMatcher.score(query: trimmed, candidate: $0) }.max() ?? 0
            guard bestScore >= 720, let url = URL(string: pane.urlString) else { continue }

            let itemID = "pref:\(pane.id)"
            let baseScore = bestScore == 1000 ? 910 : (bestScore - 70)
            let boost = min(frecency?.boost(for: itemID, query: trimmed) ?? 0, 80)
            matches.append(SearchItem(
                id: itemID,
                title: localizedTitle,
                subtitle: pane.subtitle,
                category: .quickAction,
                sfSymbol: pane.symbol,
                score: min(baseScore + boost, 950),
                action: .openURL(url),
                matchSource: .quickAction
            ))
        }

        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return Array(matches.prefix(4))
    }
}
