import Accelerate
import Foundation
import os
import SQLite3

/// Single vector row prepared for batched transactional persistence in `SemanticVectorStore`.
public struct SemanticVectorUpsert: Sendable {
    public let path: String
    public let name: String
    public let mtime: Double
    public let size: Int64
    public let modelID: String
    public let vector: [Float]

    public init(path: String, name: String, mtime: Double, size: Int64, modelID: String, vector: [Float]) {
        self.path = path
        self.name = name
        self.mtime = mtime
        self.size = size
        self.modelID = modelID
        self.vector = vector
    }
}

/// SQLite-persisted vector store with an incrementally maintained Float32 matrix for sub-millisecond vDSP search.
public final class SemanticVectorStore: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.quickspot.core", category: "SemanticVectorStore")

    public static let statusIndexed = 1
    public static let statusFailed = 2
    public static let maxFailureRetries = 2

    struct RowMeta {
        let path: String
        let name: String
        let mtime: Double
    }

    let lock = NSLock()
    var db: OpaquePointer?

    var matrixDirty = true
    var hubnessDirty = true
    var matrixModelID: String = ""
    var matrixDimension: Int = 0
    var matrixData: [Float] = []
    var hubnessAdjustment: [Float] = []
    var rowMeta: [RowMeta] = []
    var pathToRowIndex: [String: Int] = [:]

    /// Centroid-based hubness reduction strength (CSLS-style) applied when corpus >= 20 images.
    static let hubnessAlpha: Float = 0.50
    static let minCorpusForHubness = 20

    public init(databaseURL: URL? = nil) {
        let targetURL = databaseURL ?? Self.defaultDatabaseURL()
        let isMemory = targetURL.path == ":memory:"
        if !isMemory {
            do {
                try FileManager.default.createDirectory(
                    at: targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                Self.logger.error("Failed to create semantic DB directory: \(error.localizedDescription, privacy: .public)")
            }
        }

        var handle: OpaquePointer?
        let path = isMemory ? ":memory:" : targetURL.path
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle {
            db = handle
            sqlite3_busy_timeout(handle, 3000)
            if !isMemory { exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;") }
            exec("""
            CREATE TABLE IF NOT EXISTS image_embeddings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT UNIQUE NOT NULL,
                name TEXT NOT NULL,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                model_id TEXT NOT NULL,
                dim INTEGER NOT NULL,
                vector BLOB NOT NULL,
                status INTEGER NOT NULL DEFAULT 1,
                retry_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_image_embeddings_model ON image_embeddings(model_id);
            """)
            migrateSchemaIfNeeded()
        } else {
            Self.logger.error("Failed to open semantic SQLite database")
            sqlite3_close(handle)
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("QuickSpot/image-embeddings.sqlite")
    }

    public func upsert(
        path: String,
        name: String,
        mtime: Double,
        size: Int64,
        modelID: String,
        vector: [Float]
    ) {
        upsertBatch([
            SemanticVectorUpsert(path: path, name: name, mtime: mtime, size: size, modelID: modelID, vector: vector)
        ])
    }

    /// Persists a GPU batch in a single SQLite transaction and updates the in-memory matrix incrementally without a full reload.
    public func upsertBatch(_ items: [SemanticVectorUpsert]) {
        let valid = items.filter { !$0.vector.isEmpty }
        guard !valid.isEmpty else { return }

        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        guard exec("BEGIN IMMEDIATE;") else { return }

        let sql = """
        INSERT INTO image_embeddings (path, name, mtime, size, model_id, dim, vector, status, retry_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0)
        ON CONFLICT(path) DO UPDATE SET
            name = excluded.name,
            mtime = excluded.mtime,
            size = excluded.size,
            model_id = excluded.model_id,
            dim = excluded.dim,
            vector = excluded.vector,
            status = 1,
            retry_count = 0;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            exec("ROLLBACK;")
            return
        }
        defer { sqlite3_finalize(stmt) }

        var succeeded: [SemanticVectorUpsert] = []
        succeeded.reserveCapacity(valid.count)
        for item in valid {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, item.path)
            bindText(stmt, 2, item.name)
            sqlite3_bind_double(stmt, 3, item.mtime)
            sqlite3_bind_int64(stmt, 4, item.size)
            bindText(stmt, 5, item.modelID)
            sqlite3_bind_int64(stmt, 6, Int64(item.vector.count))
            _ = item.vector.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 7, raw.baseAddress, Int32(raw.count), semanticSQLiteTransient)
            }
            if sqlite3_step(stmt) == SQLITE_DONE {
                succeeded.append(item)
            }
        }
        guard exec("COMMIT;") else { return }

        applyIncrementalMatrixUpsertsLocked(succeeded)
    }

    /// Computes cosine similarity against all stored vectors for `modelID` using `vDSP_mmul`.
    public func search(
        queryVector: [Float],
        modelID: String,
        limit: Int = 12,
        minSimilarity: Float = -1.0
    ) -> [SemanticVectorHit] {
        searchWithStats(queryVector: queryVector, modelID: modelID, limit: limit, minSimilarity: minSimilarity).hits
    }

    /// Computes cosine similarity plus corpus mean/stdDev using `vDSP_mmul` (with optional centroid hubness reduction and self-exclusion).
    public func searchWithStats(
        queryVector: [Float],
        modelID: String,
        limit: Int = 12,
        minSimilarity: Float = -1.0,
        excludePath: String? = nil,
        applyHubness: Bool = true
    ) -> SemanticVectorSearchResult {
        searchWithStats(
            queryVectors: [queryVector],
            modelID: modelID,
            limit: limit,
            minSimilarity: minSimilarity,
            excludePath: excludePath,
            applyHubness: applyHubness
        )
    }

    /// Computes elementwise max similarity across 1+ query variants (e.g. raw + diacritic-restored Turkish) with optional hubness & negative concept damping.
    public func searchWithStats(
        queryVectors: [[Float]],
        negativeVectors: [[Float]] = [],
        modelID: String,
        limit: Int = 12,
        minSimilarity: Float = -1.0,
        excludePath: String? = nil,
        applyHubness: Bool = true
    ) -> SemanticVectorSearchResult {
        guard let firstVec = queryVectors.first, !firstVec.isEmpty, limit > 0 else {
            return SemanticVectorSearchResult(hits: [], corpusCount: 0, mean: 0, stdDev: 0)
        }
        let dim = firstVec.count
        guard queryVectors.allSatisfy({ $0.count == dim }) else {
            return SemanticVectorSearchResult(hits: [], corpusCount: 0, mean: 0, stdDev: 0)
        }
        let validNegatives = negativeVectors.filter { $0.count == dim }

        lock.lock(); defer { lock.unlock() }
        reloadMatrixIfNeeded(modelID: modelID, dimension: dim)
        if applyHubness && hubnessDirty {
            computeHubnessAdjustmentIfNeeded()
            hubnessDirty = false
        }

        let rowCount = rowMeta.count
        guard rowCount > 0, matrixDimension == dim else {
            return SemanticVectorSearchResult(hits: [], corpusCount: 0, mean: 0, stdDev: 0)
        }

        var scores = [Float](repeating: -Float.greatestFiniteMagnitude, count: rowCount)
        var scratch = [Float](repeating: 0, count: rowCount)

        for queryVector in queryVectors {
            matrixData.withUnsafeBufferPointer { mBuf in
                queryVector.withUnsafeBufferPointer { qBuf in
                    scratch.withUnsafeMutableBufferPointer { sBuf in
                        guard let mPtr = mBuf.baseAddress,
                              let qPtr = qBuf.baseAddress,
                              let sPtr = sBuf.baseAddress else { return }
                        vDSP_mmul(
                            mPtr, 1,
                            qPtr, 1,
                            sPtr, 1,
                            vDSP_Length(rowCount),
                            1,
                            vDSP_Length(matrixDimension)
                        )
                    }
                }
            }
            if queryVectors.count == 1 {
                scores = scratch
            } else {
                vDSP_vmax(scores, 1, scratch, 1, &scores, 1, vDSP_Length(rowCount))
            }
        }

        if applyHubness && hubnessAdjustment.count == rowCount {
            vDSP_vadd(scores, 1, hubnessAdjustment, 1, &scores, 1, vDSP_Length(rowCount))
        }

        if !validNegatives.isEmpty {
            var negScores = [Float](repeating: -Float.greatestFiniteMagnitude, count: rowCount)
            for negVector in validNegatives {
                matrixData.withUnsafeBufferPointer { mBuf in
                    negVector.withUnsafeBufferPointer { qBuf in
                        scratch.withUnsafeMutableBufferPointer { sBuf in
                            guard let mPtr = mBuf.baseAddress,
                                  let qPtr = qBuf.baseAddress,
                                  let sPtr = sBuf.baseAddress else { return }
                            vDSP_mmul(
                                mPtr, 1,
                                qPtr, 1,
                                sPtr, 1,
                                vDSP_Length(rowCount),
                                1,
                                vDSP_Length(matrixDimension)
                            )
                        }
                    }
                }
                if validNegatives.count == 1 {
                    negScores = scratch
                } else {
                    vDSP_vmax(negScores, 1, scratch, 1, &negScores, 1, vDSP_Length(rowCount))
                }
            }
            if applyHubness && hubnessAdjustment.count == rowCount {
                vDSP_vadd(negScores, 1, hubnessAdjustment, 1, &negScores, 1, vDSP_Length(rowCount))
            }
            var negMean: Float = 0
            vDSP_meanv(negScores, 1, &negMean, vDSP_Length(rowCount))
            let baseline = max(Float(0), negMean)
            for i in 0..<rowCount {
                let pos = scores[i]
                let neg = negScores[i]
                guard pos.isFinite, neg.isFinite else { continue }
                let excess = max(Float(0), neg - baseline)
                var adjusted = pos - 0.55 * excess
                if neg >= pos - 0.01 && excess > 0.05 {
                    adjusted -= 0.08
                }
                scores[i] = adjusted
            }
        }

        let excludedPath = excludePath.map { ($0 as NSString).standardizingPath }
        let excludedIndex = excludedPath.flatMap { pathToRowIndex[$0] }

        var sum: Float = 0
        var includedCount = 0
        for i in 0..<rowCount where i != excludedIndex {
            let s = scores[i]
            if s.isFinite {
                sum += s
                includedCount += 1
            }
        }
        guard includedCount > 0 else {
            return SemanticVectorSearchResult(hits: [], corpusCount: 0, mean: 0, stdDev: 0)
        }

        let mean = sum / Float(includedCount)
        var stdDev: Float = 0
        if includedCount >= 2 {
            var sumSq: Float = 0
            for i in 0..<rowCount where i != excludedIndex {
                let s = scores[i]
                if s.isFinite {
                    let d = s - mean
                    sumSq += d * d
                }
            }
            stdDev = sqrt(sumSq / Float(includedCount))
        }
        let safeStd = max(stdDev, 0.012)

        var candidates: [(idx: Int, score: Float)] = []
        candidates.reserveCapacity(min(includedCount, limit * 3))
        for i in 0..<rowCount where i != excludedIndex {
            let s = scores[i]
            if s.isFinite && s >= minSimilarity {
                candidates.append((i, s))
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return rowMeta[lhs.idx].mtime > rowMeta[rhs.idx].mtime
        }

        let hits = candidates.prefix(limit).map { entry in
            let meta = rowMeta[entry.idx]
            let z = (entry.score - mean) / safeStd
            return SemanticVectorHit(
                path: meta.path,
                fileName: meta.name,
                similarity: entry.score,
                zScore: z,
                mtime: meta.mtime
            )
        }
        return SemanticVectorSearchResult(hits: hits, corpusCount: includedCount, mean: mean, stdDev: stdDev)
    }
}
