import Foundation
import NexGenEngine

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

    var canonicalHierarchy: [HierarchySection]? {
        guard let resolution = structureResolution else { return nil }
        if [
            "per_boundary_evidence",
            "homogeneous_consensus",
            "phrase_filtered_acoustic",
        ].contains(resolution.method) {
            guard ["resolved", "review_required"].contains(resolution.status),
                  resolution.hierarchy == nil,
                  resolution.acceptedBoundaryCount == max(0, sections.count - 1),
                  validCanonicalSections else { return nil }
            return sections.enumerated().map {
                HierarchySection(id: $0.offset, section: $0.element, segments: [])
            }
        }
        guard resolution.status == "resolved",
              resolution.method == "music_understanding_hierarchy",
              let hierarchy = resolution.hierarchy,
              hierarchy.source == "apple_music_understanding" else { return nil }
        guard hierarchy.sections.count == sections.count,
              !hierarchy.segments.isEmpty,
              !hierarchy.phrases.isEmpty,
              zip(sections, hierarchy.sections).allSatisfy({ pair in
                  pair.0.start == pair.1.start && pair.0.end == pair.1.end
              }) else { return nil }

        let segmentOwners = hierarchy.segments.map { uniqueOwner(of: $0, in: hierarchy.sections) }
        let phraseOwners = hierarchy.phrases.map { uniqueOwner(of: $0, in: hierarchy.segments) }
        guard segmentOwners.allSatisfy({ $0 != nil }), phraseOwners.allSatisfy({ $0 != nil }) else {
            return nil
        }

        let rows = sections.enumerated().map { sectionIndex, section in
            let segments = hierarchy.segments.enumerated().compactMap { segmentIndex, range -> HierarchySegment? in
                guard segmentOwners[segmentIndex] == sectionIndex else { return nil }
                let phrases = hierarchy.phrases.enumerated().compactMap { phraseIndex, phrase -> HierarchyPhrase? in
                    guard phraseOwners[phraseIndex] == segmentIndex else { return nil }
                    return HierarchyPhrase(id: phraseIndex, start: phrase.start, end: phrase.end)
                }
                return HierarchySegment(id: segmentIndex, start: range.start, end: range.end, phrases: phrases)
            }
            return HierarchySection(id: sectionIndex, section: section, segments: segments)
        }
        guard rows.allSatisfy({ !$0.segments.isEmpty }),
              rows.flatMap({ $0.segments }).allSatisfy({ !$0.phrases.isEmpty }) else { return nil }
        return rows
    }

    var hasCanonicalStructure: Bool { canonicalHierarchy != nil }

    var hasNestedHierarchy: Bool {
        canonicalHierarchy?.contains { !$0.segments.isEmpty } == true
    }

    var requiresStructureReview: Bool {
        structureResolution?.status == "review_required" && hasCanonicalStructure
    }

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

    struct HierarchySection: Sendable, Equatable, Identifiable {
        let id: Int
        let section: Section
        let segments: [HierarchySegment]
    }

    struct HierarchySegment: Sendable, Equatable, Identifiable {
        let id: Int
        let start: Double
        let end: Double
        let phrases: [HierarchyPhrase]
    }

    struct HierarchyPhrase: Sendable, Equatable, Identifiable {
        let id: Int
        let start: Double
        let end: Double
    }

    struct StructureResolution: Decodable, Sendable, Equatable {
        var status: String
        var method: String
        var candidateBoundaryCount: Int
        var acceptedBoundaryCount: Int
        var discardedBoundaryCount: Int
        var hierarchy: Hierarchy?
        var detail: String

        struct Hierarchy: Decodable, Sendable, Equatable {
            var source: String
            var sections: [Range]
            var segments: [Range]
            var phrases: [Range]
        }

        struct Range: Decodable, Sendable, Equatable {
            var start: Double
            var end: Double
        }

        enum CodingKeys: String, CodingKey {
            case status, method, hierarchy, detail
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

    private func uniqueOwner(
        of child: StructureResolution.Range,
        in parents: [StructureResolution.Range]
    ) -> Int? {
        let matches = parents.indices.filter { index in
            let parent = parents[index]
            return child.start.isFinite && child.end.isFinite && child.end > child.start
                && child.start >= parent.start && child.end <= parent.end
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private var validCanonicalSections: Bool {
        guard durationS.isFinite,
              durationS > 0,
              !sections.isEmpty,
              sections.first?.index == 0,
              (sections.first?.start ?? .infinity) <= 0.05,
              abs((sections.last?.end ?? 0) - durationS) <= 0.05 else { return false }
        return sections.allSatisfy {
            $0.start.isFinite && $0.end.isFinite
                && $0.start >= 0 && $0.end > $0.start
                && $0.end <= durationS + 0.05
        } && zip(sections, sections.dropFirst()).allSatisfy {
            abs($0.0.end - $0.1.start) <= 0.001
                && $0.0.index + 1 == $0.1.index
        }
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
