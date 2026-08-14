import Foundation
import MusicvideoPlugin
import NexGenEngine
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

    @Test("macOS 26 evidence-resolved sections are canonical without a nested hierarchy")
    func decodesEvidenceResolvedStructure() throws {
        let json = """
        {
          "song_path":"audio/song.mp3","duration_s":64,"bpm":120,
          "beats":[0,0.5,1],"downbeats":[0,2,4],
          "sections":[
            {"index":0,"start":0,"end":16,"source":"measured_track_extent"},
            {"index":1,"start":16,"end":40,"source":"measured_consensus"},
            {"index":2,"start":40,"end":64,"source":"measured_alignment_fusion"}
          ],
          "structure_resolution":{
            "status":"resolved","method":"per_boundary_evidence",
            "candidate_boundary_count":4,"accepted_boundary_count":2,
            "discarded_boundary_count":0,
            "detail":"Every boundary has measured evidence."
          }
        }
        """
        let data = try JSONDecoder().decode(
            AnalysisSurfaceData.self,
            from: Data(json.utf8)
        )

        #expect(data.hasCanonicalStructure)
        #expect(!data.hasNestedHierarchy)
        #expect(!data.requiresStructureReview)
        #expect(data.canonicalHierarchy?.map(\.section.start) == [0, 16, 40])
        #expect(data.canonicalHierarchy?.allSatisfy { $0.segments.isEmpty } == true)

        let review = json.replacingOccurrences(
            of: "\"status\":\"resolved\"",
            with: "\"status\":\"review_required\""
        ).replacingOccurrences(
            of: "\"method\":\"per_boundary_evidence\"",
            with: "\"method\":\"phrase_filtered_acoustic\""
        )
        let reviewData = try JSONDecoder().decode(
            AnalysisSurfaceData.self,
            from: Data(review.utf8)
        )
        #expect(reviewData.hasCanonicalStructure)
        #expect(reviewData.requiresStructureReview)
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

    @Test("the analysis panel projects only its active project analysis run over last-known data")
    func remeasurementPresentationIsProjectAndPhaseBound() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-panel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let running = PipelinePhaseExecutionSnapshot(
            runID: UUID(),
            projectRootPath: root.standardizedFileURL.resolvingSymlinksInPath().path,
            phase: "analysis",
            sourceFilename: "song.mp3",
            stageID: "measure_structure",
            completedUnitCount: 3,
            totalUnitCount: 7,
            nextStageID: "align_lyrics",
            status: .running
        )

        let presentation = AnalysisRemeasurementPresentation.current(
            execution: running,
            dataRoot: root,
            fallbackTrackName: "fallback.mp3"
        )
        #expect(presentation?.trackName == "song.mp3")
        #expect(presentation?.completedUnitCount == 3)
        #expect(presentation?.totalUnitCount == 7)

        var completed = running
        completed.status = .completed
        #expect(AnalysisRemeasurementPresentation.current(
            execution: completed,
            dataRoot: root,
            fallbackTrackName: "fallback.mp3"
        ) == nil)
        let otherPhase = PipelinePhaseExecutionSnapshot(
            runID: UUID(),
            projectRootPath: running.projectRootPath,
            phase: "brief",
            sourceFilename: running.sourceFilename,
            stageID: running.stageID,
            completedUnitCount: running.completedUnitCount,
            totalUnitCount: running.totalUnitCount,
            nextStageID: running.nextStageID,
            status: .running
        )
        #expect(AnalysisRemeasurementPresentation.current(
            execution: otherPhase,
            dataRoot: root,
            fallbackTrackName: "fallback.mp3"
        ) == nil)
        #expect(AnalysisRemeasurementPresentation.current(
            execution: running,
            dataRoot: root.appendingPathComponent("other"),
            fallbackTrackName: "fallback.mp3"
        ) == nil)
        var awaitingFirstStage = running
        awaitingFirstStage.stageID = nil
        #expect(AnalysisRemeasurementPresentation.current(
            execution: awaitingFirstStage,
            dataRoot: root,
            fallbackTrackName: "fallback.mp3"
        ) == nil)
    }

    @Test("ContractData decodes pack-contributed cockpit_surfaces; legacy files decode empty")
    func contractCockpitSurfaces() throws {
        let json = """
        {"surfaces":["choice","prose","review"],
         "phases":{"analysis":{"surface":"choice","task_class":"classification"}},
         "cockpit_surfaces":[{
           "id":"analysis","title":"Analysis","symbol":"waveform","phase":"analysis",
           "data_file":"analysis/{songStem}.json",
           "layout":[
             {"type":"statRow","items":[
               {"label":"Tempo","field":"bpm","format":"bpm","factor_field":"tempo_multiplier","visibility":"always"}
             ]},
             {"type":"beatTimeline","title":"Beat grid","duration_field":"duration_s","beats_field":"beats","downbeats_field":"downbeats","sections_field":"sections","sections_visibility":"whenCanonicalSections"},
             {"type":"sectionList","title":"Song structure","sections_field":"sections","visibility":"whenCanonicalSections"}
           ]
         }]}
        """
        let c = try JSONDecoder().decode(ContractData.self, from: Data(json.utf8))
        #expect(c.cockpitSurfaces.count == 1)
        #expect(c.cockpitSurfaces.first?.id == "analysis")
        #expect(c.cockpitSurfaces.first?.dataFile == "analysis/{songStem}.json")
        #expect(c.cockpitSurfaces.first?.layout.count == 3)
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

    @Test("native contract serializes the pack's declarative surface")
    func nativeContractSurface() throws {
        PackCatalog.register(MusicvideoPack())
        let data = try NativeCockpitReader.contractJSON(activePack: "musicvideo")
        let contract = try JSONDecoder().decode(ContractData.self, from: data)
        let surface = try #require(contract.cockpitSurfaces.first)
        #expect(surface.id == "analysis")
        #expect(surface.dataFile == "analysis/{songStem}.json")
        #expect(surface.layout.count == 3)
    }

    @Test("pack data resolver is project-local, JSON-only, and unambiguous")
    func packDataResolver() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngv-pack-surface-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let analysis = root.appendingPathComponent("analysis", isDirectory: true)
        let audio = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data().write(to: audio.appendingPathComponent("song.mp3"))
        let artifact = analysis.appendingPathComponent("song.json")
        try Data("{}".utf8).write(to: artifact)

        #expect(
            PackSurfaceDataResolver.resolve(
                dataRoot: root,
                pattern: "analysis/{songStem}.json"
            )
                == artifact
        )
        #expect(PackSurfaceDataResolver.resolve(dataRoot: root, pattern: "../secret.json") == nil)
        #expect(PackSurfaceDataResolver.resolve(dataRoot: root, pattern: "analysis/*.yaml") == nil)
        #expect(PackSurfaceDataResolver.resolve(dataRoot: root, pattern: "analysis/*.json") == nil)
        #expect(PackSurfaceDataResolver.resolve(dataRoot: root, pattern: "analysis/{unknown}.json") == nil)
    }

    @Test("pack surface document resolves declared fields without a surface-specific switch")
    func packSurfaceDocumentBindings() throws {
        let document = try PackSurfaceDocument(data: Data(Self.analysisJSON.utf8))
        #expect(document.string(at: "song_path") == "audio/midnight_drive.wav")
        #expect(document.number(at: "duration_s") == 222)
        #expect(document.numbers(at: "beats") == [0, 0.47, 0.94, 1.41])
        #expect(document.count(at: "sections") == 2)
    }

    @Test("canonical section validation never replaces the pack-declared field")
    func canonicalSectionBindingUsesDeclaredField() throws {
        let analysis = try JSONDecoder().decode(
            AnalysisSurfaceData.self,
            from: Data(Self.analysisJSON.utf8)
        )
        let declared = """
        {"declared_sections":[
          {"index":0,"start":0,"end":27,"label":"Intro","source":"measured_system_hierarchy"},
          {"index":1,"start":27,"end":71,"label":"Verse 1","source":"measured_system_hierarchy"}
        ]}
        """
        let document = try PackSurfaceDocument(data: Data(declared.utf8))

        let sections = PackSurfaceSectionBinding.sections(
            document: document,
            field: "declared_sections",
            visibility: .whenCanonicalSections,
            analysis: analysis
        )
        #expect(sections == analysis.sections)
        #expect(PackSurfaceSectionBinding.sections(
            document: document,
            field: "sections",
            visibility: .whenCanonicalSections,
            analysis: analysis
        ).isEmpty)

        let hierarchy = PackSurfaceSectionBinding.hierarchy(
            document: document,
            field: "declared_sections",
            visibility: .whenCanonicalSections,
            analysis: analysis
        )
        #expect(hierarchy.map(\.section) == sections)
        #expect(hierarchy.flatMap(\.segments).count == 2)
    }
}
