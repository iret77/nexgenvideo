import Foundation
import CryptoKit
import NexGenEngine

struct CaptionTranscriptionClient: Sendable {
    var transcribe: @MainActor @Sendable (URL, Bool, ClosedRange<Double>?, Bool, Locale?) async throws -> TranscriptionResult
    var supportedLocales: @MainActor @Sendable () async -> [Locale]
    var cacheFrozenSources = false

    static let live = Self(transcribe: { url, isVideo, range, censor, locale in
        return isVideo
            ? try await Transcription.transcribeVideoAudio(videoURL: url, censorProfanity: censor, preferredLocale: locale, sourceRange: range)
            : try await Transcription.transcribe(fileURL: url, censorProfanity: censor, preferredLocale: locale, sourceRange: range)
    }, supportedLocales: { await Transcription.supportedLocales() }, cacheFrozenSources: true)

    @MainActor func transcribeFrozen(_ source: CaptionInputSnapshot.Source, video: Bool,
                                    range: ClosedRange<Double>?, censor: Bool, locale: Locale?) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let key = CaptionTranscriptionCache.Key(sha256: source.sha256, video: video,
            range: range.map { [$0.lowerBound, $0.upperBound] }, censor: censor, locale: locale?.identifier)
        if cacheFrozenSources, let result = await CaptionTranscriptionCache.shared.read(key) {
            try Task.checkCancellation()
            return result
        }
        let result: TranscriptionResult
        do { result = try await transcribe(source.frozen, video, range, censor, locale) }
        catch { try Task.checkCancellation(); throw error }
        try Task.checkCancellation()
        guard TranscriptCache.valid(result) else { throw TranscriptionError.decodeFailed }
        if cacheFrozenSources { await CaptionTranscriptionCache.shared.store(result, key: key) }
        return result
    }
}

private actor CaptionTranscriptionCache {
    struct Key: Codable, Sendable {
        let sha256: String
        let video: Bool
        let range: [Double]?
        let censor: Bool
        let locale: String?
    }
    static let shared = CaptionTranscriptionCache()
    private func url(_ key: Key) -> URL? {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let bytes = try? encoder.encode(key), let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent(Log.subsystem + "/Transcripts/Captions-v1", isDirectory: true)
            .appendingPathComponent(FileDigest.sha256(of: bytes) + ".json")
    }
    func read(_ key: Key) -> TranscriptionResult? {
        guard let url = url(key), let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(TranscriptionResult.self, from: data),
              TranscriptCache.valid(result) else { return nil }
        return result
    }
    func store(_ result: TranscriptionResult, key: Key) {
        guard TranscriptCache.valid(result), let url = url(key), let data = try? JSONEncoder().encode(result) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
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
    let unavailable: [String: String]

    static func freeze(_ inputs: [String: URL], skippingUnavailable: Bool = false) throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NexGenVideo-Captions-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var sources: [String: Source] = [:]
            var copied: [URL: Source] = [:]
            var failures: [URL: String] = [:]
            var unavailable: [String: String] = [:]
            for (index, pair) in inputs.sorted(by: { $0.key < $1.key }).enumerated() {
                try Task.checkCancellation()
                if let source = copied[pair.value] { sources[pair.key] = source; continue }
                if let failure = failures[pair.value] { unavailable[pair.key] = failure; continue }
                do {
                    let frozen = directory.appendingPathComponent(String(index)).appendingPathExtension(pair.value.pathExtension)
                    let hash = try fingerprint(pair.value)
                    try copy(pair.value, to: frozen)
                    guard try fingerprint(frozen) == hash, try fingerprint(pair.value) == hash else {
                        throw EditorViewModel.CaptionError.sourceChanged
                    }
                    let source = Source(original: pair.value, frozen: frozen, sha256: hash)
                    sources[pair.key] = source; copied[pair.value] = source
                } catch {
                    try Task.checkCancellation()
                    guard skippingUnavailable, !(error is CancellationError),
                          error as? EditorViewModel.CaptionError != .sourceChanged else { throw error }
                    unavailable[pair.key] = error.localizedDescription
                    failures[pair.value] = error.localizedDescription
                }
            }
            return .init(directory: directory, sources: sources, unavailable: unavailable)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func validateSources() throws {
        var checked = Set<URL>()
        for source in sources.values where checked.insert(source.original).inserted {
            try Task.checkCancellation()
            guard try Self.fingerprint(source.original) == source.sha256 else { throw EditorViewModel.CaptionError.sourceChanged }
        }
    }

    func discard() { try? FileManager.default.removeItem(at: directory) }

    static func fingerprint(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try file.read(upToCount: 1_048_576), !data.isEmpty else { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func copy(_ source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while true {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty else { break }
            try output.write(contentsOf: bytes)
        }
    }
}
