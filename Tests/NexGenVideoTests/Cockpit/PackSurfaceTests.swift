import Foundation
import Testing
@testable import NexGenVideo

@Suite("Pack surface — host decoders")
struct PackSurfaceTests {

    private static let analysisJSON = """
    {
      "schema": "analysis/v3",
      "project": "demo",
      "song_path": "audio/midnight_drive.wav",
      "sample_rate": 44100,
      "duration_s": 222.0,
      "bpm": 128.0,
      "tempo_multiplier": 1.0,
      "key": "A minor",
      "downbeat_source": "music-understanding",
      "beats": [0.0, 0.47, 0.94, 1.41],
      "downbeats": [0.0, 1.88],
      "sections": [
        {"index": 0, "start": 0.0, "end": 27.0, "cluster": 0, "label": "Intro", "source": "measured_system_hierarchy"},
        {"index": 1, "start": 27.0, "end": 71.0, "cluster": 1, "label": "Verse 1", "source": "measured_system_hierarchy"}
      ],
      "structure_resolution": {
        "status": "resolved",
        "method": "music_understanding_hierarchy",
        "candidate_boundary_count": 40,
        "accepted_boundary_count": 1,
        "discarded_boundary_count": 39,
        "hierarchy": {
          "source": "apple_music_understanding",
          "sections": [{"start":0,"end":27},{"start":27,"end":71}],
          "segments": [{"start":0,"end":27},{"start":27,"end":71}],
          "phrases": [{"start":0,"end":13.5},{"start":13.5,"end":27},{"start":27,"end":71}]
        },
        "detail": "Measured system hierarchy."
      },
      "stage_diagnostics": [
        {"stage": "lyrics_alignment", "status": "succeeded", "detail": "Anchored all markers."}
      ]
    }
    """

    @Test("AnalysisSurfaceData decodes the analysis/v3 fields the panel renders")
    func decodesAnalysisArtifact() throws {
        let d = try JSONDecoder().decode(AnalysisSurfaceData.self, from: Data(Self.analysisJSON.utf8))
        #expect(d.trackName == "midnight_drive.wav")
        #expect(d.durationS == 222.0)
        #expect(d.perceivedBpm == 128.0)
        #expect(d.key == "A minor")
        #expect(d.downbeatSource == "music-understanding")
        #expect(d.beats.count == 4)
        #expect(d.downbeats.count == 2)
        #expect(d.hasBeatGrid)
        #expect(d.hasCanonicalStructure)
        #expect(d.structureResolution?.candidateBoundaryCount == 40)
        #expect(d.structureResolution?.hierarchy?.segments.count == 2)
        let hierarchy = try #require(d.canonicalHierarchy)
        #expect(hierarchy.count == 2)
        #expect(hierarchy[0].section.label == "Intro")
        #expect(hierarchy[0].segments.count == 1)
        #expect(hierarchy[0].segments[0].phrases.map(\.end) == [13.5, 27.0])
        #expect(hierarchy[1].segments[0].phrases[0].start == 27.0)
        #expect(d.stageDiagnostics.count == 1)
        #expect(d.nonSuccessStageDiagnostics.isEmpty)
        #expect(d.sections.count == 2)
        #expect(d.sections.first?.label == "Intro")
        #expect(d.sections.last?.end == 71.0)
    }

    @Test("failed, degraded, and unavailable stages remain visible")
    func nonSuccessStageDiagnostics() throws {
        let json = Self.analysisJSON.replacingOccurrences(
            of: "\"status\": \"succeeded\"",
            with: "\"status\": \"unavailable\""
        )
        let data = try JSONDecoder().decode(AnalysisSurfaceData.self, from: Data(json.utf8))
        #expect(data.nonSuccessStageDiagnostics.map(\.status) == ["unavailable"])
    }

    @Test("perceivedBpm applies the confirmed tempo multiplier")
    func perceivedBpmUsesMultiplier() throws {
        let json = Self.analysisJSON.replacingOccurrences(of: "\"tempo_multiplier\": 1.0", with: "\"tempo_multiplier\": 2.0")
        let d = try JSONDecoder().decode(AnalysisSurfaceData.self, from: Data(json.utf8))
        #expect(d.perceivedBpm == 256.0)
    }

