import Accelerate
import Foundation
import ImageIO

/// One image inside a detected near-duplicate cluster with quality metadata to guide safe cleanup.
public struct DuplicateImageItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public let fileName: String
    public let fileSize: Int64
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let mtime: Double
    public let maxSimilarity: Float
    public let isRecommendedKeep: Bool

    public var pixelCount: Int { pixelWidth * pixelHeight }

    public init(
        url: URL,
        fileName: String,
        fileSize: Int64,
        pixelWidth: Int,
        pixelHeight: Int,
        mtime: Double,
        maxSimilarity: Float,
        isRecommendedKeep: Bool
    ) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.fileName = fileName
        self.fileSize = fileSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.mtime = mtime
        self.maxSimilarity = maxSimilarity
        self.isRecommendedKeep = isRecommendedKeep
    }
}

/// Connected cluster of visually near-identical images detected from stored EmbeddingGemma 2 vectors.
public struct NearDuplicateGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let items: [DuplicateImageItem]
    public let averageSimilarity: Float

    public var reclaimableBytes: Int64 {
        items.filter { !$0.isRecommendedKeep }.reduce(0) { $0 + $1.fileSize }
    }

    public init(id: String, items: [DuplicateImageItem], averageSimilarity: Float) {
        self.id = id
        self.items = items
        self.averageSimilarity = averageSimilarity
    }
}

/// Computes pairwise cosine similarity across stored image vectors via tiled `vDSP_mmul` + union-find
/// to detect duplicate, cropped, or recompressed copies without extra ML inference.
public enum SemanticDuplicateFinder {
    public static let defaultThreshold: Float = 0.94
    private static let tileSize = 128

