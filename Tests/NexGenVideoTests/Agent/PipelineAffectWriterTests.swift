import Foundation
import Testing
@testable import NexGenVideo
@testable import MusicvideoPlugin
import NexGenEngine

@Suite("Section affect evidence and creative consumers")
struct PipelineAffectWriterTests {
    @Test("contrast fixtures preserve measurements and attributed interpretations without judging creative truth")
    func contrastFixtures() throws {
        let examples: [(String, Double, Double, String, String)] = [
            ("C", 84, 0.03, "Sparse piano, fragile delivery.", "fragile"),
            ("Am", 168, 0.8, "Dense drums, dark distorted texture.", "tense"),
            ("C", 84, 0.8, "Dense brass, forceful delivery.", "anthemic"),
        ]
        for (chord, bpm, energy, context, tag) in examples {
            let fixture = try Fixture(chord: chord, bpm: bpm, energy: energy, context: context)
            defer { fixture.remove() }
            let profile = try PipelineAffectWriter.write(fixture.args(tag: tag), dataRoot: fixture.root)
            let evidence = try #require(profile[MusicAffectEvidenceV1.key] as? [String: Any])
            let source = try #require(evidence["source"] as? [String: Any])
            let sections = try #require(source["sections"] as? [[String: Any]])
            let signals = try #require(sections[0]["signals"] as? [String: Any])
            let harmony = try #require(signals["harmony"] as? [String: Any])
            let values = try #require(harmony["value"] as? [[String: Any]])
            #expect(values.first?["label"] as? String == chord)
            #expect(harmony["basis"] as? String == "estimated")
            #expect((signals["instrumentation"] as? [String: Any])?["basis"] as? String == "unavailable")
            #expect((signals["context"] as? [String: Any])?["basis"] as? String == "inferred")
            let view = try #require(MusicAffectEvidenceV1.presentation(dataRoot: fixture.root))
            #expect(view.contains(tag))
            #expect(view.contains(context))
            #expect(view.contains("conflict: harmony"))
            #expect(view.contains("not a subjective creative-quality verdict"))
        }
    }

    @Test("aligned contradictory lyrics stay separately attributed; unaligned lyrics cannot support a section")
    func lyricsConflictAndMissingProof() throws {
        let fixture = try Fixture(alignedLyrics: true)
        defer { fixture.remove() }
        var args = fixture.args(tag: "fragile")
        var evidence = try #require(args[MusicAffectEvidenceV1.key] as? [String: Any])
        var sections = try #require(evidence["sections"] as? [[String: Any]])
        sections[0]["conflicts"] = ["harmony", "lyrics"]
        sections[0]["rationale"] = "Measured sparse dynamics support fragility while the aligned words 'We won' suggest triumph; retain the disagreement."
        evidence["sections"] = sections
        args[MusicAffectEvidenceV1.key] = evidence
        _ = try PipelineAffectWriter.write(args, dataRoot: fixture.root)
        let view = try #require(MusicAffectEvidenceV1.presentation(dataRoot: fixture.root))
        #expect(view.contains("We won"))
        #expect(view.contains("conflict: harmony, lyrics"))
        var proof = try fixture.object("analysis/song.measurement-proof.json")
        proof.removeValue(forKey: "lyrics_alignment")
        try fixture.write(proof, "analysis/song.measurement-proof.json")
        #expect(throws: (any Error).self) { try MusicAffectEvidenceV1.requireCurrent(dataRoot: fixture.root) }
        #expect(throws: (any Error).self) { try PipelineAffectWriter.write(args, dataRoot: fixture.root) }
    }

    @Test("instrumental, missing chords, unreliable key and absent provider data allow bounded abstention")
    func abstentionWithoutFabricatedEvidence() throws {
        let fixture = try Fixture(chord: nil)
        defer { fixture.remove() }
        var analysis = try fixture.object("analysis/song.json")
        analysis["key"] = "uncertain"
        analysis["stage_diagnostics"] = [["stage": "optional_provider", "status": "failed"]]
        try fixture.write(analysis, "analysis/song.json")
        let profile = try PipelineAffectWriter.write(fixture.args(tag: nil), dataRoot: fixture.root)
        let view = try #require(MusicAffectEvidenceV1.presentation(dataRoot: fixture.root))
        #expect((profile["detected"] as? [[String: Any]])?.isEmpty == true)
        #expect(view.contains("Abstention: Insufficient reliable emotional evidence."))
        #expect(view.contains("lyrics [unavailable"))
        #expect(view.contains("provider [unavailable"))
        #expect(view.contains("optional_provider"))
        #expect(view.contains("uncertain"))
        #expect(MusicAffectEvidenceV1.confidence(profile) == 0)
    }

