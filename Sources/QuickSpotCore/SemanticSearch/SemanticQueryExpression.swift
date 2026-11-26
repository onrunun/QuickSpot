import Foundation

/// Parses optional `-excluded` or `-"multi word"` negative terms out of a semantic search query
/// while preserving hyphenated words (`wi-fi`, `e-mail`) and arithmetic expressions (`10 - 5`).
public struct SemanticQueryExpression: Equatable, Sendable {
    public let positiveQuery: String
    public let negativeTerms: [String]

    public var hasNegatives: Bool { !negativeTerms.isEmpty }

    public init(positiveQuery: String, negativeTerms: [String]) {
        self.positiveQuery = positiveQuery
        self.negativeTerms = negativeTerms
    }

    public static func parse(_ raw: String) -> SemanticQueryExpression {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("-") else {
            return SemanticQueryExpression(positiveQuery: trimmed, negativeTerms: [])
        }

        var positives: [String] = []
        var negatives: [String] = []

        var idx = trimmed.startIndex
        while idx < trimmed.endIndex {
            while idx < trimmed.endIndex, trimmed[idx].isWhitespace {
                idx = trimmed.index(after: idx)
            }
            guard idx < trimmed.endIndex else { break }

            if trimmed[idx] == "-" {
                let afterDash = trimmed.index(after: idx)
                if afterDash < trimmed.endIndex, trimmed[afterDash] == "\"" {
                    let phraseStart = trimmed.index(after: afterDash)
                    if let closingQuote = trimmed[phraseStart...].firstIndex(of: "\"") {
                        let phrase = String(trimmed[phraseStart..<closingQuote])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        idx = trimmed.index(after: closingQuote)
                        if Self.isValidNegativeTerm(phrase) {
                            negatives.append(phrase)
                        } else if !phrase.isEmpty {
                            positives.append("-\"\(phrase)\"")
                        }
                        continue
                    }
                }

                var tokenEnd = afterDash
                while tokenEnd < trimmed.endIndex, !trimmed[tokenEnd].isWhitespace {
                    tokenEnd = trimmed.index(after: tokenEnd)
                }
                let candidate = String(trimmed[afterDash..<tokenEnd])
                idx = tokenEnd
                if Self.isValidNegativeTerm(candidate) {
                    negatives.append(candidate)
                } else {
                    positives.append("-" + candidate)
                }
            } else {
                var tokenEnd = idx
                while tokenEnd < trimmed.endIndex, !trimmed[tokenEnd].isWhitespace {
                    tokenEnd = trimmed.index(after: tokenEnd)
                }
                positives.append(String(trimmed[idx..<tokenEnd]))
                idx = tokenEnd
            }
        }

        let positiveJoined = positives.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // If the query had ONLY `-something` with no positive terms, fall back to the raw query unchanged.
        guard !positiveJoined.isEmpty else {
            return SemanticQueryExpression(positiveQuery: trimmed, negativeTerms: [])
        }

        var uniqueNegatives: [String] = []
        var seen = Set<String>()
        for term in negatives {
            let key = term.lowercased()
            if seen.insert(key).inserted {
                uniqueNegatives.append(term)
            }
        }

        return SemanticQueryExpression(positiveQuery: positiveJoined, negativeTerms: uniqueNegatives)
    }

    /// Returns true when `text` (filename or OCR snippet) contains any excluded negative term.
    public func matchesNegativeTerm(in text: String) -> Bool {
        guard !negativeTerms.isEmpty, !text.isEmpty else { return false }
        let folded = VisionTextExtractor.normalizeForSearch(text)
        return negativeTerms.contains { term in
            let needle = VisionTextExtractor.normalizeForSearch(term)
            return needle.count >= 2 && folded.contains(needle)
        }
    }

    private static func isValidNegativeTerm(_ term: String) -> Bool {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2 else { return false }
        return cleaned.contains(where: \.isLetter)
    }
}
