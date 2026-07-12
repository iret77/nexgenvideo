import Foundation

/// Resolves the on-device whisper.cpp ggml model, downloading it on demand from the public Hugging
/// Face mirror and caching it in Application Support. Whisper models are large (~1.6 GB for
/// large-v3-turbo), so they ship OUTSIDE the app and download once, on the first analysis that needs
/// transcription. Hugging Face is a public, free model host — no NexGen-run infrastructure involved.
enum WhisperModelStore {
    /// Default model: `large-v3-turbo` — near-large-v3 quality (the bar the old pipeline set) at a
    /// fraction of the runtime, and robust on sung vocals where Apple Speech failed. Overridable via
    /// the `NGV_WHISPER_MODEL` environment variable (e.g. "medium", "small").
    static var defaultModel: String {
        ProcessInfo.processInfo.environment["NGV_WHISPER_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "large-v3-turbo"
    }

    enum ModelError: LocalizedError {
        case downloadFailed(String)
        var errorDescription: String? {
            switch self {
            case .downloadFailed(let m): return "Couldn't download the on-device speech model: \(m)"
            }
        }
    }

    static func modelsDir() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("NexGenVideo/models/whisper", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The local model file, downloading it (blocking) if absent. Call off the main thread — the
    /// analysis phase runner already runs on a detached task. Idempotent: a present, non-empty file
    /// is returned as-is.
    static func ensureModel(_ model: String) throws -> URL {
        let filename = "ggml-\(model).bin"
        let dest = try modelsDir().appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path),
            let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int, size > 0 {
            return dest
        }
        guard let url = URL(string:
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)?download=true") else {
            throw ModelError.downloadFailed("bad model URL for \(filename)")
        }
        try downloadSync(from: url, to: dest)
        return dest
    }

    /// Synchronous download to `dest` (atomic move from URLSession's temp file). URLSession runs on
    /// its own queue, so blocking the caller here never starves it.
    private static func downloadSync(from url: URL, to dest: URL) throws {
        let sem = DispatchSemaphore(value: 0)
        var thrown: Error?
        let task = URLSession.shared.downloadTask(with: url) { tmp, response, err in
            defer { sem.signal() }
            if let err { thrown = err; return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let tmp, (200..<300).contains(code) else {
                thrown = ModelError.downloadFailed("HTTP \(code)")
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
    }
}
