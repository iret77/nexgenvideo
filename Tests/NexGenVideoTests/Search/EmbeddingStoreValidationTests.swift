import Foundation
import Testing
@testable import NexGenVideo

@Suite("Embedding cache rejects corrupt sizes before allocation")
struct EmbeddingStoreValidationTests {
    private func raw(_ header: EmbeddingStore.Header, payload: Data = Data()) throws -> Data {
        let json = try JSONEncoder().encode(header)
        var data = Data("PALMEMB1".utf8)
        var length = UInt32(json.count).littleEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(json)
        data.append(payload)
        return data
    }

    @Test func negativeAndOverflowingHeadersDoNotTrapOrCountAsCurrent() throws {
        let key = "validation-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key)) }
        try FileManager.default.createDirectory(at: EmbeddingStore.directory, withIntermediateDirectories: true)
        for (dim, count) in [(Int.max, 1), (1, Int.max), (-1, 1), (1, -1), (0, 1)] {
            let header = EmbeddingStore.Header(model: "fixture", modelVersion: 1, samplerVersion: 1, dim: dim, count: count)
            try raw(header).write(to: EmbeddingStore.diskURL(key), options: .atomic)
            #expect(EmbeddingStore.header(key: key) == nil)
            #expect(!EmbeddingStore.isCurrent(key: key, model: "fixture", modelVersion: 1, samplerVersion: 1))
            #expect(throws: EmbeddingStore.StoreError.self) { try EmbeddingStore.load(key: key) }
        }
    }

    @Test func hugeHeaderLengthAndTruncatedRowsRejectWithoutUncheckedRead() throws {
        let key = "truncated-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key)) }
        try FileManager.default.createDirectory(at: EmbeddingStore.directory, withIntermediateDirectories: true)
        var hugeLength = Data("PALMEMB1".utf8)
        var length = UInt32.max.littleEndian
        hugeLength.append(Data(bytes: &length, count: 4))
        hugeLength.append(0)
        let header = EmbeddingStore.Header(model: "fixture", modelVersion: 1, samplerVersion: 1, dim: 3, count: 2)
        for bytes in [hugeLength, try raw(header, payload: Data(repeating: 0, count: 7))] {
            try bytes.write(to: EmbeddingStore.diskURL(key), options: .atomic)
            #expect(EmbeddingStore.header(key: key) == nil)
            #expect(throws: EmbeddingStore.StoreError.self) { try EmbeddingStore.load(key: key) }
        }
    }

    @Test func invalidRowsAndNonfiniteHalfVectorsReject() throws {
        let key = "row-values-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key)) }
        try FileManager.default.createDirectory(at: EmbeddingStore.directory, withIntermediateDirectories: true)
        let header = EmbeddingStore.Header(model: "fixture", modelVersion: 1, samplerVersion: 1, dim: 1, count: 1)
        for (time, start, end, vector) in [(Double.nan, 0.0, 1.0, Float16(1)),
                                          (0, 1, 2, Float16(1)), (0, 0, 1, Float16.nan)] {
            var payload = Data()
            for number in [time, start, end] {
                var number = number
                payload.append(Data(bytes: &number, count: 8))
            }
            var vector = vector
            payload.append(Data(bytes: &vector, count: 2))
            try raw(header, payload: payload).write(to: EmbeddingStore.diskURL(key), options: .atomic)
            #expect(throws: EmbeddingStore.StoreError.self) { try EmbeddingStore.load(key: key) }
        }
    }

    @Test func saveRejectsShapeMismatchInsteadOfPreconditionTrap() {
        let header = EmbeddingStore.Header(model: "fixture", modelVersion: 1, samplerVersion: 1, dim: 3, count: 2)
        #expect(throws: EmbeddingStore.StoreError.self) {
            try EmbeddingStore.save(header: header, rows: [], vectors: [], key: "unused-invalid")
        }
    }

    @Test func rankerRejectsDirectMalformedIndexesAndInvalidLimits() {
        let header = EmbeddingStore.Header(model: "fixture", modelVersion: 1, samplerVersion: 1, dim: 2, count: 2)
        let malformed = EmbeddingStore.AssetIndex(header: header, rows: [], vectors: [1, 0, 1, 0])
        #expect(VisualSearch.search(query: [1, 0], indexes: [("asset", malformed)]).isEmpty)
        let excessive = EmbeddingStore.AssetIndex(header: .init(model: "fixture", modelVersion: 1, samplerVersion: 1,
                                                               dim: 2, count: Int.max), rows: [], vectors: [])
        #expect(VisualSearch.search(query: [1, 0], indexes: [("asset", excessive)]).isEmpty)
        #expect(VisualSearch.search(query: [Float.nan, 0], indexes: [("asset", malformed)]).isEmpty)
        #expect(VisualSearch.search(query: [1, 0], indexes: [("asset", malformed)], limit: -1).isEmpty)
    }
}
