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
         "phase_order":["analysis"],
         "phases":{"analysis":{"surface":"choice","task_class":"classification","artifact_selector":"host.analysis"}},
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
            )?.destination == .interaction
        )

        let reviewContract = try JSONDecoder().decode(
            ContractData.self,
            from: Data(#"{"phase_order":["brief","production_design","treatment","storyboard","bible","shotlist","sanity","frames","render"],"phases":{"brief":{"surface":"prose","task_class":"review","artifact_selector":"host.brief"},"production_design":{"surface":"review","task_class":"review","artifact_selector":"host.production_design"},"treatment":{"surface":"prose","task_class":"review","artifact_selector":"host.treatment"},"storyboard":{"surface":"review","task_class":"review","artifact_selector":"host.storyboard"},"bible":{"surface":"review","task_class":"review","artifact_selector":"host.bible"},"shotlist":{"surface":"review","task_class":"review","artifact_selector":"host.shotlist"},"sanity":{"surface":"review","task_class":"review","artifact_selector":"host.sanity_report"},"frames":{"surface":"review","task_class":"review","artifact_selector":"host.frames_manifest"},"render":{"surface":"review","task_class":"review","artifact_selector":"host.render_manifest"}}}"#.utf8)
        )
        #expect(PipelineSurfaceRouting.route(for: "brief", contract: reviewContract,
            availablePackSurfaces: [])?.destination == .story(.brief))
        #expect(PipelineSurfaceRouting.route(for: "treatment", contract: reviewContract,
            availablePackSurfaces: [])?.destination == .story(.treatment))
        #expect(PipelineSurfaceRouting.route(for: "storyboard", contract: reviewContract,
            availablePackSurfaces: [])?.destination == .storyboard)
        #expect(PipelineSurfaceRouting.route(for: "bible", contract: reviewContract,
            availablePackSurfaces: [])?.destination == .tab(.bible))
        #expect(PipelineSurfaceRouting.route(for: "shotlist", contract: reviewContract,
            availablePackSurfaces: [])?.destination == .tab(.shotlist))
        #expect(PipelineSurfaceRouting.route(for: "sanity", contract: reviewContract,
            availablePackSurfaces: [])?.destination == .sanity)
        #expect(PipelineSurfaceRouting.route(for: "frames", contract: reviewContract,
            availablePackSurfaces: [])?.destination == .review(.frames))
        #expect(PipelineSurfaceRouting.route(for: "render", contract: reviewContract,
            availablePackSurfaces: [])?.destination == .review(.render))
        let unavailable = try #require(PipelineSurfaceRouting.route(for: "production_design",
            contract: reviewContract, availablePackSurfaces: []))
        #expect(unavailable.destination == .productionDesign)
        #expect(unavailable.label == "Production Design")

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
        #expect(contract.phaseOrder == PipelineAgentContract.musicvideoPhases)
        #expect(contract.phases["analysis"]?.artifactSelector == "host.analysis")
    }

    @Test("generic and Musicvideo navigation use their resolved native phase contracts")
    func nativeContractPhaseOrders() throws {
        PackCatalog.register(MusicvideoPack())
        let generic = try JSONDecoder().decode(
            ContractData.self,
            from: NativeCockpitReader.contractJSON()
        )
        let musicvideo = try JSONDecoder().decode(
            ContractData.self,
            from: NativeCockpitReader.contractJSON(activePack: "musicvideo")
        )

        #expect(generic.phaseOrder == coreGatePhases)
        #expect(!generic.phaseOrder.contains("analysis"))
        #expect(musicvideo.phaseOrder == PipelineAgentContract.musicvideoPhases)
        #expect(musicvideo.phaseOrder.firstIndex(of: "analysis") == 1)
    }

    @Test("artifact selectors route renamed phases without a host phase-name switch")
    func routesByArtifactSelector() throws {
        let contract = try JSONDecoder().decode(
            ContractData.self,
            from: Data(#"{"phase_order":["pack_story"],"phases":{"pack_story":{"surface":"review","task_class":"review","artifact_selector":"host.storyboard"}}}"#.utf8)
        )
        #expect(PipelineSurfaceRouting.route(
            for: "pack_story",
            contract: contract,
            availablePackSurfaces: []
        )?.destination == .storyboard)
    }

    @Test("dock readiness presents shared blockers without exposing tool or path diagnostics")
    func readinessPresentation() {
        let analysis = PipelineReadinessPresentation.current(
            selector: "host.analysis",
            phaseLabel: "Audio Analysis",
            approval: .blocked("run_phase found no analysis artifact at /tmp/private/analysis.json"),
            mutations: .ready,
            hostDecisionRequirement: nil
        )
        #expect(analysis.message == "Complete Audio Analysis with a verified beat grid and section structure.")
        #expect(!analysis.message.contains("run_phase"))
        #expect(!analysis.message.contains("/tmp"))
        #expect(analysis.diagnostic?.contains("run_phase") == true)
        #expect(analysis.action == .askAgent("run_phase found no analysis artifact at /tmp/private/analysis.json"))

        let decision = PipelineReadinessPresentation.current(
            selector: "host.production_design",
            phaseLabel: "Production Design",
            approval: .ready,
            mutations: .ready,
            hostDecisionRequirement: "Answer \u{201C}Choose a visual direction\u{201D} in Agent before changing the phase."
        )
        #expect(decision.message == "Answer \u{201C}Choose a visual direction\u{201D} in Agent before changing the phase.")
        #expect(decision.diagnostic == nil)
        #expect(decision.action == .openDecision)

        let checking = PipelineReadinessPresentation.current(
            selector: "host.frames_manifest",
            phaseLabel: "Frames",
            approval: .blocked("Checking approval readiness."),
            mutations: .blocked("Checking gate controls."),
            hostDecisionRequirement: nil,
            checking: true
        )
        #expect(checking.message == "Checking Frames editing access.")
        #expect(checking.diagnostic == nil)
        #expect(checking.action == .none)

        let substantive = "Checking frame findings requires an accepted observation."
        let actualBlocker = PipelineReadinessPresentation.current(
            selector: "host.frames_manifest",
            phaseLabel: "Frames",
            approval: .blocked(substantive),
            mutations: .ready,
            hostDecisionRequirement: nil
        )
        #expect(actualBlocker.message == "Resolve or explicitly accept the current frame findings before approval.")
        #expect(actualBlocker.diagnostic == substantive)
        #expect(actualBlocker.action == .askAgent(substantive))

        let intake = PipelineReadinessPresentation.current(
            selector: "host.project_track",
            phaseLabel: "Project Init",
            approval: .blocked("Complete the host-owned Track card before working on Project Init."),
            mutations: .ready,
            hostDecisionRequirement: nil
        )
        #expect(intake.message == "Complete the Track card before approving Project Init.")
    }

    @Test("spend status distinguishes unset limits and verified lower-bound crossings")
    func spendWarningPresentation() throws {
        func warning(
            budget: Double?, stop: Double?, spent: Double,
            complete: Bool, remaining: Double? = nil
        ) throws -> String? {
            var payload: [String: Any] = [
                "project": "fixture",
                "budget_spent_eur": spent,
                "spend_complete": complete,
            ]
            if let budget { payload["budget_eur"] = budget }
            if let stop { payload["budget_stop_eur"] = stop }
            if let remaining { payload["budget_remaining_eur"] = remaining }
            let data = try JSONSerialization.data(withJSONObject: payload)
            return try JSONDecoder().decode(ProjectStateData.self, from: data).spendWarning
        }

        #expect(try warning(budget: nil, stop: nil, spent: 0, complete: true) == nil)
        #expect(try warning(budget: 0, stop: 0, spent: 0, complete: true) == nil)
        #expect(try warning(budget: nil, stop: nil, spent: 0, complete: false) == "Spend incomplete")
        #expect(try warning(budget: 125, stop: 150, spent: 150, complete: true) == "Hard stop reached")
        #expect(try warning(budget: 125, stop: 150, spent: 150, complete: false) == "Hard stop reached · Spend incomplete")
        #expect(try warning(budget: 125, stop: nil, spent: 126, complete: false) == "Over budget · Spend incomplete")
        #expect(try warning(budget: 125, stop: nil, spent: 10, complete: false) == "Spend incomplete")
        #expect(try warning(budget: 125, stop: nil, spent: 118, complete: true, remaining: 7) == "Low budget")
    }

    @Test("navigation validation rejects stale state and selection keeps browsing separate from execution")
    func validatesNavigationAndSelection() throws {
        let contract = try JSONDecoder().decode(
            ContractData.self,
            from: Data(#"{"phase_order":["project_init","brief"],"phases":{"project_init":{"surface":"choice","task_class":"classification","artifact_selector":"host.project_track"},"brief":{"surface":"prose","task_class":"creative_long","artifact_selector":"host.brief"}}}"#.utf8)
        )
        let state = try JSONDecoder().decode(
            ProjectStateData.self,
            from: Data(#"{"project":"demo","mode":"default","phases":[{"phase":"project_init","approved":true,"state":"approved"},{"phase":"brief","approved":false,"state":"pending"}],"next_phase":"brief"}"#.utf8)
        )
        let navigation = try ProductionNavigationData.validated(contract: contract, state: state)
        #expect(navigation.state?.nextPhaseName == "brief")
        #expect(PipelineNavigationSelection.normalized(
            requestedPhase: "project_init",
            requestedTab: .pipeline,
            requestedPackSurfaceID: nil,
            state: state,
            contract: contract,
            availablePackSurfaces: []
        ) == "project_init")
        #expect(PipelineNavigationSelection.normalized(
            requestedPhase: "removed_phase",
            requestedTab: .pipeline,
            requestedPackSurfaceID: nil,
            state: state,
            contract: contract,
            availablePackSurfaces: []
        ) == "brief")
        #expect(PipelineNavigationSelection.normalized(
            requestedPhase: nil,
            requestedTab: .story,
            requestedPackSurfaceID: nil,
            state: state,
            contract: contract,
            availablePackSurfaces: []
        ) == "brief")

        let missingNext = try JSONDecoder().decode(
            ProjectStateData.self,
            from: Data(#"{"project":"demo","mode":"default","phases":[{"phase":"project_init","approved":true,"state":"approved"},{"phase":"brief","approved":false,"state":"pending"}]}"#.utf8)
        )
        #expect(missingNext.nextPhaseName == nil)
        #expect(throws: ProductionNavigationData.ValidationError.self) {
            try ProductionNavigationData.validated(contract: contract, state: missingNext)
        }

        let staleOrder = try JSONDecoder().decode(
            ProjectStateData.self,
            from: Data(#"{"project":"demo","mode":"default","phases":[{"phase":"brief","approved":false,"state":"pending"},{"phase":"project_init","approved":true,"state":"approved"}],"next_phase":"brief"}"#.utf8)
        )
        #expect(throws: ProductionNavigationData.ValidationError.self) {
            try ProductionNavigationData.validated(contract: contract, state: staleOrder)
        }
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
