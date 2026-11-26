import Foundation

/// Fast fuzzy matcher with macOS NFD normalization, Turkish folding, multi-token, and camelCase acronym support.
public enum FuzzyMatcher {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private static let foldingMap: [Character: String] = [
        "ı": "i", "İ": "i", "I": "i",
        "ş": "s", "Ş": "s",
        "ğ": "g", "Ğ": "g",
        "ü": "u", "Ü": "u",
        "ö": "o", "Ö": "o",
        "ç": "c", "Ç": "c",
        "ß": "ss", "ẞ": "ss",
        "æ": "ae", "Æ": "ae",
        "œ": "oe", "Œ": "oe",
        "ø": "o", "Ø": "o"
    ]

    private struct WordEntry {
        let text: String
        let offset: Int
    }

    /// Normalizes macOS NFD decomposed filenames, Turkish/European characters, diacritics, and casing consistently.
    public static func normalize(_ text: String) -> String {
        let precomposed = text.precomposedStringWithCanonicalMapping
        var mapped = String()
        mapped.reserveCapacity(precomposed.count)
        for ch in precomposed {
            if let replacement = foldingMap[ch] {
                mapped.append(replacement)
            } else {
                mapped.append(ch)
            }
        }
        return mapped
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: posixLocale)
            .lowercased()
    }

    /// Scores a filename by taking the best match across its extensionless stem and full name.
    public static func scoreFilename(query: String, fileName: String) -> Int? {
        let fullScore = score(query: query, candidate: fileName)
        guard let dotIndex = fileName.lastIndex(of: "."),
              dotIndex > fileName.startIndex,
              fileName.index(after: dotIndex) < fileName.endIndex else {
            return fullScore
        }
        let stem = String(fileName[..<dotIndex])
        let stemScore = score(query: query, candidate: stem)
        switch (stemScore, fullScore) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// Returns a relevance score (higher is better), or nil when `query` does not match `candidate`.
    public static func score(query: String, candidate: String) -> Int? {
        let q = normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let c = normalize(candidate)
        guard !q.isEmpty, !c.isEmpty else { return nil }

        let words = wordTokens(candidate)
        let singleScore = singleQueryScore(query: q, candidate: c, words: words)

        let queryTokens = q.split(whereSeparator: \.isWhitespace).map(String.init)
        guard queryTokens.count >= 2 else { return singleScore }

        let multiScore = multiTokenScore(tokens: queryTokens, candidate: c, words: words)
        switch (singleScore, multiScore) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    private static func singleQueryScore(query q: String, candidate c: String, words: [String]) -> Int? {
        if c == q { return 1000 }
        if c.hasPrefix(q) { return 880 - min(c.count - q.count, 80) }

        if words.contains(where: { $0.hasPrefix(q) }) {
            return 780 - min(c.count - q.count, 60)
        }

        if q.count >= 2 {
            let initials = String(words.compactMap(\.first))
            if initials == q { return 740 }
            if initials.hasPrefix(q) { return 720 }
        }

        if let range = c.range(of: q) {
            let offset = c.distance(from: c.startIndex, to: range.lowerBound)
            return max(480, 560 - min(offset * 4, 80))
        }

        guard q.count >= 2 else { return nil }
        return tightOrderedMatch(query: q, candidate: c)?.score
    }

    private static func multiTokenScore(tokens: [String], candidate c: String, words: [String]) -> Int? {
        let entries = indexedWords(words, in: c)
        var totalScore = 0
        var positions: [Int] = []
        positions.reserveCapacity(tokens.count)

        for token in tokens {
            guard let match = matchSingleToken(token, candidate: c, entries: entries) else {
                return nil
            }
            totalScore += match.score
            positions.append(match.offset)
        }

        let average = totalScore / tokens.count
        let inOrder = zip(positions, positions.dropFirst()).allSatisfy { $0 <= $1 }
        let orderAdjustment = inOrder ? 15 : -25
        let compactQueryLen = tokens.reduce(0) { $0 + $1.count } + (tokens.count - 1)
        let lengthPenalty = min(max(0, c.count - compactQueryLen) / 2, 30)
        return min(870, max(240, average + orderAdjustment - lengthPenalty))
    }

    private static func matchSingleToken(
        _ token: String,
        candidate c: String,
        entries: [WordEntry]
    ) -> (score: Int, offset: Int)? {
        var bestWordMatch: (score: Int, offset: Int)?
        for entry in entries {
            if entry.text == token {
                let candidateMatch = (score: 850, offset: entry.offset)
                if bestWordMatch == nil || candidateMatch.score > bestWordMatch!.score {
                    bestWordMatch = candidateMatch
                }
            } else if entry.text.hasPrefix(token) {
                let prefixScore = 780 - min(entry.text.count - token.count, 40)
                if bestWordMatch == nil || prefixScore > bestWordMatch!.score {
                    bestWordMatch = (score: prefixScore, offset: entry.offset)
                }
            }
        }
        if let bestWordMatch { return bestWordMatch }

        guard token.count >= 2 else { return nil }

        if let range = c.range(of: token) {
            let offset = c.distance(from: c.startIndex, to: range.lowerBound)
            return (score: max(480, 580 - min(offset * 2, 60)), offset: offset)
        }

        return tightOrderedMatch(query: token, candidate: c)
    }

    private static func indexedWords(_ words: [String], in normalizedCandidate: String) -> [WordEntry] {
        var entries: [WordEntry] = []
        entries.reserveCapacity(words.count)
        var searchStart = normalizedCandidate.startIndex
        var charOffset = 0

        for word in words {
            if let range = normalizedCandidate.range(of: word, range: searchStart..<normalizedCandidate.endIndex) {
                charOffset += normalizedCandidate.distance(from: searchStart, to: range.lowerBound)
                entries.append(WordEntry(text: word, offset: charOffset))
                charOffset += normalizedCandidate.distance(from: range.lowerBound, to: range.upperBound)
                searchStart = range.upperBound
            } else {
                entries.append(WordEntry(text: word, offset: charOffset))
            }
        }
        return entries
    }

    private static func wordTokens(_ original: String) -> [String] {
        let precomposed = original.precomposedStringWithCanonicalMapping
        var tokens: [String] = []
        var current = String()
        var prevWasLower = false

        for ch in precomposed {
            if !ch.isLetter && !ch.isNumber {
                if !current.isEmpty {
                    tokens.append(normalize(current))
                    current.removeAll(keepingCapacity: true)
                }
                prevWasLower = false
                continue
            }
            if prevWasLower && ch.isUppercase && !current.isEmpty {
                tokens.append(normalize(current))
                current.removeAll(keepingCapacity: true)
            }
            current.append(ch)
            prevWasLower = ch.isLowercase
        }
        if !current.isEmpty { tokens.append(normalize(current)) }
        return tokens
    }

    private static func tightOrderedMatch(query q: String, candidate c: String) -> (score: Int, offset: Int)? {
        let qChars = Array(q)
        var qi = 0
        var firstPos = -1
        var lastPos = -1

        for (idx, ch) in c.enumerated() {
            if ch == qChars[qi] {
                if firstPos < 0 { firstPos = idx }
                lastPos = idx
                qi += 1
                if qi == qChars.count { break }
            }
        }
        guard qi == qChars.count, firstPos >= 0 else { return nil }
        let span = lastPos - firstPos + 1
        guard span <= qChars.count * 3 + 2 else { return nil }
        let score = max(240, 360 - (span - qChars.count) * 8)
        return (score: score, offset: firstPos)
    }
}
