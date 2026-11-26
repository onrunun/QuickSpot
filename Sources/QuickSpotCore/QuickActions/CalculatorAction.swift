import Foundation
import JavaScriptCore

/// Evaluates arithmetic, powers, trig/math functions, and percentage formulas locally via JavaScriptCore.
public enum CalculatorAction {
    private static let mathFuncs = ["sqrt", "sin", "cos", "tan", "log", "abs", "round", "floor", "ceil", "pow"]
    private static let allowedChars = CharacterSet(charactersIn: "0123456789.+-*/()%^, ")
        .union(.letters)

    public static func evaluate(_ raw: String) -> (expression: String, result: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ allowedChars.contains($0) }),
              let jsExpr = prepareJSExpression(trimmed),
              let ctx = JSContext(),
              let val = ctx.evaluateScript(jsExpr),
              val.isNumber else {
            return nil
        }

        let num = val.toDouble()
        guard num.isFinite else { return nil }
        let formatted = formatNumber(num)
        guard formatted != trimmed else { return nil }
        return (trimmed, formatted)
    }

    public static func item(for query: String) -> SearchItem? {
        guard let (expr, result) = evaluate(query) else { return nil }
        return SearchItem(
            id: "calc:\(result)",
            title: "= \(result)",
            subtitle: L10n.format("action.calc.subtitle", expr),
            category: .quickAction,
            sfSymbol: "equal.square.fill",
            score: 1350,
            action: .copyText(result)
        )
    }

    private static func prepareJSExpression(_ input: String) -> String? {
        var expr = input
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "^", with: "**")

        // "20% of 450" (and multilingual prepositions) -> "((20)/100*(450))"
        expr = replacing(
            expr,
            pattern: #"(\d+(?:\.\d+)?)\s*%\s*(?:of|nin|nın|nun|nün|von|de|da|do)?\s*(\d+(?:\.\d+)?)"#,
            template: "(($1)/100.0*($2))"
        )
        // "1500 + 18%" or "1500 - 18%" -> "(1500)*(1+(18)/100.0)"
        expr = replacing(
            expr,
            pattern: #"(\d+(?:\.\d+)?|\([^()]+\))\s*([+-])\s*(\d+(?:\.\d+)?)\s*%"#,
            template: "($1)*(1$2(($3)/100.0))"
        )
        // Standalone "50%" -> "(50/100.0)"
        expr = replacing(expr, pattern: #"(\d+(?:\.\d+)?)\s*%"#, template: "(($1)/100.0)")

        for fn in mathFuncs {
            expr = replacing(expr, pattern: "\\b\(fn)\\s*\\(", template: "Math.\(fn)(")
        }
        expr = replacing(expr, pattern: #"\bpi\b"#, template: "Math.PI")
        expr = replacing(expr, pattern: #"\be\b"#, template: "Math.E")

        // Verify at least one operator or Math function is present so bare numbers aren't evaluated.
        let hasOperator = expr.contains(where: { "+-*/".contains($0) }) || expr.contains("Math.")
        guard hasOperator else { return nil }

        // Reject unknown bare identifiers (everything outside digits/ops and Math.<fn|PI|E>).
        let stripped = replacing(expr, pattern: #"Math\.(?:sqrt|sin|cos|tan|log|abs|round|floor|ceil|pow|PI|E)"#, template: "")
        guard stripped.rangeOfCharacter(from: .letters) == nil else { return nil }
        return expr
    }

    private static func replacing(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func formatNumber(_ value: Double) -> String {
        if abs(value.rounded() - value) < 1e-10, abs(value) < 1e15 {
            return String(Int64(value.rounded()))
        }
        let formatted = String(format: "%.6f", value)
        var s = formatted
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) {
            s.removeLast()
        }
        return s
    }
}
