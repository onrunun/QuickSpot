import Foundation

/// Offline instant converter for HEX/RGB colors, Unix timestamps, and length/mass/data/temperature units.
public enum ConverterAction {
    private static let lengthMeters: [String: Double] = [
        "mm": 0.001, "cm": 0.01, "m": 1.0, "km": 1000.0,
        "in": 0.0254, "inch": 0.0254, "ft": 0.3048, "feet": 0.3048, "yd": 0.9144, "mi": 1609.344, "mile": 1609.344
    ]
    private static let massGrams: [String: Double] = [
        "mg": 0.001, "g": 1.0, "kg": 1000.0, "oz": 28.349523125, "lb": 453.59237, "lbs": 453.59237
    ]
    private static let dataBytes: [String: Double] = [
        "b": 1, "kb": 1024, "mb": 1_048_576, "gb": 1_073_741_824, "tb": 1_099_511_627_776
    ]

    private static let hexRegex = compileRegex(#"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$"#)
    private static let rgbRegex = compileRegex(#"^rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)$"#)
    private static let unitRegex = compileRegex(#"^(-?\d+(?:[.,]\d+)?)\s*([a-zA-Z]+)\s*(?:to|in|zu|en|em|->|=)?\s*([a-zA-Z]+)$"#)
    private static let formatters = FormatterCache()

    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private let dateFormatter: DateFormatter
        private let isoFormatter: ISO8601DateFormatter
        private let numberFormatter: NumberFormatter

        init() {
            let df = DateFormatter()
            df.dateFormat = "dd MMM yyyy HH:mm:ss"
            self.dateFormatter = df

            self.isoFormatter = ISO8601DateFormatter()

            let nf = NumberFormatter()
            nf.locale = Locale(identifier: "en_US_POSIX")
            nf.numberStyle = .decimal
            nf.maximumFractionDigits = 4
            nf.usesGroupingSeparator = false
            self.numberFormatter = nf
        }

        func formatDate(_ date: Date) -> (local: String, iso: String) {
            lock.lock()
            defer { lock.unlock() }
            dateFormatter.locale = L10n.currentLocale
            return (dateFormatter.string(from: date), isoFormatter.string(from: date))
        }

        func formatNumber(_ value: Double) -> String {
            lock.lock()
            defer { lock.unlock() }
            return numberFormatter.string(from: NSNumber(value: value)) ?? String(value)
        }
    }

    public static func item(for query: String) -> SearchItem? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return matchColor(trimmed) ?? matchTimestamp(trimmed) ?? matchUnit(trimmed)
    }

    private static func matchColor(_ raw: String) -> SearchItem? {
        let r: Int; let g: Int; let b: Int
        if let match = firstMatch(hexRegex, in: raw) {
            let hex = match[1]
            let expanded = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
            guard let val = UInt32(expanded, radix: 16) else { return nil }
            r = Int((val >> 16) & 0xFF); g = Int((val >> 8) & 0xFF); b = Int(val & 0xFF)
        } else if let match = firstMatch(rgbRegex, in: raw.lowercased()),
                  let rv = Int(match[1]), let gv = Int(match[2]), let bv = Int(match[3]),
                  rv <= 255, gv <= 255, bv <= 255 {
            r = rv; g = gv; b = bv
        } else {
            return nil
        }

        let hexNoHash = String(format: "%02X%02X%02X", r, g, b)
        let hex = "#\(hexNoHash)"
        let (h, s, l) = rgbToHSL(r: r, g: g, b: b)
        return SearchItem(
            id: "color:\(hexNoHash)",
            title: hex,
            subtitle: "rgb(\(r), \(g), \(b)) · hsl(\(h), \(s)%, \(l)%)",
            category: .quickAction,
            sfSymbol: "paintpalette.fill",
            score: 1380,
            action: .copyText(hex),
            matchSource: .quickAction
        )
    }

    private static func matchTimestamp(_ raw: String) -> SearchItem? {
        guard raw.allSatisfy(\.isNumber), let value = Int64(raw) else { return nil }
        let seconds: TimeInterval
        if raw.count == 10, (1_000_000_000...4_999_999_999).contains(value) {
            seconds = TimeInterval(value)
        } else if raw.count == 13, (1_000_000_000_000...4_999_999_999_999).contains(value) {
            seconds = TimeInterval(value) / 1000.0
        } else {
            return nil
        }
        let date = Date(timeIntervalSince1970: seconds)
        let formatted = formatters.formatDate(date)
        return SearchItem(
            id: "ts:\(raw)",
            title: formatted.local,
            subtitle: L10n.format("action.timestamp.subtitle", formatted.iso),
            category: .quickAction,
            sfSymbol: "clock.fill",
            score: 1340,
            action: .copyText(formatted.iso),
            matchSource: .quickAction
        )
    }

    private static func matchUnit(_ raw: String) -> SearchItem? {
        guard let parts = firstMatch(unitRegex, in: raw),
              let value = Double(parts[1].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let fromRaw = parts[2].lowercased()
        let toRaw = parts[3].lowercased()
        guard fromRaw != toRaw else { return nil }

        let converted: Double?
        if let f = lengthMeters[fromRaw], let t = lengthMeters[toRaw] {
            converted = value * f / t
        } else if let f = massGrams[fromRaw], let t = massGrams[toRaw] {
            converted = value * f / t
        } else if let f = dataBytes[fromRaw], let t = dataBytes[toRaw] {
            converted = value * f / t
        } else {
            converted = convertTemperature(value, from: fromRaw, to: toRaw)
        }
        guard let result = converted, result.isFinite else { return nil }

        let formatted = formatters.formatNumber(result)
        return SearchItem(
            id: "unit:\(formatted)",
            title: "= \(formatted) \(parts[3])",
            subtitle: L10n.format("action.convert.subtitle", raw),
            category: .quickAction,
            sfSymbol: "arrow.left.arrow.right.square.fill",
            score: 1360,
            action: .copyText(formatted),
            matchSource: .quickAction
        )
    }

    private static func convertTemperature(_ value: Double, from: String, to: String) -> Double? {
        func norm(_ u: String) -> String? {
            if u == "c" || u == "celsius" { return "c" }
            if u == "f" || u == "fahrenheit" { return "f" }
            if u == "k" || u == "kelvin" { return "k" }
            return nil
        }
        guard let f = norm(from), let t = norm(to), f != t else { return nil }
        let celsius: Double = f == "c" ? value : (f == "f" ? (value - 32) * 5 / 9 : value - 273.15)
        return t == "c" ? celsius : (t == "f" ? celsius * 9 / 5 + 32 : celsius + 273.15)
    }

    private static func rgbToHSL(r: Int, g: Int, b: Int) -> (Int, Int, Int) {
        let rf = Double(r) / 255.0, gf = Double(g) / 255.0, bf = Double(b) / 255.0
        let maxC = max(rf, gf, bf), minC = min(rf, gf, bf), delta = maxC - minC, l = (maxC + minC) / 2.0
        guard delta > 0 else { return (0, 0, Int((l * 100).rounded())) }
        let s = l > 0.5 ? delta / (2.0 - maxC - minC) : delta / (maxC + minC)
        var h: Double = maxC == rf ? ((gf - bf) / delta).truncatingRemainder(dividingBy: 6)
            : (maxC == gf ? (bf - rf) / delta + 2 : (rf - gf) / delta + 4)
        h *= 60; if h < 0 { h += 360 }
        return (Int(h.rounded()), Int((s * 100).rounded()), Int((l * 100).rounded()))
    }

    private static func compileRegex(_ pattern: String) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            assertionFailure("Invalid ConverterAction regex \(pattern): \(error)")
            return nil
        }
    }

    private static func firstMatch(_ regex: NSRegularExpression?, in text: String) -> [String]? {
        guard let regex,
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
