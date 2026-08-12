import Foundation
import NexGenEngine

/// Host-side reader for the `beatAnalysis` cockpit surface. Decodes the fields the Analysis panel
/// renders straight from the pack's `analysis/<song>.json` (schema `analysis/v2`) — the host owns this
/// generic "measured audio analysis" shape, so it never imports the format pack's own `Analysis` type.
/// The file is located with the public engine helper (`AudioProjectLayout`), the same one the pack uses,
/// so both read the identical artifact under the one-song discipline.
struct AnalysisSurfaceData: Decodable, Sendable, Equatable {
    var songPath: String
    var durationS: Double
    var bpm: Double
    var tempoMultiplier: Double
    var key: String?
    var downbeatSource: String?
    var beats: [Double]
    var downbeats: [Double]
    var sections: [Section]
    var structureResolution: StructureResolution?
    var stageDiagnostics: [StageDiagnostic]

    /// Perceived tempo = measured bpm × the A2-confirmed multiplier (the raw value is often half/double
    /// the subjective feel) — the value every downstream consumer uses, so it's what the panel shows.
    var perceivedBpm: Double { bpm * tempoMultiplier }

    /// A measured beat grid with real beats is the surface's reason to exist; without it the track is
    /// rubato/beatless and the panel shows the degraded state (key + duration only).
    var hasBeatGrid: Bool { !beats.isEmpty }

    var hasCanonicalStructure: Bool {
        guard let status = structureResolution?.status else { return false }
        return status == "resolved" || status == "review_required"
    }

    var requiresStructureReview: Bool { structureResolution?.status == "review_required" }

    var nonSuccessStageDiagnostics: [StageDiagnostic] {
        stageDiagnostics.filter { $0.status != "succeeded" && $0.status != "not_applicable" }
    }

    /// The song's display name (last path component of the recorded song path).
    var trackName: String { (songPath as NSString).lastPathComponent }

    struct Section: Decodable, Sendable, Equatable, Identifiable {
        var index: Int
        var start: Double
        var end: Double
        var label: String?
        var source: String?
        var id: Int { index }

        enum CodingKeys: String, CodingKey { case index, start, end, label, source }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
            start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
            end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
            label = try c.decodeIfPresent(String.self, forKey: .label)
            source = try c.decodeIfPresent(String.self, forKey: .source)
        }
    }

    struct StructureResolution: Decodable, Sendable, Equatable {
        var status: String
        var method: String
        var candidateBoundaryCount: Int
        var acceptedBoundaryCount: Int
        var discardedBoundaryCount: Int
        var detail: String

        enum CodingKeys: String, CodingKey {
            case status, method, detail
            case candidateBoundaryCount = "candidate_boundary_count"
            case acceptedBoundaryCount = "accepted_boundary_count"
            case discardedBoundaryCount = "discarded_boundary_count"
        }
    }

    struct StageDiagnostic: Decodable, Sendable, Equatable {
        var stage: String
        var status: String
        var detail: String
    }

    enum CodingKeys: String, CodingKey {
        case songPath = "song_path"
        case durationS = "duration_s"
        case bpm
        case tempoMultiplier = "tempo_multiplier"
        case key
        case downbeatSource = "downbeat_source"
        case beats
        case downbeats
        case sections
        case structureResolution = "structure_resolution"
        case stageDiagnostics = "stage_diagnostics"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songPath = try c.decodeIfPresent(String.self, forKey: .songPath) ?? ""
        durationS = try c.decodeIfPresent(Double.self, forKey: .durationS) ?? 0
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm) ?? 0
        tempoMultiplier = try c.decodeIfPresent(Double.self, forKey: .tempoMultiplier) ?? 1.0
        key = try c.decodeIfPresent(String.self, forKey: .key)
        downbeatSource = try c.decodeIfPresent(String.self, forKey: .downbeatSource)
        beats = try c.decodeIfPresent([Double].self, forKey: .beats) ?? []
        downbeats = try c.decodeIfPresent([Double].self, forKey: .downbeats) ?? []
        sections = try c.decodeIfPresent([Section].self, forKey: .sections) ?? []
        structureResolution = try c.decodeIfPresent(StructureResolution.self, forKey: .structureResolution)
        stageDiagnostics = try c.decodeIfPresent([StageDiagnostic].self, forKey: .stageDiagnostics) ?? []
    }
}

extension AnalysisSurfaceData {
    /// The analysis artifact URL for a data root, or nil when it doesn't exist yet (so the surface's tab
    /// stays hidden until there is something to show). Uses the same one-song resolution as the pack.
    static func artifactURL(dataRoot: URL) -> URL? {
        guard let url = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Load + decode the analysis artifact under `dataRoot`, or nil when absent/unreadable.
    static func load(dataRoot: URL) -> AnalysisSurfaceData? {
        guard let url = artifactURL(dataRoot: dataRoot),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(AnalysisSurfaceData.self, from: data)
    }
}