    @Test("invalid references, unknown timing and excessive inference confidence cannot be persisted")
    func invalidDraftsLeaveOriginalBytes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try PipelineAffectWriter.write(fixture.args(), dataRoot: fixture.root)
        let original = try Data(contentsOf: fixture.root.appendingPathComponent(MusicAffectEvidenceV1.path))
        for mutation in ["confidence", "timing", "unavailable", "duplicate", "override"] {
            var args = fixture.args()
            var evidence = try #require(args[MusicAffectEvidenceV1.key] as? [String: Any])
            var sections = try #require(evidence["sections"] as? [[String: Any]])
            switch mutation {
            case "confidence": sections[0]["confidence"] = 0.71
            case "timing": sections[0]["start"] = 0.5
            case "unavailable": sections[0]["support"] = ["provider"]
            case "duplicate": sections[1]["index"] = 0
            default:
                args["override_action"] = "set"
                args["override"] = [["tag": "dark", "weight": 1]]
                args["override_reason"] = "User requested a dark contrast."
            }
            evidence["sections"] = sections
            args[MusicAffectEvidenceV1.key] = evidence
            #expect(throws: (any Error).self) { try PipelineAffectWriter.write(args, dataRoot: fixture.root) }
            #expect(try Data(contentsOf: fixture.root.appendingPathComponent(MusicAffectEvidenceV1.path)) == original)
        }
    }

    @Test("an explicit override survives re-recording and drives treatment and real Visual Arc prompt directives")
    func overrideReachesCreativeConsumer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var args = fixture.args(desired: "dark")
        args["override_action"] = "set"
        args["override"] = [["tag": "dark", "weight": 1]]
        args["override_reason"] = "User wants an unsettling visual contrast."
        _ = try PipelineAffectWriter.write(args, dataRoot: fixture.root)
        let profile = try PipelineAffectWriter.write(fixture.args(desired: "dark"), dataRoot: fixture.root)
        #expect((profile["override"] as? [[String: Any]])?.first?["value"] as? String == "dark")
        #expect((profile["detected"] as? [[String: Any]])?.first?["value"] as? String == "fragile")
        let view = try #require(MusicAffectEvidenceV1.presentation(dataRoot: fixture.root))
        #expect(view.contains("Detected: fragile"))
        #expect(view.contains("Desired video affect: dark"))
        #expect(view.contains("User wants an unsettling visual contrast."))
        try MusicAffectEvidenceV1.requireTreatment("A dark abstract treatment.\n" + view, dataRoot: fixture.root)
        #expect(throws: (any Error).self) { try MusicAffectEvidenceV1.requireTreatment("A generic mood label.", dataRoot: fixture.root) }
        let shotlist = try fixture.shotlist()
        let arc = fixture.arc(direction: "dark: Let a narrow cold light contract around the recurring circle.")
        try MusicAffectEvidenceV1.requireVisualArc(arc, shotlist: shotlist, dataRoot: fixture.root)
        let directives = PipelineMusicvideoProductionWriter.visualArcDirectives(visualArc: arc, shotID: "s001")
        #expect(directives.contains { $0.contains("dark: Let a narrow cold light contract") })
        #expect(throws: (any Error).self) {
            try MusicAffectEvidenceV1.requireVisualArc(fixture.arc(direction: "fragile: Ignore the user's contrary choice."), shotlist: shotlist, dataRoot: fixture.root)
        }
        var clear = fixture.args()
        clear["override_action"] = "clear"
        clear["override_reason"] = "User returned to the detected mood."
        let cleared = try PipelineAffectWriter.write(clear, dataRoot: fixture.root)
        #expect(cleared["override"] == nil)
        #expect(cleared["override_clear_reason"] as? String == "User returned to the detected mood.")
    }

    @Test("exact changed source bytes invalidate evidence and downstream consumers")
    func sourceMutationInvalidates() throws {
        for path in ["audio/song.wav", "analysis/song.json", "analysis/song.measurement-proof.json", "lyrics/lyrics.txt", "analysis/transcript.json"] {
            let fixture = try Fixture(alignedLyrics: true)
            defer { fixture.remove() }
            _ = try PipelineAffectWriter.write(fixture.args(), dataRoot: fixture.root)
            let view = try #require(MusicAffectEvidenceV1.presentation(dataRoot: fixture.root))
            for phase in ["brief", "treatment", "shotlist"] {
                try PipelineLineageStore.record(phase: phase, snapshot: MusicvideoPipelineLineage.snapshot(phase: phase, dataRoot: fixture.root), dataRoot: fixture.root)
                try MusicvideoPipelineLineage.requireCurrent(phase: phase, dataRoot: fixture.root)
            }
            var bytes = try Data(contentsOf: fixture.root.appendingPathComponent(path))
            bytes.append(0x20)
            try bytes.write(to: fixture.root.appendingPathComponent(path))
            for phase in ["brief", "treatment", "shotlist"] {
                #expect(throws: (any Error).self) { try MusicvideoPipelineLineage.requireCurrent(phase: phase, dataRoot: fixture.root) }
            }
            #expect(throws: (any Error).self) { try MusicAffectEvidenceV1.requireCurrent(dataRoot: fixture.root) }
            #expect(throws: (any Error).self) { try MusicAffectEvidenceV1.requireTreatment(view, dataRoot: fixture.root) }
            #expect(throws: (any Error).self) {
                try MusicAffectEvidenceV1.requireVisualArc(fixture.arc(direction: "fragile: Let a narrow cold light contract around the recurring circle."), shotlist: fixture.shotlist(), dataRoot: fixture.root)
            }
        }
    }

    @Test("legacy typed round-trip cannot erase the extension or bypass its canonical writer")
    func legacyRoundTripPreservesBytes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try PipelineAffectWriter.write(fixture.args(), dataRoot: fixture.root)
        let url = fixture.root.appendingPathComponent(MusicAffectEvidenceV1.path)
        let original = try Data(contentsOf: url)
        var decoded = try JSONDecoder().decode(AffectProfile.self, from: original)
        try decoded.save(dataRoot: fixture.root)
        #expect(try Data(contentsOf: url) == original)
        decoded.override = [WeightedAffect(value: .dark, weight: 1)]
        #expect(throws: (any Error).self) { try decoded.save(dataRoot: fixture.root) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("old projects stay readable; the new pack requires evidence and retains the vocabulary")
    func legacyAndVocabulary() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try MusicAffectEvidenceV1.requireCurrent(dataRoot: fixture.root)
        try MusicAffectEvidenceV1.requireTreatment("Legacy treatment", dataRoot: fixture.root)
        let binding: [String: Any] = ["activePlugin": "musicvideo", "activePluginVersion": "0.6.0"]
        try MusicAffectEvidenceV1.canonical(binding).write(to: fixture.home.appendingPathComponent("ngv.json"))
        try MusicAffectEvidenceV1.requireCurrent(dataRoot: fixture.root)
        try MusicAffectEvidenceV1.requireTreatment("Legacy treatment after explicit pack update", dataRoot: fixture.root)
        var legacyWrite = fixture.args()
        legacyWrite.removeValue(forKey: MusicAffectEvidenceV1.key)
        #expect(throws: (any Error).self) { try PipelineAffectWriter.write(legacyWrite, dataRoot: fixture.root) }
        #expect(Set(MusicAffectEvidenceV1.tags) == Set(AffectTag.allCases.map(\.rawValue)))
        #expect(Set(MusicAffectEvidenceV1.tags) == Set(AffectTagVocabulary.all))
        let profile = AffectProfile(detected: [WeightedAffect(value: .fragile, weight: 1)])
        let brief = try Brief(project: "demo", generated: "fixture", mission: .demo, targetPlatform: "web", aspectRatio: .landscape16x9, projectMode: "beat", conceptType: .abstract, visualMedium: .liveActionRealistic, figures: .none, lyricsIntegration: .ignored)
        #expect(ProjectProfileAssembler.assemble(brief: brief, affectProfile: profile).creative.affects?.confidence == 0.7)
    }

    @Test("the actual Pattern Fit provider uses evidence confidence, explicit override and abstention")
    func patternProviderConsumesEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let brief = try Brief(project: "demo", generated: "fixture", mission: .demo, targetPlatform: "web", aspectRatio: .landscape16x9, projectMode: "beat", conceptType: .abstract, visualMedium: .liveActionRealistic, tone: [.euphoric], figures: .none, lyricsIntegration: .ignored)
        for mode in ["detection", "override", "abstention"] {
            var args = fixture.args(tag: mode == "abstention" ? nil : "fragile", desired: mode == "override" ? "dark" : nil)
            if mode == "override" {
                args["override_action"] = "set"
                args["override"] = [["tag": "dark", "weight": 1]]
                args["override_reason"] = "Deliberate contrary intent."
            } else if mode == "abstention" {
                args["override_action"] = "clear"
                args["override_reason"] = "User withdraws the desired affect."
            }
            let profile = try PipelineAffectWriter.write(args, dataRoot: fixture.root)
            let typed = try JSONDecoder().decode(AffectProfile.self, from: MusicAffectEvidenceV1.canonical(profile))
            var expected = ProjectProfileAssembler.assemble(brief: brief, affectProfile: typed)
            if mode == "detection" { expected.creative.affects?.confidence = 0.6 }
            if mode == "abstention" { expected.creative.affects = nil }
            let response = try MusicvideoPatternProvider().recommend(briefJSON: JSONEncoder().encode(brief), optionsJSON: MusicAffectEvidenceV1.canonical(["affect_profile": profile]))
            let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
            let recommendations = try #require(object["recommendations"] as? [String: Any])
            #expect(recommendations["project_profile_sha256"] as? String == FileDigest.sha256(of: try PatternFitLibrary.canonicalJSON(expected)))
            #expect(recommendations["score_semantics"] as? String == "compatibility_index_not_probability")
        }
    }

    @Test("artifact displays show actual source evidence and never mistake affect for analysis")
    func existingArtifactDisplayConsumesEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let brief = try Brief(project: "demo", generated: "fixture", mission: .demo, targetPlatform: "web", aspectRatio: .landscape16x9, projectMode: "beat", conceptType: .abstract, visualMedium: .liveActionRealistic, figures: .none, lyricsIntegration: .ignored)
        try YAMLArtifactStore(dataRoot: fixture.root).save(brief, to: PipelineLayout.briefFile)
        _ = try PipelineAffectWriter.write(fixture.args(), dataRoot: fixture.root)
        #expect(ShowArtifact.gate("brief", dataRoot: fixture.root).contains("Detected: fragile"))
        let analysis = ShowArtifact.gate("analysis", dataRoot: fixture.root)
        #expect(analysis.contains("84.0"))
        #expect(analysis.contains("Section evidence for affect interpretation"))
        #expect(analysis.contains("changes_per_second"))
    }

    private struct Fixture {
        let home: URL
        let root: URL

        init(chord: String? = "C", bpm: Double = 84, energy: Double = 0.03, context: String = "Sparse piano, fragile delivery.", alignedLyrics: Bool = false) throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("affect-evidence-" + UUID().uuidString)
            root = try ProjectScaffold.initProject(home: home, name: "demo")
            for dir in ["audio", "analysis", "lyrics"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
            }
            let track = Data("synthetic source bytes; not runtime audio evidence".utf8)
            try track.write(to: root.appendingPathComponent("audio/song.wav"))
            let hash = FileDigest.sha256(of: track)
            let chords: [[String: Any]] = chord.map {
                [["start": 0, "end": 2, "label": $0], ["start": 2, "end": 8, "label": "G"]]
            } ?? []
            var analysis: [String: Any] = [
                "project": "demo", "schema": "analysis/v3", "song_path": "audio/song.wav", "song_sha256": hash,
                "duration_s": 8, "sample_rate": 48000, "bpm": bpm, "tempo_multiplier": 1,
                "beats": [0, 1, 2, 3, 4, 5, 6, 7], "downbeats": [0, 4],
                "sections": [["index": 0, "start": 0, "end": 4], ["index": 1, "start": 4, "end": 8]],
                "energy_curve": [["t": 1, "rms": energy], ["t": 5, "rms": energy * 2]],
                "interpretation": ["overall_character": context], "alignment": [],
                "chord_progression": chords,
            ]
            var proof: [String: Any] = ["schema": "analysis_measurement_proof/v1", "project": "demo", "song_sha256": hash]
            if alignedLyrics {
                let text = Data("We won".utf8)
                try text.write(to: root.appendingPathComponent("lyrics/lyrics.txt"))
                let lines: [[String: Any]] = [["start": 1, "end": 2, "text": "We won", "words": [["start": 1, "end": 1.4, "text": "We", "score": 0.9], ["start": 1.4, "end": 2, "text": "won", "score": 0.9]]]]
                let source = Data("{}".utf8)
                try source.write(to: root.appendingPathComponent("analysis/transcript.json"))
                analysis["alignment"] = lines
                proof["lyrics_alignment"] = [
                    "source_path": "analysis/transcript.json", "source_sha256": FileDigest.sha256(of: source),
                    "lyrics_sha256": FileDigest.sha256(of: text),
                    "alignment_sha256": FileDigest.sha256(of: try MusicAffectEvidenceV1.canonical(lines)),
                    "timing_evidence": "recognized_speech", "lyric_token_count": 2, "matched_token_count": 2,
                ]
            }
            try write(analysis, "analysis/song.json")
            try write(proof, "analysis/song.measurement-proof.json")
        }

        func remove() { try? FileManager.default.removeItem(at: home) }
        func write(_ value: [String: Any], _ path: String) throws {
            try MusicAffectEvidenceV1.canonical(value).write(to: root.appendingPathComponent(path))
        }
        func object(_ path: String) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(path))) as? [String: Any])
        }
        func args(tag: String? = "fragile", desired: String? = nil) -> [String: Any] {
            let detected = tag.map { [["value": $0, "weight": 1] as [String: Any]] } ?? []
            let sections: [[String: Any]] = (0...1).map { index in
                var section: [String: Any] = [
                    "index": index, "detected": detected, "confidence": tag == nil ? 0 : 0.6,
                    "support": tag == nil ? [] : ["energy", "rhythm", "context"], "conflicts": tag == nil ? [] : ["harmony"],
                    "rationale": "Dynamics and approved arrangement context support a tentative reading; chord brightness need not agree.",
                    "harmony": "Resolution is a tentative reading of the progression, not a measured emotion.",
                    "uncertainty": "Key confidence is unknown; instrumentation is context, not independent detection.",
                    "visual_direction": (desired ?? tag ?? "undetermined") + ": Let a narrow cold light contract around the recurring circle.",
                ]
                if tag == nil { section["abstention_reason"] = "Insufficient reliable emotional evidence." }
                return section
            }
            return [
                "detected": tag.map { [["tag": $0, "weight": 1] as [String: Any]] } ?? [],
                "rationale": "Tentative section-derived interpretation, not a creative-quality verdict.",
                MusicAffectEvidenceV1.key: ["schema": MusicAffectEvidenceV1.schema, "summary": "A restrained opening grows denser; conflicting clues remain visible.", "confidence": tag == nil ? 0 : 0.6, "sections": sections],
            ]
        }
        func shotlist() throws -> Shotlist {
            try Shotlist(schema_: shotlistSchemaVersion, mode: .beat, project: "demo", song: Song(title: "Fixture", audioPath: "audio/song.wav", analysisPath: "analysis/song.json", bpm: 84, durationS: 8), generated: "fixture", generator: "fixture", shots: [
                Shot(id: "s001", section: "opening", timeStart: 0, timeEnd: 4, durationS: 4, type: .bRoll, description: "Circle", visualPrompt: "Circle", mood: "dark"),
                Shot(id: "s002", section: "ending", timeStart: 4, timeEnd: 8, durationS: 4, type: .bRoll, description: "Circle", visualPrompt: "Circle", mood: "dark"),
            ])
        }
        func arc(direction: String) -> MusicVisualArcDraftV1 {
            MusicVisualArcDraftV1(concept: "Abstract circles", motifs: [], sections: [
                MusicArcSectionV1(sectionID: "opening", musicalFunction: "opening", visualFunction: direction, motifIDs: [], shotIDs: ["s001"], constants: [], variations: [], lyricsRelation: .unused, changeExplanation: "Contracting light"),
                MusicArcSectionV1(sectionID: "ending", musicalFunction: "ending", visualFunction: direction, motifIDs: [], shotIDs: ["s002"], constants: [], variations: [], lyricsRelation: .unused, changeExplanation: "Contracting light"),
            ])
        }
    }
}
