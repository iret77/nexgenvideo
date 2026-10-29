import CryptoKit
import Foundation

/// Disk cache for per-asset frame embeddings, keyed by file identity.
struct EmbeddingStore {
    struct Header: Codable, Equatable, Sendable {
        let model: String
        let modelVersion: Int
        let samplerVersion: Int
        let dim: Int
        let count: Int
    }

    struct Row: Sendable {
        let time: Double
        let shotStart: Double
        let shotEnd: Double
    }

    struct AssetIndex: Sendable {
        let header: Header
        let rows: [Row]
        let vectors: [Float]
    }

    enum StoreError: LocalizedError {
        case corrupt
        var errorDescription: String? { "The visual search index is damaged. Retry indexing this media." }
    }

    private static let magic = Data("PALMEMB1".utf8)
    private static let maximumHeaderBytes = 65_536

    static let directory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/Embeddings", isDirectory: true)

    static func key(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let identity = "\(url.path)|\(mtime.timeIntervalSince1970)|\(size)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    static func diskURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).embed") }

    static func header(key: String) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: diskURL(key)) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: magic.count + 4),
              prefix.count == magic.count + 4, prefix.prefix(magic.count) == magic else { return nil }
        let length = Int(UInt32(littleEndian: prefix.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard length > 0, length <= maximumHeaderBytes,
              let json = try? handle.read(upToCount: length), json.count == length,
              let header = try? JSONDecoder().decode(Header.self, from: json),
              let layout = try? validatedLayout(header),
              let expectedSize = checkedSize(prefix: magic.count + 4 + length, payload: layout.payloadBytes),
              let attributes = try? FileManager.default.attributesOfItem(atPath: diskURL(key).path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size == Int64(expectedSize) else { return nil }
        return header
    }

    private static func checkedSize(prefix: Int, payload: Int) -> Int? {
        let (size, overflow) = prefix.addingReportingOverflow(payload)
        return overflow ? nil : size
    }

    static func isCurrent(key: String, model: String, modelVersion: Int, samplerVersion: Int) -> Bool {
        guard let header = header(key: key), header.count > 0 else { return false }
        return header.model == model && header.modelVersion == modelVersion && header.samplerVersion == samplerVersion
    }

    static func load(key: String) throws -> AssetIndex {
        let data = try Data(contentsOf: diskURL(key))
        guard data.count > magic.count + 4, data.prefix(magic.count) == magic else { throw StoreError.corrupt }
        let length = Int(UInt32(littleEndian: data[magic.count..<(magic.count + 4)].withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }))
        var offset = magic.count + 4
        guard length > 0, length <= maximumHeaderBytes, length <= data.count - offset else { throw StoreError.corrupt }
        guard let header = try? JSONDecoder().decode(Header.self, from: data.subdata(in: offset..<(offset + length))) else {
            throw StoreError.corrupt
        }
        offset += length
        let layout = try validatedLayout(header)
        guard data.count - offset == layout.payloadBytes else { throw StoreError.corrupt }
        var rows: [Row] = []
        rows.reserveCapacity(header.count)
        var vectors = [Float](repeating: 0, count: layout.vectorCount)
        data.suffix(from: offset).withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for row in 0..<header.count {
                let base = row * layout.rowBytes
                rows.append(Row(time: raw.loadUnaligned(fromByteOffset: base, as: Double.self),
                                shotStart: raw.loadUnaligned(fromByteOffset: base + 8, as: Double.self),
                                shotEnd: raw.loadUnaligned(fromByteOffset: base + 16, as: Double.self)))
                for column in 0..<header.dim {
                    vectors[row * header.dim + column] = Float(raw.loadUnaligned(fromByteOffset: base + 24 + column * 2, as: Float16.self))
                }
            }
        }
        let index = AssetIndex(header: header, rows: rows, vectors: vectors)
        try validate(index)
        return index
    }

    static func validate(_ index: AssetIndex) throws {
        let layout = try validatedLayout(index.header)
        guard index.rows.count == index.header.count, index.vectors.count == layout.vectorCount,
              index.vectors.allSatisfy(\.isFinite) else { throw StoreError.corrupt }
        var previous = -Double.infinity
        for row in index.rows {
            guard row.time.isFinite, row.shotStart.isFinite, row.shotEnd.isFinite,
                  row.shotStart >= 0, row.shotStart <= row.time, row.time <= row.shotEnd,
                  row.time >= previous else { throw StoreError.corrupt }
            previous = row.time
        }
    }

    private static func validatedLayout(_ header: Header) throws -> (rowBytes: Int, vectorCount: Int, payloadBytes: Int) {
        guard !header.model.isEmpty, header.modelVersion > 0, header.samplerVersion > 0,
              header.dim > 0, header.dim <= Int(Int32.max), header.count >= 0, header.count <= Int(Int32.max) else {
            throw StoreError.corrupt
        }
        let (embeddingBytes, dimensionOverflow) = header.dim.multipliedReportingOverflow(by: 2)
        let (rowBytes, rowOverflow) = embeddingBytes.addingReportingOverflow(24)
        let (payloadBytes, payloadOverflow) = header.count.multipliedReportingOverflow(by: rowBytes)
        let (vectorCount, vectorOverflow) = header.count.multipliedReportingOverflow(by: header.dim)
        guard !dimensionOverflow, !rowOverflow, !payloadOverflow, !vectorOverflow else { throw StoreError.corrupt }
        return (rowBytes, vectorCount, payloadBytes)
    }

    static func save(header: Header, rows: [Row], vectors: [Float], key: String) throws {
        try validate(AssetIndex(header: header, rows: rows, vectors: vectors))
        guard vectors.allSatisfy({ Float16($0).isFinite }) else { throw StoreError.corrupt }
        let json = try JSONEncoder().encode(header)
        guard !json.isEmpty, json.count <= maximumHeaderBytes else { throw StoreError.corrupt }
        var data = magic
        var length = UInt32(json.count).littleEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(json)
        for (index, row) in rows.enumerated() {
            for value in [row.time, row.shotStart, row.shotEnd] {
                var value = value
                data.append(Data(bytes: &value, count: 8))
            }
            for column in 0..<header.dim {
                var half = Float16(vectors[index * header.dim + column])
                data.append(Data(bytes: &half, count: 2))
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: diskURL(key), options: .atomic)
    }

    static func clearAll() { try? FileManager.default.removeItem(at: directory) }

    static func clearAllChecked(at root: URL = EmbeddingStore.directory) throws {
        do { try FileManager.default.removeItem(at: root) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }
}
