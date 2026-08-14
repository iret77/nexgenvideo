import CryptoKit
import Foundation
import NexGenEngine

struct AnalysisMeasurementProof: Codable, Sendable, Equatable {
    static let currentSchema = "analysis_measurement_proof/v1"

    struct LyricsAlignmentProof: Codable, Sendable, Equatable {
        let sourcePath: String
        let sourceSHA256: String
        let lyricsSHA256: String
        let alignmentSHA256: String
        let timingEvidence: LyricsAlignment.TimingEvidence
        let timingMethod: KnownTextAlignmentTimingMethod?
        let markerCount: Int
        let lyricTokenCount: Int
        let matchedTokenCount: Int

        enum CodingKeys: String, CodingKey {
            case markerCount = "marker_count"
            case sourcePath = "source_path"
            case sourceSHA256 = "source_sha256"
            case lyricsSHA256 = "lyrics_sha256"
            case alignmentSHA256 = "alignment_sha256"
            case timingEvidence = "timing_evidence"
            case timingMethod = "timing_method"
            case lyricTokenCount = "lyric_token_count"
            case matchedTokenCount = "matched_token_count"
        }
    }

    let schema: String
    let project: String
    let songSHA256: String
    let lyricsAlignment: LyricsAlignmentProof?

    enum CodingKeys: String, CodingKey {
        case schema, project
        case songSHA256 = "song_sha256"
        case lyricsAlignment = "lyrics_alignment"
    }

    init(project: String, songSHA256: String, lyricsAlignment: LyricsAlignmentProof?) {
        schema = Self.currentSchema
        self.project = project
        self.songSHA256 = songSHA256
        self.lyricsAlignment = lyricsAlignment
    }
}

enum AnalysisMeasurementProofStore {
    static func url(dataRoot: URL) -> URL? {
        AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot).map {
            $0.deletingPathExtension().appendingPathExtension("measurement-proof.json")
        }
    }

    static func save(_ proof: AnalysisMeasurementProof, dataRoot: URL) throws {
        guard let destination = url(dataRoot: dataRoot) else {
            throw MusicvideoAnalysisRunner.RunError.noSong(
                audioDir: dataRoot.appendingPathComponent("audio").path
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(proof)
        data.append(0x0A)
        try data.write(to: destination, options: .atomic)
    }

    static func load(dataRoot: URL) throws -> AnalysisMeasurementProof {
        guard let source = url(dataRoot: dataRoot) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(
            AnalysisMeasurementProof.self,
            from: Data(contentsOf: source)
        )
    }

    static func lyricsFingerprint(_ lyrics: String) -> String {
        sha256(Data(lyrics.utf8))
    }

    static func alignmentFingerprint(_ object: [String: Any]) throws -> String {
        let alignment = object["alignment"] as? [[String: Any]] ?? []
        return sha256(try JSONSerialization.data(
            withJSONObject: alignment,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
