import Foundation

/// Persists time-decayed frecency records and query-to-item affinity bindings in UserDefaults.
public final class FrecencyStore: @unchecked Sendable {
    private struct UsageRecord: Codable {
        var count: Int
        var decayedScore: Double
        var lastUsed: TimeInterval
    }

    private struct AffinityRecord: Codable {
        var itemID: String
        var count: Int
        var decayedScore: Double
        var lastUsed: TimeInterval
    }

    private struct StoragePayload: Codable {
        var version: Int
        var items: [String: UsageRecord]
        var affinities: [String: AffinityRecord]
    }

    private static let halfLifeSeconds: TimeInterval = 14.0 * 86_400.0
    private static let maxItemRecords = 500
    private static let maxAffinityRecords = 200
    private static let maxFrecencyBoost = 160.0
    private static let maxAffinityBoost = 220.0

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey = "QuickSpot.frecency"
    private var items: [String: UsageRecord] = [:]
    private var affinities: [String: AffinityRecord] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let now = Date().timeIntervalSince1970

        if let data = defaults.data(forKey: storageKey),
           let payload = try? JSONDecoder().decode(StoragePayload.self, from: data) {
            self.items = payload.items
            self.affinities = payload.affinities
        } else if let legacy = defaults.dictionary(forKey: storageKey) as? [String: Int] {
            var migrated: [String: UsageRecord] = [:]
            migrated.reserveCapacity(legacy.count)
            for (id, count) in legacy where count > 0 {
                migrated[id] = UsageRecord(count: count, decayedScore: Double(count), lastUsed: now)
            }
            self.items = migrated
            if !migrated.isEmpty {
                persistLocked()
            }
        }
    }

    /// Computes combined decayed frecency boost (up to 160) plus optional query-affinity bonus (up to 220).
    public func boost(for id: String, query: String? = nil) -> Int {
        let now = Date().timeIntervalSince1970
        let normalizedQuery = query.map {
            FuzzyMatcher.normalize($0).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""

        lock.lock()
        let itemRecord = items[id]
        let affinityBonus = affinityBoostLocked(for: id, normalizedQuery: normalizedQuery, now: now)
        lock.unlock()

        let frecencyBonus: Int
        if let record = itemRecord {
            let eff = decayedValue(record.decayedScore, lastUsed: record.lastUsed, now: now)
            frecencyBonus = Int(min(Self.maxFrecencyBoost, (log2(1.0 + eff) * 38.0).rounded()))
        } else {
            frecencyBonus = 0
        }

        return frecencyBonus + affinityBonus
    }

    /// Records a launch or selection for `id` and optionally binds it to `query`.
    public func record(id: String, query: String? = nil) {
        guard !id.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let normalizedQuery = query.map {
            FuzzyMatcher.normalize($0).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""

        lock.lock()
        if var existing = items[id] {
            let eff = decayedValue(existing.decayedScore, lastUsed: existing.lastUsed, now: now)
            existing.count += 1
            existing.decayedScore = eff + 1.0
            existing.lastUsed = now
            items[id] = existing
        } else {
            items[id] = UsageRecord(count: 1, decayedScore: 1.0, lastUsed: now)
        }

        if !normalizedQuery.isEmpty {
            if var existing = affinities[normalizedQuery], existing.itemID == id {
                let eff = decayedValue(existing.decayedScore, lastUsed: existing.lastUsed, now: now)
                existing.count += 1
                existing.decayedScore = eff + 1.0
                existing.lastUsed = now
                affinities[normalizedQuery] = existing
            } else {
                affinities[normalizedQuery] = AffinityRecord(
                    itemID: id,
                    count: 1,
                    decayedScore: 1.0,
                    lastUsed: now
                )
            }
        }

        pruneIfNeededLocked(now: now)
        let data = encodePayloadLocked()
        lock.unlock()

        if let data {
            defaults.set(data, forKey: storageKey)
        }
    }

    /// Returns top item IDs ordered by decayed frecency score, tie-breaking alphabetically.
    public func topIDs(limit: Int = 6) -> [String] {
        guard limit > 0 else { return [] }
        let now = Date().timeIntervalSince1970
        lock.lock()
        let snapshot = items
        lock.unlock()

        return rankedIDs(from: snapshot, now: now, limit: limit) { _ in true }
    }

    /// Returns top recently/frequently used non-app filesystem paths.
    public func topFileIDs(limit: Int = 8) -> [String] {
        guard limit > 0 else { return [] }
        let now = Date().timeIntervalSince1970
        lock.lock()
        let snapshot = items
        lock.unlock()

        return rankedIDs(from: snapshot, now: now, limit: limit) { id in
            id.hasPrefix("/") && !id.lowercased().hasSuffix(".app")
        }
    }

    private func rankedIDs(
        from snapshot: [String: UsageRecord],
        now: TimeInterval,
        limit: Int,
        predicate: (String) -> Bool
    ) -> [String] {
        let scored: [(id: String, score: Double)] = snapshot.compactMap { id, record in
            guard predicate(id), record.count > 0 else { return nil }
            let eff = decayedValue(record.decayedScore, lastUsed: record.lastUsed, now: now)
            guard eff > 0 else { return nil }
            return (id: id, score: eff)
        }
        return scored
            .sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) < 1e-6 {
                    return lhs.id < rhs.id
                }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map(\.id)
    }

    private func affinityBoostLocked(for id: String, normalizedQuery: String, now: TimeInterval) -> Int {
        guard !normalizedQuery.isEmpty else { return 0 }

        var bestBonus = 0.0

        if let exact = affinities[normalizedQuery], exact.itemID == id {
            let eff = decayedValue(exact.decayedScore, lastUsed: exact.lastUsed, now: now)
            bestBonus = max(bestBonus, rawAffinityBoost(for: eff))
        }

        guard normalizedQuery.count >= 2 else {
            return Int(bestBonus.rounded())
        }

        for (bindingQuery, record) in affinities where record.itemID == id && bindingQuery != normalizedQuery {
            guard bindingQuery.count >= 2 else { continue }
            let eff = decayedValue(record.decayedScore, lastUsed: record.lastUsed, now: now)
            let base = rawAffinityBoost(for: eff)
            if normalizedQuery.hasPrefix(bindingQuery) {
                let coverage = min(1.0, Double(bindingQuery.count) / Double(normalizedQuery.count))
                let scaled = base * (0.65 + 0.20 * coverage)
                bestBonus = max(bestBonus, scaled)
            } else if bindingQuery.hasPrefix(normalizedQuery) {
                let coverage = min(1.0, Double(normalizedQuery.count) / Double(bindingQuery.count))
                let scaled = base * (0.45 + 0.25 * coverage)
                bestBonus = max(bestBonus, scaled)
            }
        }

        return Int(min(Self.maxAffinityBoost, bestBonus).rounded())
    }

    private func rawAffinityBoost(for effectiveScore: Double) -> Double {
        guard effectiveScore > 0 else { return 0 }
        return min(Self.maxAffinityBoost, (effectiveScore / (effectiveScore + 0.5)) * 235.0)
    }

    private func decayedValue(_ value: Double, lastUsed: TimeInterval, now: TimeInterval) -> Double {
        let age = max(0, now - lastUsed)
        return value * pow(0.5, age / Self.halfLifeSeconds)
    }

    private func pruneIfNeededLocked(now: TimeInterval) {
        if items.count > Self.maxItemRecords {
            let sorted = items.sorted { lhs, rhs in
                let ls = decayedValue(lhs.value.decayedScore, lastUsed: lhs.value.lastUsed, now: now)
                let rs = decayedValue(rhs.value.decayedScore, lastUsed: rhs.value.lastUsed, now: now)
                return ls == rs ? lhs.value.lastUsed > rhs.value.lastUsed : ls > rs
            }
            items = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maxItemRecords).map { ($0.key, $0.value) })
        }

        if affinities.count > Self.maxAffinityRecords {
            let sorted = affinities.sorted { lhs, rhs in
                let ls = decayedValue(lhs.value.decayedScore, lastUsed: lhs.value.lastUsed, now: now)
                let rs = decayedValue(rhs.value.decayedScore, lastUsed: rhs.value.lastUsed, now: now)
                return ls == rs ? lhs.value.lastUsed > rhs.value.lastUsed : ls > rs
            }
            affinities = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maxAffinityRecords).map { ($0.key, $0.value) })
        }
    }

    private func encodePayloadLocked() -> Data? {
        let payload = StoragePayload(version: 2, items: items, affinities: affinities)
        return try? JSONEncoder().encode(payload)
    }

    private func persistLocked() {
        if let data = encodePayloadLocked() {
            defaults.set(data, forKey: storageKey)
        }
    }
}
