import CryptoKit
import Foundation

/// Download-on-demand for on-device ML model files hosted publicly on Hugging Face (a free, public
/// model host — no NexGen-run infrastructure). Caches under Application Support/NexGenVideo/models/<subdir>.
/// Shared by the Demucs (stem separation) and Beat This! (downbeat) providers. Synchronous — callers
/// run on the analysis phase runner's detached task.
enum HFModelStore {
    typealias Downloader = (_ source: URL, _ destination: URL) throws -> Void

    private final class DownloadState: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: (any Error)?

        func fail(_ error: any Error) {
            lock.withLock { storedError = error }
        }

        var error: (any Error)? {
            lock.withLock { storedError }
        }
    }

    enum StoreError: LocalizedError {
        case downloadFailed(String)
        var errorDescription: String? {
            switch self {
            case .downloadFailed(let m): return "Couldn't download the on-device model: \(m)"
            }
        }
    }

    static func modelsDir(_ subdir: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("NexGenVideo/models/\(subdir)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolve `repo`/`file` from the HF resolve endpoint into `subdir`, downloading (blocking) if the
    /// cached copy is absent or too small. Returns the local file URL. `minBytes` guards against a
    /// cached error page / truncated download being trusted as a model (these models are tens of MB+).
    static func ensure(
        repo: String,
        revision: String,
        file: String,
        subdir: String,
        minBytes: Int = 1_000_000,
        expectedSHA256: String,
        storeRoot: URL? = nil,
        downloader: Downloader? = nil
    ) throws -> URL {
        guard revision.count == 40, revision.allSatisfy(\.isHexDigit) else {
            throw StoreError.downloadFailed(
                "\(file) requires a full immutable repository commit"
            )
        }
        return try ensure(
            urlString: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file)?download=true",
            file: file,
            subdir: subdir,
            minBytes: minBytes,
            expectedSHA256: expectedSHA256,
            storeRoot: storeRoot,
            downloader: downloader
        )
    }

    /// Resolve `file` from an explicit public URL into `subdir` (for models hosted outside HF, e.g. a
    /// GitHub raw asset), downloading (blocking) if absent or too small. Returns the local file URL.
    static func ensure(
        urlString: String,
        file: String,
        subdir: String,
        minBytes: Int = 1_000_000,
        expectedSHA256: String,
        storeRoot: URL? = nil,
        downloader: Downloader? = nil
    ) throws -> URL {
        guard isSHA256(expectedSHA256) else {
            throw StoreError.downloadFailed("invalid pinned checksum for \(file)")
        }
        let directory: URL
        if let storeRoot {
            directory = storeRoot.appendingPathComponent(subdir, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } else {
            directory = try modelsDir(subdir)
        }
        let dest = directory.appendingPathComponent(file)
        if fileSize(dest) >= minBytes {
            if (try? sha256Hex(of: dest))?.caseInsensitiveCompare(expectedSHA256) == .orderedSame {
                return dest
            }
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            do {
                try FileManager.default.removeItem(at: dest)
            } catch {
                throw StoreError.downloadFailed(
                    "couldn't remove the invalid cached \(file): \(error.localizedDescription)"
                )
            }
        }
        guard let url = URL(string: urlString) else {
            throw StoreError.downloadFailed("bad model URL: \(urlString)")
        }
        let staging = directory.appendingPathComponent(
            ".\(file).download-\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: staging) }
        if let downloader {
            try downloader(url, staging)
        } else {
            try downloadSync(from: url, to: staging)
        }
        guard fileSize(staging) >= minBytes else {
            throw StoreError.downloadFailed(
                "\(file) came back too small (\(fileSize(staging)) bytes) — not a valid model"
            )
        }
        guard (try? sha256Hex(of: staging)).map({
            $0.caseInsensitiveCompare(expectedSHA256) == .orderedSame
        }) == true else {
            throw StoreError.downloadFailed("\(file) didn't match its pinned checksum")
        }
        try FileManager.default.moveItem(at: staging, to: dest)
        return dest
    }

    private static func downloadSync(from url: URL, to destination: URL) throws {
        let sem = DispatchSemaphore(value: 0)
        let state = DownloadState()
        let task = URLSession.shared.downloadTask(with: url) { tmp, response, err in
            defer { sem.signal() }
            if let err {
                state.fail(err)
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let tmp, (200..<300).contains(code) else {
                state.fail(StoreError.downloadFailed(
                    "HTTP \(code) for \(destination.lastPathComponent)"
                ))
                return
            }
            do {
                try FileManager.default.moveItem(at: tmp, to: destination)
            } catch {
                state.fail(error)
            }
        }
        task.resume()
        sem.wait()
        if let error = state.error { throw error }
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024),
              !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    }
}
