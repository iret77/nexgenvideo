import Accelerate
import Foundation

enum VisualSearch {
    struct Hit: Equatable, Sendable {
        let assetID: String
        let time: Double
        let shotStart: Double
        let shotEnd: Double
        let score: Float
    }

    /// Top hits across assets, best-per-shot
    static func search(
        query: [Float],
        indexes: [(assetID: String, index: EmbeddingStore.AssetIndex)],
        limit: Int = 20,
        relativeCutoff: Float = 0.85,
        minScore: Float? = nil
    ) -> [Hit] {
        guard !query.isEmpty, query.allSatisfy(\.isFinite), limit > 0,
              relativeCutoff.isFinite, relativeCutoff >= 0,
              minScore?.isFinite != false else { return [] }
        var hits: [Hit] = []
        for (assetID, index) in indexes {
            let dim = index.header.dim
            guard dim == query.count, index.header.count > 0,
                  (try? EmbeddingStore.validate(index)) != nil else { continue }
            var scores = [Float](repeating: 0, count: index.header.count)
            // scores = vectors (count×dim) · query
            cblas_sgemv(
                CblasRowMajor, CblasNoTrans,
                Int32(index.header.count), Int32(dim),
                1, index.vectors, Int32(dim),
                query, 1, 0, &scores, 1
            )
            // Keep only the best frame of each shot so one scene doesn't flood results.
            var bestPerShot: [Double: (row: Int, score: Float)] = [:]
            for (i, score) in scores.enumerated() where score.isFinite {
                let shot = index.rows[i].shotStart
                if let existing = bestPerShot[shot], existing.score >= score { continue }
                bestPerShot[shot] = (i, score)
            }
            for (_, best) in bestPerShot {
                let row = index.rows[best.row]
                hits.append(Hit(
                    assetID: assetID, time: row.time,
                    shotStart: row.shotStart, shotEnd: row.shotEnd,
                    score: best.score
                ))
            }
        }
        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.assetID != $1.assetID { return $0.assetID < $1.assetID }
            return $0.time < $1.time
        }
        if let minScore {
            hits = hits.filter { $0.score >= minScore }
        }
        guard let top = hits.first?.score, top > 0 else { return [] }
        let floor = top * relativeCutoff
        return Array(hits.prefix(limit).filter { $0.score >= floor })
    }
}
