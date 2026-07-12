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
    /// cached copy is absent or empty. Returns the local file URL.
    static func ensure(repo: String, file: String, subdir: String) throws -> URL {
        let dest = try modelsDir(subdir).appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: dest.path),
            let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int, size > 0 {
            return dest
        }
        guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)?download=true") else {
            throw StoreError.downloadFailed("bad model URL for \(repo)/\(file)")
        }
        let sem = DispatchSemaphore(value: 0)
        var thrown: Error?
        let task = URLSession.shared.downloadTask(with: url) { tmp, response, err in
            defer { sem.signal() }
            if let err { thrown = err; return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let tmp, (200..<300).contains(code) else {
                thrown = StoreError.downloadFailed("HTTP \(code) for \(repo)/\(file)")
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
        return dest
    }
}
