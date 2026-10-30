import BpyRuntimeProtocol
import CryptoKit
import Foundation

nonisolated final class SpatialScenePayload: @unchecked Sendable {
    private enum Source {
        case bytes(Data)
        case project(path: String, root: URL)
        case runtime(BpyRuntimeFile)
    }

    private let lock = NSLock()
    private let source: Source
    let sha256: String
    let byteCount: UInt64
    private var released = false

    init(data: Data) {
        source = .bytes(data); sha256 = SpatialSceneStore.digest(data); byteCount = UInt64(data.count)
    }

    init(path: String, root: URL, sha256: String, byteCount: UInt64) {
        source = .project(path: path, root: root); self.sha256 = sha256; self.byteCount = byteCount
    }

    init(file: BpyRuntimeFile) {
        source = .runtime(file); sha256 = file.sha256; byteCount = file.byteCount
    }

    private func file(checking: () throws -> Void = {}) throws -> BpyRuntimeFile? {
        try lock.withLock {
            guard !released else { throw SpatialSceneError.changed }
            switch source {
            case .bytes: return nil
            case .project(let path, let root):
                return try BpyRuntimeFile.borrow(path, in: root, maximum: 512 * 1_024 * 1_024,
                    expectedSHA256: sha256, checking: checking)
            case .runtime(let file): return try file.retained()
            }
        }
    }

    @discardableResult
    func verify(checking: () throws -> Void) throws -> String {
        try checking()
        if let file = try file(checking: checking) {
            defer { file.release() }
            guard file.byteCount == byteCount else { throw SpatialSceneError.changed }
            if case .runtime = source { try file.verify(checking: checking) }
        } else if case .bytes(let data) = source {
            guard UInt64(data.count) == byteCount else { throw SpatialSceneError.changed }
            var digest = SHA256()
            for offset in stride(from: 0, to: data.count, by: 65_536) {
                try checking()
                digest.update(data: data[offset..<min(offset + 65_536, data.count)])
            }
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else { throw SpatialSceneError.changed }
        }
        try checking()
        return sha256
    }

    func verifiedHeader(checking: () throws -> Void) throws -> (sha256: String, header: Data) {
        try checking()
        let header: Data
        if let file = try file(checking: checking) {
            defer { file.release() }
            guard file.byteCount == byteCount else { throw SpatialSceneError.changed }
            if case .runtime = source { try file.verify(checking: checking) }
            header = try file.read(maximum: 64)
        } else {
            _ = try verify(checking: checking)
            guard case .bytes(let data) = source else { throw SpatialSceneError.changed }
            header = Data(data.prefix(64))
        }
        try checking()
        return (sha256, header)
    }

    func data() throws -> Data {
        guard byteCount <= 512 * 1_024 * 1_024 else { throw SpatialSceneError.changed }
        if let file = try file() {
            defer { file.release() }
            return try file.verifiedData(maximum: 512 * 1_024 * 1_024)
        }
        guard case .bytes(let data) = source else { throw SpatialSceneError.changed }
        return data
    }

    func checkpoint(to destination: URL, maximum: UInt64, checking: () throws -> Void,
                    disposed: @escaping @Sendable (Bool, BpyRuntimeFileIdentity) -> Void) throws -> BpyRuntimeFile {
        guard byteCount <= maximum else { throw SpatialSceneError.changed }
        if let file = try file(checking: checking) {
            defer { file.release() }
            return try file.copy(to: destination, maximum: maximum, checking: checking, disposed: disposed)
        }
        guard case .bytes(let data) = source else { throw SpatialSceneError.changed }
        return try BpyRuntimeFile.copy(data: data, to: destination, maximum: maximum, checking: checking, disposed: disposed)
    }

    func export(to destination: URL, checking: () throws -> Void) throws {
        try checking()
        if let file = try file(checking: checking) {
            defer { file.release() }
            try file.export(to: destination, checking: checking)
        } else {
            guard case .bytes(let data) = source else { throw SpatialSceneError.changed }
            try BpyRuntimeFile.export(data: data, to: destination, checking: checking)
        }
    }

    func releaseRuntimeSource() {
        let file: BpyRuntimeFile? = lock.withLock {
            guard !released, case .runtime(let file) = source else { return nil }
            released = true
            return file
        }
        file?.release()
    }

    deinit { releaseRuntimeSource() }
}
