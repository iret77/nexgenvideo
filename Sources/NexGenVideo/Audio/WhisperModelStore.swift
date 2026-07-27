import Foundation

/// Resolves the on-device whisper.cpp ggml model, downloading it on demand from the public Hugging
/// Face mirror and caching it in Application Support. Whisper models are large (~1.6 GB for
/// large-v3-turbo), so they ship OUTSIDE the app and download once, on the first analysis that needs
/// transcription. Hugging Face is a public, free model host — no NexGen-run infrastructure involved.
enum WhisperModelStore {
    struct ModelSpec: Equatable {
        let filename: String
        let revision: String
        let sha256: String
        let size: Int
    }

    private static let repository = "ggerganov/whisper.cpp"
    private static let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    static let specifications: [String: ModelSpec] = [
        "large-v3-turbo": ModelSpec(
            filename: "ggml-large-v3-turbo.bin",
            revision: revision,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
            size: 1_624_555_275
        ),
        "medium": ModelSpec(
            filename: "ggml-medium.bin",
            revision: revision,
            sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
            size: 1_533_763_059
        ),
        "small": ModelSpec(
            filename: "ggml-small.bin",
            revision: revision,
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
            size: 487_601_967
        ),
    ]

    /// Default model: `large-v3-turbo` — near-large-v3 quality (the bar the old pipeline set) at a
    /// fraction of the runtime, and robust on sung vocals where Apple Speech failed. Overridable via
    /// `NGV_WHISPER_MODEL` with one of the pinned model names.
    static var defaultModel: String {
        ProcessInfo.processInfo.environment["NGV_WHISPER_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "large-v3-turbo"
    }

    enum ModelError: LocalizedError {
        case downloadFailed(String)
        case unsupportedModel(String)
        var errorDescription: String? {
            switch self {
            case .downloadFailed(let m): return "Couldn't download the on-device speech model: \(m)"
            case .unsupportedModel(let model):
                return "Unsupported on-device speech model '\(model)'. Choose "
                    + WhisperModelStore.specifications.keys.sorted().joined(separator: ", ") + "."
            }
        }
    }

    static func ensureModel(
        _ model: String,
        storeRoot: URL? = nil,
        downloader: HFModelStore.Downloader? = nil
    ) throws -> URL {
        guard let spec = specifications[model] else {
            throw ModelError.unsupportedModel(model)
        }
        do {
            return try HFModelStore.ensure(
                repo: repository,
                revision: spec.revision,
                file: spec.filename,
                subdir: "whisper",
                minBytes: spec.size,
                expectedSHA256: spec.sha256,
                storeRoot: storeRoot,
                downloader: downloader
            )
        } catch {
            throw ModelError.downloadFailed(error.localizedDescription)
        }
    }
}
