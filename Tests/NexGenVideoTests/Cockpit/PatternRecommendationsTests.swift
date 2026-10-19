import Foundation
import Testing
@testable import NexGenVideo
@testable import MusicvideoPlugin
import NexGenEngine

@Suite("Native Pattern-fit presentation preserves the pack contract")
struct PatternRecommendationsTests {
    private func brief() throws -> Brief {
        try Brief(project: "pattern-project", generated: "fixture", mission: .artPiece,
            targetPlatform: "web", aspectRatio: .landscape16x9, projectMode: "section", conceptType: .narrative,
            visualMedium: .liveActionRealistic, tone: [.melancholic], figures: .artistPlusOthers,
            lyricsIntegration: .metaphorical)
    }

    private func response() throws -> Data {
        try MusicvideoPatternProvider().recommend(briefJSON: JSONEncoder().encode(brief()),
            optionsJSON: Data("{\"perceived_bpm\":92,\"match_mode\":\"balanced\"}".utf8))
    }

    @MainActor
    @Test func malformedOptionsCannotSilentlyDiscardExplicitExclusions() async throws {
        let harness = ToolHarness(enforceHardGates: true)
        let malformed: [[String: Any]] = [
            ["excluded_pattern_ids": "excluded"], ["excluded_pattern_ids": ["excluded", 2] as [Any]],
            ["match_mode": 2], ["perceived_bpm": "92"], ["top": 1.5], ["top": 51], ["excluded_ids": ["excluded"]]
        ]
        for args in malformed {
            let result = await harness.runRaw("suggest_patterns", args: args)
            #expect(result.isError)
            #expect(ToolHarness.textOf(result).contains("suggest_patterns"))
            #expect(ToolHarness.textOf(result).contains(try #require(args.keys.first)))
        }
        let provider = MusicvideoPatternProvider()
        let bytes = try JSONEncoder().encode(brief())
        for options in [
            "{\"excluded_pattern_ids\":[\"excluded\"],\"match_mode\":\"invalid\"}",
            "{\"excluded_pattern_ids\":[\"excluded\"],\"max_results\":\"5\"}",
            "{\"excluded_pattern_ids\":[\"excluded\"],\"affect_profile\":[]}",
            "{\"max_results\":-1}", "{\"max_results\":0}"
        ] {
            #expect(throws: (any Error).self) {
                try provider.recommend(briefJSON: bytes, optionsJSON: Data(options.utf8))
            }
        }
        let initial = try PatternRecommendationsModel.decode(response())
        let id = try #require(initial.recommendations?.results.first?.id)
        let options = try JSONSerialization.data(withJSONObject: ["excluded_pattern_ids": [id]])
        let excluded = try PatternRecommendationsModel.decode(provider.recommend(briefJSON: bytes, optionsJSON: options))
        #expect(excluded.recommendations?.results.first(where: { $0.id == id })?.excluded == true)
    }

    @Test func absentBriefIsOptionalButMalformedBriefIsRejected() throws {
        let provider = MusicvideoPatternProvider()
        let absent = try PatternRecommendationsModel.decode(provider.recommend(
            briefJSON: Data("null".utf8), optionsJSON: Data("{}".utf8)))
        #expect(!absent.available)
        #expect(throws: (any Error).self) {
            try provider.recommend(briefJSON: Data("{\"project\":42}".utf8), optionsJSON: Data("{}".utf8))
        }
    }

    @MainActor
    @Test func hostRecommendationProducerDistinguishesMissingAndDamagedInputs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pattern-inputs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = MusicvideoPatternProvider()
        let absent = try ToolExecutor.patternRecommendationInputs(dataRoot: root, args: [:])
        #expect(absent.brief == Data("null".utf8))
        #expect(try !PatternRecommendationsModel.decode(provider.recommend(briefJSON: absent.brief, optionsJSON: absent.options)).available)

        let value = try brief()
        let store = YAMLArtifactStore(dataRoot: root)
        try store.save(value, to: PipelineLayout.briefFile)
        let valid = try ToolExecutor.patternRecommendationInputs(dataRoot: root, args: ["match_mode": "balanced", "top": 3])
        #expect(try JSONDecoder().decode(Brief.self, from: valid.brief) == value)
        #expect(try PatternRecommendationsModel.decode(provider.recommend(briefJSON: valid.brief, optionsJSON: valid.options)).available)
        #expect(try (JSONSerialization.jsonObject(with: valid.options) as? [String: Any])?["affect_profile"] == nil)
        for invalid in [Data("project: [unterminated".utf8), Data([0xff])] {
            try invalid.write(to: root.appendingPathComponent(PipelineLayout.briefFile))
            #expect(throws: (any Error).self) { try ToolExecutor.patternRecommendationInputs(dataRoot: root, args: [:]) }
        }
        try store.save(value, to: PipelineLayout.briefFile)
        let affectURL = root.appendingPathComponent(ToolExecutor.affectFile)
        try FileManager.default.createDirectory(at: affectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let recorded = AffectProfile(detected: [.init(value: .dark, weight: 1)], override: [.init(value: .euphoric, weight: 1)])
        try JSONEncoder().encode(recorded).write(to: affectURL)
        let overridden = try ToolExecutor.patternRecommendationInputs(dataRoot: root, args: [:])
        let options = try #require(try JSONSerialization.jsonObject(with: overridden.options) as? [String: Any])
        let object = try #require(options["affect_profile"])
        let restored = try JSONDecoder().decode(AffectProfile.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.isOverridden && restored.effective.first?.value == .euphoric)
        #expect(try PatternRecommendationsModel.decode(provider.recommend(briefJSON: overridden.brief, optionsJSON: overridden.options)).available)
        for invalid in ["{", "[]", "null"] {
            try Data(invalid.utf8).write(to: affectURL)
            #expect(throws: (any Error).self) { try ToolExecutor.patternRecommendationInputs(dataRoot: root, args: [:]) }
        }
        try FileManager.default.removeItem(at: affectURL)
        try FileManager.default.createDirectory(at: affectURL, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try ToolExecutor.patternRecommendationInputs(dataRoot: root, args: [:]) }
    }

    @Test func invalidBpmAndDuplicateToneCannotInventEvidenceOrChangeWeights() throws {
        var value = try brief(); value.tone = [.melancholic, .melancholic, .dark]
        let assembled = ProjectProfileAssembler.assemble(brief: value, perceivedBpm: .infinity)
        #expect(assembled.audio.perceivedBpm == nil)
        let affects = try #require(assembled.creative.affects?.value)
        #expect(affects.map(\.value) == [.melancholic, .dark])
        #expect(affects.map(\.weight) == [0.5, 0.5])
        #expect(ProjectProfileAssembler.assemble(brief: value, perceivedBpm: 92).audio.perceivedBpm?.value == 92)
    }

    @Test func actualPackResponseKeepsEveryIndexConfidenceCoverageAndSignatureBasis() throws {
        let bytes = try response()
        let actual = try PatternRecommendationsModel.decode(bytes)
        let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let set = try #require(object["recommendations"] as? [String: Any])
        let raw = try #require(set["results"] as? [[String: Any]])
        let decoded = try #require(actual.recommendations)
        #expect(decoded.results.count == raw.count)
        for (result, original) in zip(decoded.results, raw) {
            #expect(result.patternId == original["pattern_id"] as? String)
            #expect(result.fitScore == original["fit_score"] as? Double)
            #expect(result.confidence == original["confidence"] as? Double)
            #expect(result.inputCoverage == original["input_coverage"] as? Double)
            let detailBytes = try #require(MusicvideoPatternProvider().get(id: result.id))
            let detail = try PatternRecommendationsModel.detail(detailBytes, expectedID: result.id)
            let source = try #require(try JSONSerialization.jsonObject(with: detailBytes) as? [String: Any])
            let camera = try #require(source["camera"] as? [String: Any])
            #expect(detail.evidence.first(where: { $0.id == "camera" })?.basis == camera["basis"] as? String)
        }
    }

    @Test func provisionalOrExcludedCannotBePresentedAsWinningSlots() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: response()) as? [String: Any])
        var set = try #require(object["recommendations"] as? [String: Any])
        var results = try #require(set["results"] as? [[String: Any]])
        _ = try #require(results.first)
        let id = try #require(results[0]["pattern_id"] as? String)
        results[0]["fit_band"] = "provisional"; results[0]["rank"] = NSNull()
        set["results"] = results
        set["slots"] = ["best_overall_pattern_id": id, "production_efficient_pattern_id": NSNull(), "creative_stretch_pattern_id": NSNull()]
        object["recommendations"] = set
        #expect(throws: (any Error).self) { try PatternRecommendationsModel.decode(JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func measuredBasisCannotBeInventedByAnUnknownEvidenceLabel() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: response()) as? [String: Any])
        let set = try #require(object["recommendations"] as? [String: Any])
        let raw = try #require(set["results"] as? [[String: Any]])
        let id = try #require(raw.first?["pattern_id"] as? String)
        let detailBytes = try #require(MusicvideoPatternProvider().get(id: id))
        var detail = try #require(try JSONSerialization.jsonObject(with: detailBytes) as? [String: Any])
        var camera = try #require(detail["camera"] as? [String: Any]); camera["basis"] = "certain"
        detail["camera"] = camera
        #expect(throws: (any Error).self) {
            try PatternRecommendationsModel.detail(JSONSerialization.data(withJSONObject: detail), expectedID: id)
        }
    }

    @Test func inferredAffectNeverExceedsTheLockedConfidenceCap() throws {
        let detected = AffectProfile(detected: [.init(value: .dark, weight: 1)], basis: .inferred)
        let project = ProjectProfileAssembler.assemble(brief: try brief(), affectProfile: detected)
        let affect = try #require(project.creative.affects)
        #expect(affect.source == .agentInference)
        #expect(affect.confidence <= 0.7)
        let corrected = AffectProfile(detected: detected.detected, override: [.init(value: .euphoric, weight: 1)])
        let user = try #require(ProjectProfileAssembler.assemble(brief: brief(), affectProfile: corrected).creative.affects)
        #expect(user.source == .user && user.userConfirmed && user.value.first?.value == .euphoric)
        #expect(user.confidence == 1)
    }

    @Test func commonBriefPublicationPreservesIdentityAndSynchronizesMetadata() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pattern-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "pattern-project", mode: .beat)
        let old = try YAMLArtifactStore(dataRoot: root).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        var value = try brief(); value.directorPattern = "selected-pattern"
        try PipelineBriefArtifactWriter.write(value, dataRoot: root)
        let saved = try YAMLArtifactStore(dataRoot: root).load(Brief.self, at: PipelineLayout.briefFile)
        let metadata = try YAMLArtifactStore(dataRoot: root).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        #expect(saved == value)
        #expect(metadata.project == old.project && metadata.created == old.created && metadata.mode == .section)
        value.project = "foreign-project"
        #expect(throws: (any Error).self) { try PipelineBriefArtifactWriter.write(value, dataRoot: root) }
        #expect(try YAMLArtifactStore(dataRoot: root).load(Brief.self, at: PipelineLayout.briefFile) == saved)
    }

    @MainActor
    @Test func agentStagingCannotForgeNativePatternChoices() throws {
        for path in ["brief/pattern-selection.current.v1.json", "brief/pattern-selections/test.v1.json",
                     "pipeline/brief/pattern-selections/test.recommendations.json"] {
            #expect(throws: (any Error).self) { try ToolExecutor.requirePipelineAssetCopyPath(path, source: false) }
        }
    }

    @MainActor
    @Test func optionalNativeClosureRejectsChangedBriefAndHomeFallbackAndIsInvalidatedByTheCanonicalWriter() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pattern-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "pattern-project", mode: .section)
        var value = try brief()
        try PipelineBriefArtifactWriter.write(value, dataRoot: root)
        #expect(try PipelinePatternSelectionEvidence.references(dataRoot: root).isEmpty)
        let id = UUID().uuidString.lowercased()
        value.generator = "brief-native@pattern-selection/" + id
        try PipelineBriefArtifactWriter.write(value, dataRoot: root)
        let briefBytes = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.briefFile))
        let response = try response()
        let decision = PatternRecommendationsStore.Decision(schema: "native-pattern-selection/v1", id: id,
            projectID: value.project, patternID: nil, previousPatternID: nil,
            inputFingerprint: FileDigest.sha256(of: try JSONEncoder().encode(value)), resultSHA256: FileDigest.sha256(of: response),
            selectedPatternSHA256: nil, briefSHA256: FileDigest.sha256(of: briefBytes), warnings: [],
            reason: "Isolated evidence reader fixture; no native interaction claim.", selectedAt: "fixture", restored: false)
        let prefix = "brief/pattern-selections/" + id
        for (path, bytes) in [(PatternRecommendationsStore.decisionPath, try PlanningWriterIO.json(decision)),
                              (prefix + ".v1.json", try PlanningWriterIO.json(decision)),
                              (prefix + ".recommendations.json", response), (prefix + ".brief.yaml", briefBytes)] {
            _ = try ProjectLocalFile.ensureDirectory((path as NSString).deletingLastPathComponent, dataRoot: root)
            try bytes.write(to: root.appendingPathComponent(path))
        }
        #expect(!(try PipelinePatternSelectionEvidence.references(dataRoot: root)).isEmpty)
        var changed = value; changed.notes = "Changed without updating the native choice."
        try YAMLArtifactStore(dataRoot: root).save(changed, to: PipelineLayout.briefFile)
        #expect(throws: (any Error).self) { try PipelinePatternSelectionEvidence.references(dataRoot: root) }
        try briefBytes.write(to: root.appendingPathComponent(PipelineLayout.briefFile))
        let archivePath = prefix + ".recommendations.json"
        let alias = home.appendingPathComponent(archivePath)
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try response.write(to: alias)
        try FileManager.default.removeItem(at: root.appendingPathComponent(archivePath))
        #expect(throws: (any Error).self) { try PipelinePatternSelectionEvidence.references(dataRoot: root) }
        try response.write(to: root.appendingPathComponent(archivePath))
        try PipelineBriefArtifactWriter.write(changed, dataRoot: root)
        #expect(try PipelinePatternSelectionEvidence.references(dataRoot: root).isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(prefix + ".v1.json").path))
    }
}
