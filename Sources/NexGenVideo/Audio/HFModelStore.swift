import CryptoKit
import Foundation

/// Download-on-demand for on-device ML model files hosted publicly on Hugging Face (a free, public
/// model host — no NexGen-run infrastructure). Caches under Application Support/NexGenVideo/models/<subdir>.
/// Shared by the Demucs (stem separation) and Beat This! (downbeat) providers. Synchronous — callers
/// run on the analysis phase runner's detached task.
enum HFModelStore {
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
        file: String,
        subdir: String,
        minBytes: Int = 1_000_000,
        expectedSHA256: String? = nil
    ) throws -> URL {
        try ensure(urlString: "https://huggingface.co/\(repo)/resolve/main/\(file)?download=true",
                   file: file, subdir: subdir, minBytes: minBytes, expectedSHA256: expectedSHA256)
    }

    /// Resolve `file` from an explicit public URL into `subdir` (for models hosted outside HF, e.g. a
    /// GitHub raw asset), downloading (blocking) if absent or too small. Returns the local file URL.
    static func ensure(
        urlString: String,
        file: String,
        subdir: String,
        minBytes: Int = 1_000_000,
        expectedSHA256: String? = nil
    ) throws -> URL {
        let dest = try modelsDir(subdir).appendingPathComponent(file)
        if let expectedSHA256, !isSHA256(expectedSHA256) {
            throw StoreError.downloadFailed("invalid pinned checksum for \(file)")
        }
        if fileSize(dest) >= minBytes {
            if let expectedSHA256 {
                if (try? sha256Hex(of: dest))?.caseInsensitiveCompare(expectedSHA256) == .orderedSame {
                    return dest
                }
                try? FileManager.default.removeItem(at: dest)
            } else {
                return dest
            }
        }
        guard let url = URL(string: urlString) else {
            throw StoreError.downloadFailed("bad model URL: \(urlString)")
        }
        let sem = DispatchSemaphore(value: 0)
        var thrown: Error?
        let task = URLSession.shared.downloadTask(with: url) { tmp, response, err in
            defer { sem.signal() }
            if let err { thrown = err; return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let tmp, (200..<300).contains(code) else {
                thrown = StoreError.downloadFailed("HTTP \(code) for \(file)")
                return
            }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
            } catch { thrown = error }
        }
        task.resume()
        sem.wait()
        if let thrown { throw thrown }
        // Reject a bad payload (e.g. an HTML error body served with a 200) so we don't hand ORT garbage
        // and cache it forever.
        guard fileSize(dest) >= minBytes else {
            try? FileManager.default.removeItem(at: dest)
            throw StoreError.downloadFailed("\(file) came back too small (\(fileSize(dest)) bytes) — not a valid model")
        }
        if let expectedSHA256 {
            guard (try? sha256Hex(of: dest)).map({
                $0.caseInsensitiveCompare(expectedSHA256) == .orderedSame
            }) == true else {
                try? FileManager.default.removeItem(at: dest)
                throw StoreError.downloadFailed("\(file) didn't match its pinned checksum")
            }
        }
        return dest
    }

    static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    }
}
