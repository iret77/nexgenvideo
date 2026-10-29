import Foundation
import NexGenEngine

struct CaptionTranscriptionClient: Sendable {
    var transcribe: @MainActor @Sendable (URL, Bool, ClosedRange<Double>?, Bool, Locale?) async throws -> TranscriptionResult
    var supportedLocales: @MainActor @Sendable () async -> [Locale]

    static let live = Self(transcribe: { url, isVideo, range, censor, locale in
        if censor || locale != nil {
            return isVideo
                ? try await Transcription.transcribeVideoAudio(videoURL: url, censorProfanity: censor, preferredLocale: locale, sourceRange: range)
                : try await Transcription.transcribe(fileURL: url, censorProfanity: censor, preferredLocale: locale, sourceRange: range)
        }
        return try await TranscriptCache.shared.transcript(for: url, isVideo: isVideo, range: range)
    }, supportedLocales: { await Transcription.supportedLocales() })
}

struct CaptionProjectState {
    let timeline: Timeline
    let manifest: MediaManifest
    let root: URL?
    let key: String?
    let generation: UUID?

    @MainActor init(_ editor: EditorViewModel) {
        timeline = editor.timeline; manifest = editor.mediaManifest
        root = editor.workingRoot; key = editor.openWorkingCopyKey; generation = editor.openWorkingCopyGeneration
    }

    @MainActor func validate(_ editor: EditorViewModel) throws {
        try Task.checkCancellation()
        guard timeline == editor.timeline, manifest == editor.mediaManifest, root == editor.workingRoot,
              key == editor.openWorkingCopyKey, generation == editor.openWorkingCopyGeneration else {
            throw EditorViewModel.CaptionError.timelineChanged
        }
    }
}

struct CaptionInputSnapshot: Sendable {
    struct Source: Sendable {
        let original: URL
        let frozen: URL
        let sha256: String
    }
    let directory: URL
    let sources: [String: Source]

    static func freeze(_ inputs: [String: URL]) throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NexGenVideo-Captions-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var sources: [String: Source] = [:]
            for (index, pair) in inputs.sorted(by: { $0.key < $1.key }).enumerated() {
                try Task.checkCancellation()
                let frozen = directory.appendingPathComponent(String(index)).appendingPathExtension(pair.value.pathExtension)
                let hash = try FileDigest.sha256(of: pair.value)
                try FileManager.default.copyItem(at: pair.value, to: frozen)
                guard try FileDigest.sha256(of: frozen) == hash, try FileDigest.sha256(of: pair.value) == hash else {
                    throw EditorViewModel.CaptionError.sourceChanged
                }
                sources[pair.key] = .init(original: pair.value, frozen: frozen, sha256: hash)
            }
            return .init(directory: directory, sources: sources)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func validateSources() throws {
        for source in sources.values {
            try Task.checkCancellation()
            guard try FileDigest.sha256(of: source.original) == source.sha256 else { throw EditorViewModel.CaptionError.sourceChanged }
        }
    }

    func discard() { try? FileManager.default.removeItem(at: directory) }
}