    static func findGroups(
        in store: SemanticVectorStore,
        modelID: String,
        dimension: Int,
        threshold: Float = defaultThreshold,
        maxGroups: Int = 80
    ) -> [NearDuplicateGroup] {
        let clampedThreshold = max(0.75, min(0.999, threshold))
        let snapshot = store.matrixSnapshot(modelID: modelID, dimension: dimension)
        let n = snapshot.rows.count
        let dim = snapshot.dimension
        guard n >= 2, dim > 0, snapshot.data.count == n * dim else { return [] }

        var parent = Array(0..<n)
        var rank = [Int](repeating: 0, count: n)
        var bestSim = [Float](repeating: 0, count: n)
        var pairSimSums: [Int: (sum: Float, count: Int)] = [:]

        func find(_ x: Int) -> Int {
            var cur = x
            while parent[cur] != cur {
                parent[cur] = parent[parent[cur]]
                cur = parent[cur]
            }
            return cur
        }

        func unite(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            guard ra != rb else { return }
            if rank[ra] < rank[rb] {
                parent[ra] = rb
            } else if rank[ra] > rank[rb] {
                parent[rb] = ra
            } else {
                parent[rb] = ra
                rank[ra] += 1
            }
        }

        var transposedB = [Float](repeating: 0, count: dim * tileSize)
        var scores = [Float](repeating: 0, count: tileSize * tileSize)
        var edges: [(i: Int, j: Int, sim: Float)] = []

        snapshot.data.withUnsafeBufferPointer { baseBuf in
            guard let basePtr = baseBuf.baseAddress else { return }
            for i0 in stride(from: 0, to: n, by: tileSize) {
                let rowsI = min(tileSize, n - i0)
                let ptrA = basePtr.advanced(by: i0 * dim)

                for j0 in stride(from: i0, to: n, by: tileSize) {
                    let rowsJ = min(tileSize, n - j0)
                    let ptrB = basePtr.advanced(by: j0 * dim)

                    transposedB.withUnsafeMutableBufferPointer { tBuf in
                        guard let tPtr = tBuf.baseAddress else { return }
                        vDSP_mtrans(ptrB, 1, tPtr, 1, vDSP_Length(dim), vDSP_Length(rowsJ))
                        scores.withUnsafeMutableBufferPointer { cBuf in
                            guard let cPtr = cBuf.baseAddress else { return }
                            vDSP_mmul(
                                ptrA, 1,
                                tPtr, 1,
                                cPtr, 1,
                                vDSP_Length(rowsI),
                                vDSP_Length(rowsJ),
                                vDSP_Length(dim)
                            )
                        }
                    }

                    for r in 0..<rowsI {
                        let startC = (i0 == j0) ? (r + 1) : 0
                        let rowOffset = r * rowsJ
                        for c in startC..<rowsJ {
                            let sim = scores[rowOffset + c]
                            if sim.isFinite && sim >= clampedThreshold {
                                let gi = i0 + r
                                let gj = j0 + c
                                unite(gi, gj)
                                if sim > bestSim[gi] { bestSim[gi] = sim }
                                if sim > bestSim[gj] { bestSim[gj] = sim }
                                edges.append((gi, gj, sim))
                            }
                        }
                    }
                }
            }
        }

        guard !edges.isEmpty else { return [] }

        var membersByRoot: [Int: [Int]] = [:]
        for edge in edges {
            let root = find(edge.i)
            let cur = pairSimSums[root] ?? (0, 0)
            pairSimSums[root] = (cur.sum + edge.sim, cur.count + 1)
        }
        var visited = Set<Int>()
        for edge in edges {
            for idx in [edge.i, edge.j] where visited.insert(idx).inserted {
                membersByRoot[find(idx), default: []].append(idx)
            }
        }

        let fm = FileManager.default
        var groups: [NearDuplicateGroup] = []
        groups.reserveCapacity(min(membersByRoot.count, maxGroups))

        for (root, indices) in membersByRoot {
            guard indices.count >= 2 else { continue }
            var candidates: [(url: URL, name: String, size: Int64, width: Int, height: Int, mtime: Double, sim: Float)] = []
            for idx in indices {
                let row = snapshot.rows[idx]
                guard fm.fileExists(atPath: row.path) else { continue }
                let url = URL(fileURLWithPath: row.path)
                let (size, width, height) = inspectImageStats(url)
                candidates.append((url, row.name, size, width, height, row.mtime, bestSim[idx]))
            }
            guard candidates.count >= 2 else { continue }

            // Rank highest-quality original first: highest pixel count, then largest file size, then oldest mtime.
            candidates.sort { lhs, rhs in
                let lhsPx = lhs.width * lhs.height
                let rhsPx = rhs.width * rhs.height
                if lhsPx != rhsPx { return lhsPx > rhsPx }
                if lhs.size != rhs.size { return lhs.size > rhs.size }
                if lhs.mtime != rhs.mtime { return lhs.mtime < rhs.mtime }
                return lhs.name < rhs.name
            }

            let items = candidates.enumerated().map { idx, c in
                DuplicateImageItem(
                    url: c.url,
                    fileName: c.name,
                    fileSize: c.size,
                    pixelWidth: c.width,
                    pixelHeight: c.height,
                    mtime: c.mtime,
                    maxSimilarity: c.sim,
                    isRecommendedKeep: idx == 0
                )
            }

            let stats = pairSimSums[root] ?? (items.first?.maxSimilarity ?? clampedThreshold, 1)
            let avg = stats.count > 0 ? stats.sum / Float(stats.count) : clampedThreshold
            let groupID = items.map(\.id).sorted().joined(separator: "|")
            groups.append(NearDuplicateGroup(id: groupID, items: items, averageSimilarity: avg))
        }

        return groups
            .sorted { lhs, rhs in
                if lhs.reclaimableBytes != rhs.reclaimableBytes {
                    return lhs.reclaimableBytes > rhs.reclaimableBytes
                }
                if lhs.averageSimilarity != rhs.averageSimilarity {
                    return lhs.averageSimilarity > rhs.averageSimilarity
                }
                return lhs.items.count > rhs.items.count
            }
            .prefix(maxGroups)
            .map { $0 }
    }

    private static func inspectImageStats(_ url: URL) -> (size: Int64, width: Int, height: Int) {
        let vals = try? url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(vals?.fileSize ?? 0)
        var width = 0
        var height = 0
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        }
        return (size, width, height)
    }
}