    @Test("a beatless track decodes as degraded (no beat grid)")
    func degradedWhenNoBeats() throws {
        let json = Self.analysisJSON
            .replacingOccurrences(of: "\"beats\": [0.0, 0.47, 0.94, 1.41]", with: "\"beats\": []")
            .replacingOccurrences(of: "\"downbeats\": [0.0, 1.88]", with: "\"downbeats\": []")
        let d = try JSONDecoder().decode(AnalysisSurfaceData.self, from: Data(json.utf8))
        #expect(!d.hasBeatGrid)
        #expect(d.key == "A minor")   // still usable
    }

    @Test("missing or unresolved structure is never presented as canonical")
    func unresolvedStructure() throws {
        let legacy = """
        {"song_path":"audio/song.wav","duration_s":12,"bpm":120,
         "beats":[0,0.5],"downbeats":[0,2],"sections":[]}
        """
        let legacyData = try JSONDecoder().decode(AnalysisSurfaceData.self, from: Data(legacy.utf8))
        #expect(!legacyData.hasCanonicalStructure)

        let unresolved = Self.analysisJSON.replacingOccurrences(of: "\"status\": \"resolved\"", with: "\"status\": \"needs_review\"")
        let unresolvedData = try JSONDecoder().decode(AnalysisSurfaceData.self, from: Data(unresolved.utf8))
        #expect(!unresolvedData.hasCanonicalStructure)

        let wrongSource = Self.analysisJSON.replacingOccurrences(
            of: "\"source\": \"apple_music_understanding\"",
            with: "\"source\": \"librosa\""
        )
        let wrongSourceData = try JSONDecoder().decode(
            AnalysisSurfaceData.self,
            from: Data(wrongSource.utf8)
        )
        #expect(!wrongSourceData.hasCanonicalStructure)

        let unnestedPhrase = Self.analysisJSON.replacingOccurrences(
            of: #"{"start":27,"end":71}"#,
            with: #"{"start":26,"end":71}"#,
            options: [],
            range: Self.analysisJSON.range(of: #""phrases": [{"start":0,"end":13.5},{"start":13.5,"end":27},{"start":27,"end":71}]"#)
        )
        let unnestedData = try JSONDecoder().decode(
            AnalysisSurfaceData.self,
            from: Data(unnestedPhrase.utf8)
        )
        #expect(!unnestedData.hasCanonicalStructure)
    }

    @Test("measured hierarchy timecodes preserve centisecond evidence")
    func measuredHierarchyTimecodes() {
        #expect(PackSurfaceFormat.measuredTimecode(59.999) == "1:00.00")
        #expect(PackSurfaceFormat.measuredTimecode(71.234) == "1:11.23")
    }

    @Test("ContractData decodes pack-contributed cockpit_surfaces; legacy files decode empty")
    func contractCockpitSurfaces() throws {
        let json = """
        {"surfaces":["choice","prose","review"],
         "phases":{"analysis":{"surface":"choice","task_class":"classification"}},
         "cockpit_surfaces":[{"id":"analysis","title":"Analysis","symbol":"waveform","phase":"analysis","kind":"beatAnalysis"}]}
        """
        let c = try JSONDecoder().decode(ContractData.self, from: Data(json.utf8))
        #expect(c.cockpitSurfaces.count == 1)
        #expect(c.cockpitSurfaces.first?.id == "analysis")
        #expect(c.cockpitSurfaces.first?.kind == "beatAnalysis")
        #expect(c.cockpitSurfaces.first?.symbol == "waveform")
        #expect(
            PipelineSurfaceRouting.route(
                for: "analysis",
                contract: c,
                availablePackSurfaces: c.cockpitSurfaces
            )?.destination == .pack("analysis")
        )
        #expect(
            PipelineSurfaceRouting.route(
                for: "analysis",
                contract: c,
                availablePackSurfaces: []
            )?.destination == .chat
        )

        let legacy = try JSONDecoder().decode(ContractData.self, from: Data(#"{"phases":{}}"#.utf8))
        #expect(legacy.cockpitSurfaces.isEmpty)
    }
}
