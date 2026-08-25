import CryptoKit
import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

/// Deterministic hard-gate enforcement: the port of the predecessor's require-chain that physically
/// stops the agent from advancing a phase whose real artifact (measured beats/downbeats) is missing.
@Suite("Hard gates")
struct GateGuardTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: root.appendingPathComponent("audio").appendingPathComponent("song.wav"))
        try YAMLArtifactStore(dataRoot: root).save(
            ProjectMeta(project: "demo", mode: .beat),
            to: PipelineLayout.projectFile
        )
        return root
    }

    private func writeAnalysis(_ root: URL, beats: [Double], downbeats: [Double], duration: Double,
                              sectionLabels: [[String: String]] = []) throws {
        let dir = root.appendingPathComponent("analysis")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let song = root.appendingPathComponent("audio/song.wav")
        let songHash = SHA256.hash(data: try Data(contentsOf: song))
            .map { String(format: "%02x", $0) }
            .joined()
        let persistedBeats = beats.isEmpty
            ? []
            : Array(Set(beats + downbeats)).sorted()
        var obj: [String: Any] = [
            "schema": analysisSchemaVersion,
            "project": "demo",
            "song_path": "audio/song.wav",
            "song_sha256": songHash,
            "beats": persistedBeats,
            "downbeats": downbeats,
            "bpm": 120,
            "duration_s": duration,
            "sections": [
                [
                    "index": 0,
                    "start": 0,
                    "end": duration,
                    "cluster": 0,
                    "source": "measured_system_hierarchy",
                ],
            ],
            "structure_candidates": [
                ["source": "librosa", "sections": [["index": 0, "start": 0, "end": duration, "cluster": 0]]],
                ["source": "essentia", "sections": [["index": 0, "start": 0, "end": duration, "cluster": 0]]],
            ],
            "structure_resolution": [
                "version": "adaptive-structure/v5",
                "status": "resolved",
                "method": "music_understanding_hierarchy",
                "detector_sources": ["apple_music_understanding"],
                "minimum_section_bars": 0,
                "candidate_boundary_count": 0,
                "consensus_boundary_count": 0,
                "alignment_marker_count": 0,
                "resolved_alignment_marker_count": 0,
                "accepted_boundary_count": 0,
                "discarded_boundary_count": 0,
                "boundary_evidence": [[
                    "time": 0,
                    "kind": "system_hierarchy",
                    "detector_sources": ["apple_music_understanding"],
                ]],
                "hierarchy": [
                    "source": "apple_music_understanding",
                    "sections": [["start": 0, "end": duration]],
                    "segments": [["start": 0, "end": duration]],
                    "phrases": [["start": 0, "end": duration]],
                ],
                "detail": "Measured system hierarchy.",
            ],
            "downbeat_source": "music-understanding",
            "pipeline_stages": ["structure", "music_understanding"],
            "stage_diagnostics": [[
                "stage": "music_understanding",
                "status": "succeeded",
                "detail": "Measured system hierarchy.",
            ]],
        ]
        if !sectionLabels.isEmpty {
            obj["tempo_multiplier"] = 1
            obj["interpretation"] = [
                "section_labels": sectionLabels,
                "anomalies": [],
                "overall_character": "Measured steady pulse with a compact arc.",
            ]
        }
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent("song.json"))
        try AnalysisMeasurementProofStore.save(
            AnalysisMeasurementProof(
                project: "demo",
                songSHA256: songHash,
                lyricsAlignment: nil
            ),
            dataRoot: root
        )
    }

    private func writeConsolidatedAnalysis(
        _ root: URL,
        detectorBoundaries: [[Double]],
        alignmentReport: LyricsAlignment.Result? = nil,
        includeSystemHierarchy: Bool = true,
        downbeats: [Double]? = nil,
        duration: Double = 64.0
    ) throws -> URL {
        let sources = ["librosa", "essentia"]
        let measuredDownbeats = downbeats
            ?? stride(from: 0.0, through: duration, by: 2.0).map { $0 }
        func sections(_ boundaries: [Double], source: String) -> [AudioSection] {
            let times = ([0.0] + boundaries + [duration]).sorted()
            return zip(times, times.dropFirst()).enumerated().map { item in
                AudioSection(
                    index: item.offset,
                    start: item.element.0,
                    end: item.element.1,
                    cluster: item.offset,
                    source: source
                )
            }
        }
        let raw = AudioAnalysis(
            sampleRate: 44_100,
            durationS: duration,
            bpm: 120,
            beats: stride(from: 0.0, through: duration, by: 0.5).map { $0 },
            downbeats: measuredDownbeats,
            downbeatSource: includeSystemHierarchy ? "music-understanding" : "beat-transformer",
            sections: sections(detectorBoundaries[0], source: sources[0]),
            energyCurve: [],
            tempoCurve: [],
            sectionsEssentia: detectorBoundaries.count > 1
                ? sections(detectorBoundaries[1], source: sources[1])
                : []
        )
        let song = root.appendingPathComponent("audio/song.wav")
        let songHash = SHA256.hash(data: try Data(contentsOf: song))
            .map { String(format: "%02x", $0) }
            .joined()
        let systemRanges = [(0.0, 20.0), (20.0, 40.0), (40.0, duration)]
        let system = includeSystemHierarchy
            ? MusicUnderstandingMeasurement(
                beats: stride(from: 0.0, through: duration, by: 0.5).map { $0 },
                bars: stride(from: 0.0, through: duration, by: 2.0).map { $0 },
                bpm: 120,
                sections: systemRanges.map { MeasuredMusicRange(start: $0.0, end: $0.1) },
                segments: systemRanges.map { MeasuredMusicRange(start: $0.0, end: $0.1) },
                phrases: stride(from: 0.0, to: duration, by: 4.0).map {
                    MeasuredMusicRange(start: $0, end: min($0 + 4, duration))
                }
            )
            : nil
        let canonical = try MusicvideoAnalysisRunner.toCanonicalDetailed(
            raw,
            project: "demo",
            songPath: "audio/song.wav",
            lyricsAlignment: alignmentReport?.lines ?? [],
            alignmentReport: alignmentReport,
            pipelineStages: includeSystemHierarchy ? ["music_understanding"] : [],
            songSha256: songHash,
            musicUnderstanding: system
        )
        var diagnostics = includeSystemHierarchy
            ? [
                MusicvideoAnalysisRunner.StageDiagnostic(
                    stage: "music_understanding",
                    status: .succeeded,
                    detail: "Measured system hierarchy."
                ),
            ]
            : [
                MusicvideoAnalysisRunner.StageDiagnostic(
                    stage: "native_dsp",
                    status: .succeeded,
                    detail: "Measured acoustic candidates."
                ),
                MusicvideoAnalysisRunner.StageDiagnostic(
                    stage: "neural_beat_grid",
                    status: .succeeded,
                    detail: "Measured neural beat grid."
                ),
            ]
        if let alignmentReport {
            diagnostics.append(
                MusicvideoAnalysisRunner.StageDiagnostic(
                    stage: "lyrics_alignment",
                    status: alignmentReport.hasSuccessfulAlignment
                        || alignmentReport.hasReliableStructureEvidence
                        ? .succeeded : .degraded,
                    detail: "Measured lyric alignment.",
                    timingEvidence: alignmentReport.timingEvidence,
                    timingMethod: alignmentReport.timingMethod
                )
            )
        }
        var object = try #require(
            try JSONSerialization.jsonObject(
                with: MusicvideoAnalysisRunner.encodeArtifact(
                    canonical.analysis,
                    structureResolution: canonical.structureResolution,
                    stageDiagnostics: diagnostics
                )
            ) as? [String: Any]
        )
        object["tempo_multiplier"] = 1
        object["interpretation"] = [
            "section_labels": canonical.analysis.sections.map {
                ["index": String($0.index), "label": "section\($0.index)", "confidence": "0.9"]
            },
            "anomalies": [],
            "overall_character": "Measured structure under gate verification.",
        ]
        let url = root.appendingPathComponent("analysis/song.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let lyrics: String?
        if let alignmentReport {
            lyrics = alignmentReport.lines.map { line in
                let marker = line.sectionMarker.map { "[\($0)]\n" } ?? ""
                return marker + line.text
            }.joined(separator: "\n")
            let lyricsURL = root.appendingPathComponent("lyrics/lyrics.txt")
            try FileManager.default.createDirectory(
                at: lyricsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(lyrics!.utf8).write(to: lyricsURL)
        } else {
            lyrics = nil
        }
        let alignmentProof: AnalysisMeasurementProof.LyricsAlignmentProof?
        if let lyrics, let alignmentReport {
            alignmentProof = AnalysisMeasurementProof.LyricsAlignmentProof(
                sourcePath: "audio/song.wav",
                sourceSHA256: try FileDigest.sha256(of: song),
                lyricsSHA256: AnalysisMeasurementProofStore.lyricsFingerprint(lyrics),
                alignmentSHA256: try AnalysisMeasurementProofStore.alignmentFingerprint(
                    object
                ),
                timingEvidence: alignmentReport.timingEvidence,
                timingMethod: alignmentReport.timingMethod,
                markerCount: alignmentReport.markerCount,
                lyricTokenCount: alignmentReport.lines.flatMap(\.words).count,
                matchedTokenCount: alignmentReport.lines
                    .flatMap(\.words)
                    .filter { $0.score != nil }
                    .count
            )
        } else {
            alignmentProof = nil
        }
        try AnalysisMeasurementProofStore.save(
            AnalysisMeasurementProof(
                project: "demo",
                songSHA256: songHash,
                lyricsAlignment: alignmentProof
            ),
            dataRoot: root
        )
        return url
    }

    private func writeGeneratedBibleProof(
        _ root: URL,
        path: String
    ) throws {
        let url = root.appendingPathComponent(path)
        try savePipelineAssetProof(
            PipelineAssetProof(
                project: "demo",
                scope: "bible",
                entries: [
                    path: PipelineAssetProofEntry(
                        path: path,
                        sha256: try FileDigest.sha256(of: url),
                        providerPrompt: "Compiled sheet prompt",
                        generationModel: "image-model",
                        sourceMediaId: "generated-sheet"
                    ),
                ]
            ),
            dataRoot: root
        )
    }

    @Test("a late lyric marker cannot create a system boundary at track end")
    func lateLyricMarkerDoesNotCreateBoundary() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let alignment = LyricsAlignment.alignDetailed(
            lyrics: "[Verse]\nhello world\n[Outro]\nfinal words",
            transcript: [
                .init(text: "hello", start: 0.1, end: 0.3),
                .init(text: "world", start: 0.3, end: 0.5),
                .init(text: "final", start: 63.5, end: 63.7),
                .init(text: "words", start: 63.7, end: 63.9),
            ]
        )
        _ = try writeConsolidatedAnalysis(
            root,
            detectorBoundaries: [[63.6]],
            alignmentReport: alignment
        )

        try MusicvideoGateChecks.requireInterpretableAnalysis(dataRoot: root)
        try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
    }

    @Test("native lyric marker near track end resolves to internal acoustic evidence")
    func lateNativeLyricMarkerUsesInternalEvidence() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let alignment = LyricsAlignment.alignDetailed(
            lyrics: "[Verse]\nhello world\n[Outro]\nfinal words",
            transcript: [
                .init(text: "hello", start: 0.1, end: 0.3),
                .init(text: "world", start: 0.3, end: 0.5),
                .init(text: "final", start: 63.5, end: 63.7),
                .init(text: "words", start: 63.7, end: 63.9),
            ]
        )
        let url = try writeConsolidatedAnalysis(
            root,
            detectorBoundaries: [[62], [62.4]],
            alignmentReport: alignment,
            includeSystemHierarchy: false
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let resolution = try #require(object["structure_resolution"] as? [String: Any])
        let evidence = try #require(resolution["boundary_evidence"] as? [[String: Any]])
        #expect(evidence.contains {
            ($0["time"] as? NSNumber)?.doubleValue == 62
                && $0["kind"] as? String == "lyrics_supported_acoustic"
        })
        try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
    }

    @Test("unresolved native structure reports its actual evidence failure")
    func unresolvedNativeStructureReportsNativeFailure() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeConsolidatedAnalysis(
            root,
            detectorBoundaries: [[16], [16.4]],
            includeSystemHierarchy: false,
            downbeats: [0]
        )

        do {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
            Issue.record("expected unresolved native structure to block approval")
        } catch let blocked as GateBlocked {
            #expect(blocked.message.contains("native structure remains unresolved"))
            #expect(!blocked.message.contains("Apple Music Understanding"))
        }
    }

    private func shotlist(
        duration: Double = 12,
        keyframeStrategy: KeyframeStrategy = .start,
        sourceMode: SourceMode = .generated,
        productionPlan: ShotProductionPlan? = nil,
        generator: String = "test"
    ) throws -> Shotlist {
        let song = try Song(
            title: "song",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: duration
        )
        let shot = try Shot(
            id: "s001",
            section: "intro",
            timeStart: 0,
            timeEnd: duration,
            durationS: duration,
            type: .performance,
            sourceMode: sourceMode,
            description: "A complete shot",
            visualPrompt: "A performer holds the opening pose in a measured wide frame.",
            mood: "restrained",
            keyframeStrategy: keyframeStrategy,
            productionPlan: productionPlan
        )
        return try Shotlist(
            schema_: shotlistSchemaVersion,
            mode: .section,
            project: "demo",
            song: song,
            generated: "2026-07-26T00:00:00Z",
            generator: generator,
            shots: [shot]
        )
    }

    private func brief() throws -> Brief {
        try Brief(
            project: "demo",
            generated: "2026-07-26T00:00:00Z",
            mission: .demo,
            targetPlatform: "YouTube",
            aspectRatio: .landscape16x9,
            projectMode: "section",
            budgetEur: 50,
            conceptType: .narrative,
            visualMedium: .animation2d,
            visualMediumNotes: "restrained hand-drawn animation",
            tone: [.quiet],
            figures: .none,
            lyricsIntegration: .metaphorical
        )
    }

    private func storyboardSteps(
        locationView: String = "wide",
        firstBlocking: [[String: String]] = []
    ) throws -> [Step] {
        try (1...4).map { index in
            try Step(
                id: "intro.\(String(format: "%02d", index))",
                function: index == 1 ? .transition : .story,
                subject: "The performer holds opening pose \(index).",
                camera: "Wide static frame.",
                settingHint: "yard, from the gate",
                locationViewRequest: locationView,
                framing: "wide",
                cameraSetup: [
                    "height": "eye_level",
                    "angle": "frontal",
                    "lens_hint": "wide",
                ],
                characterBlocking: index == 1 ? firstBlocking : []
            )
        }
    }

    private func writePlanningStyle(_ root: URL) throws {
        try YAMLArtifactStore(dataRoot: root).save(
            try brief(),
            to: PipelineLayout.briefFile
        )
        try YAMLArtifactStore(dataRoot: root).save(
            try ProductionDesign(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                visualMedium: .animation2d,
                visualMediumNotes: "restrained hand-drawn animation",
                colorScript: ["intro": "Muted blue dawn."]
            ),
            to: "production_design/production_design.yaml"
        )
    }

    // MARK: - Fail-closed pack wiring (the triangle Engine↔Plugin↔Agent must be live)

    @Test("requireWiredPack: a generic project (no declared pack) is unaffected")
    func wiringGenericPasses() throws {
        try GateGuard.requireWiredPack(declared: nil, resolved: nil, registry: EngineRegistry())
    }

    @Test("requireWiredPack: a declared pack that didn't wire blocks EVERY approval (P0 fail-closed)")
    func wiringDeclaredButUnwiredBlocks() {
        // Package declares musicvideo but the runtime resolved nil / built an empty registry — no step
        // may be approved, or the pipeline would advance ungated masquerading as generic.
        #expect(throws: GateBlocked.self) {
            try GateGuard.requireWiredPack(declared: "musicvideo", resolved: nil, registry: EngineRegistry())
        }
        #expect(throws: GateBlocked.self) {
            try GateGuard.requireWiredPack(declared: "musicvideo", resolved: "musicvideo", registry: EngineRegistry())
        }
    }

    @Test("requireWiredPack: a genuinely wired pack passes")
    func wiringWiredPasses() throws {
        let registry = EngineRegistry()
        registry.registerWiringProbe { PackWiring.token(pack: "musicvideo", nonce: $0) }
        try GateGuard.requireWiredPack(declared: "musicvideo", resolved: "musicvideo", registry: registry)
    }

    @Test("analysis gate requires measured rhythm and A2 interpretation")
    func analysisRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let labels = [[
            "index": "0",
            "label": "intro",
            "confidence": "0.9",
        ]]

        // No artifact → blocked.
        #expect(throws: GateBlocked.self) { try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root) }

        // Degenerate artifact (no beats/downbeats) → blocked.
        try writeAnalysis(root, beats: [], downbeats: [], duration: 0)
        #expect(throws: GateBlocked.self) { try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root) }

        // Real rhythm data but NO interpretation yet (A2 not done) → still blocked.
        try writeAnalysis(root, beats: [0.5, 1.0, 1.5], downbeats: [0.5, 2.5], duration: 12.0)
        #expect(throws: GateBlocked.self) { try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root) }

        // Labels cannot make unresolved structural timing approvable.
        try writeAnalysis(root, beats: [0.5, 1.0, 1.5], downbeats: [0.5, 2.5], duration: 12.0, sectionLabels: labels)
        let analysisURL = root.appendingPathComponent("analysis/song.json")
        var unresolved = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: analysisURL)) as? [String: Any]
        )
        var resolution = try #require(unresolved["structure_resolution"] as? [String: Any])
        resolution["status"] = "needs_review"
        resolution["method"] = "unresolved"
        unresolved["structure_resolution"] = resolution
        try JSONSerialization.data(withJSONObject: unresolved).write(to: analysisURL)
        #expect(throws: GateBlocked.self) { try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root) }

        // Lyrics are optional when the system hierarchy resolves the structure.
        try writeAnalysis(root, beats: [0.5, 1.0, 1.5], downbeats: [0.5, 2.5], duration: 12.0, sectionLabels: labels)
        try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)

        try Data("replacement".utf8).write(
            to: root.appendingPathComponent("audio/song.wav")
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
        }
    }

    @Test("analysis gate accepts the verified system hierarchy contract")
    func analysisGateAcceptsConsolidatedArtifact() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeConsolidatedAnalysis(root, detectorBoundaries: [[23.3], [25.1]])
        try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
    }

    @Test("analysis gate reports inconsistent system rhythm without discarding its hierarchy")
    func analysisGateReportsSystemRhythmFailurePrecisely() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeConsolidatedAnalysis(
            root,
            detectorBoundaries: [[23.3], [25.1]]
        )
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["downbeat_source"] = Analysis.DownbeatSource.beatTransformer.rawValue
        var diagnostics = try #require(object["stage_diagnostics"] as? [[String: Any]])
        diagnostics[0]["status"] = "degraded"
        diagnostics[0]["detail"] = "Retained fallback rhythm."
        object["stage_diagnostics"] = diagnostics
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let resolution = try #require(object["structure_resolution"] as? [String: Any])
        #expect(resolution["status"] as? String == "resolved")
        #expect(resolution["hierarchy"] as? [String: Any] != nil)
        do {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
            Issue.record("Expected inconsistent Music Understanding rhythm to block approval.")
        } catch let blocked as GateBlocked {
            #expect(blocked.message.contains("canonical beat/bar/BPM grid"))
        }
    }

    @Test("analysis gate accepts lyric labels attached to measured system boundaries")
    func analysisGateAcceptsSystemBoundaryLabels() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = LyricsAlignment.alignDetailed(
            lyrics: "[Intro]\nopen words\n[Verse]\nverse words\n[Outro]\nending words",
            transcript: [
                .init(text: "open", start: 0.1, end: 0.3),
                .init(text: "words", start: 0.3, end: 0.5),
                .init(text: "verse", start: 20.0, end: 20.2),
                .init(text: "words", start: 20.2, end: 20.4),
                .init(text: "ending", start: 52.0, end: 52.2),
                .init(text: "words", start: 52.2, end: 52.4),
            ]
        )
        let url = try writeConsolidatedAnalysis(
            root,
            detectorBoundaries: [[19.6, 40.4], [39.5]],
            alignmentReport: report
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let resolution = try #require(object["structure_resolution"] as? [String: Any])
        #expect(resolution["status"] as? String == "resolved")
        #expect(resolution["resolved_alignment_marker_count"] as? Int == 2)
        try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
    }

    @Test("analysis gate lets speech recognition label acoustic boundaries")
    func analysisGateAcceptsRecognizedLabelsOnAcousticBoundaries() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = LyricsAlignment.alignDetailed(
            lyrics: "[Verse]\nopen words\n[Bridge]\nwide open",
            transcript: [
                .init(text: "open", start: 16.1, end: 16.3),
                .init(text: "words", start: 16.3, end: 16.5),
                .init(text: "wide", start: 40.1, end: 40.3),
                .init(text: "open", start: 40.3, end: 40.5),
            ]
        )
        let url = try writeConsolidatedAnalysis(
            root,
            detectorBoundaries: [[16, 40, 58], [16.4, 40.4, 58.4]],
            alignmentReport: report,
            includeSystemHierarchy: false
        )
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            ) as? [String: Any]
        )
        let resolution = try #require(
            object["structure_resolution"] as? [String: Any]
        )
        let evidence = try #require(
            resolution["boundary_evidence"] as? [[String: Any]]
        )
        #expect(evidence.filter {
            $0["kind"] as? String == "lyrics_supported_acoustic"
        }.count == 2)
        try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)

        var tampered = object
        var alignment = try #require(tampered["alignment"] as? [[String: Any]])
        alignment[0]["start"] = 24.0
        tampered["alignment"] = alignment
        try JSONSerialization.data(withJSONObject: tampered).write(to: url)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
        }

        tampered = object
        var sections = try #require(tampered["sections"] as? [[String: Any]])
        sections[1]["label"] = "chorus"
        tampered["sections"] = sections
        try JSONSerialization.data(withJSONObject: tampered).write(to: url)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
        }
    }

    @Test("native analysis gate preserves an opening lyric marker label")
    func analysisGateRejectsTamperedOpeningLabel() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = LyricsAlignment.alignDetailed(
            lyrics: "[Intro]\nopen words\n[Verse]\nwide open",
            transcript: [
                .init(text: "open", start: 0.1, end: 0.3),
                .init(text: "words", start: 0.3, end: 0.5),
                .init(text: "wide", start: 16.1, end: 16.3),
                .init(text: "open", start: 16.3, end: 16.5),
            ]
        )
        let url = try writeConsolidatedAnalysis(
            root,
            detectorBoundaries: [[16, 58], [16.4, 58.4]],
            alignmentReport: report,
            includeSystemHierarchy: false
        )
        try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)

        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var sections = try #require(object["sections"] as? [[String: Any]])
        sections[0]["label"] = "tampered"
        object["sections"] = sections
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
        }
    }

    @Test("analysis gate reproduces known-text alignment provenance")
    func analysisGateAcceptsKnownTextAlignmentBoundaries() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = LyricsAlignment.alignKnownTextDetailed(
            lyrics: "[Verse]\nopen words\n[Bridge]\nwide open",
            measurement: KnownTextAlignmentMeasurement(
                words: [
                    .init(text: "open", start: 16.1, end: 16.3),
                    .init(text: "words", start: 16.3, end: 16.5),
                    .init(text: "wide", start: 40.1, end: 40.3),
                    .init(text: "open", start: 40.3, end: 40.5),
                ],
                timingMethod: .attentionDTW
            )
        )
        let url = try writeConsolidatedAnalysis(
            root,
            detectorBoundaries: [[58], [58.4]],
            alignmentReport: report,
            includeSystemHierarchy: false
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let resolution = try #require(object["structure_resolution"] as? [String: Any])
        #expect(resolution["alignment_timing_evidence"] as? String == "known_text_alignment")
        let evidence = try #require(resolution["boundary_evidence"] as? [[String: Any]])
        #expect(evidence.filter {
            $0["kind"] as? String == "lyrics_known_text_alignment"
        }.count == 2)
        try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)

        var tampered = object
        var tamperedResolution = resolution
        tamperedResolution["alignment_timing_evidence"] = "recognized_speech"
        tampered["structure_resolution"] = tamperedResolution
        try JSONSerialization.data(withJSONObject: tampered).write(to: url)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
        }
    }

    @Test("analysis gate rejects artifact-only escalation to known-text timing")
    func analysisGateRejectsKnownTextTimingEscalation() throws {
        try assertKnownTextTimingEscalationBlocked(includeSystemHierarchy: false)
    }

    @Test("system hierarchy gate rejects artifact-only escalation to known-text timing")
    func systemHierarchyGateRejectsKnownTextTimingEscalation() throws {
        try assertKnownTextTimingEscalationBlocked(includeSystemHierarchy: true)
    }

    private func assertKnownTextTimingEscalationBlocked(
        includeSystemHierarchy: Bool
    ) throws {
        let knownTextRoot = try tempRoot()
        let recognizedRoot = try tempRoot()
        defer {
            try? FileManager.default.removeItem(at: knownTextRoot)
            try? FileManager.default.removeItem(at: recognizedRoot)
        }
        let lyrics = "[Verse]\nopen words\n[Bridge]\nwide open"
        let transcript = [
            TranscriptToken(text: "open", start: 16.1, end: 16.3),
            TranscriptToken(text: "words", start: 16.3, end: 16.5),
            TranscriptToken(text: "wide", start: 40.1, end: 40.3),
            TranscriptToken(text: "open", start: 40.3, end: 40.5),
        ]
        let knownText = LyricsAlignment.alignKnownTextDetailed(
            lyrics: lyrics,
            measurement: KnownTextAlignmentMeasurement(
                words: transcript.map {
                    TranscribedWord(text: $0.text, start: $0.start, end: $0.end)
                },
                timingMethod: .attentionDTW
            )
        )
        let recognized = LyricsAlignment.alignDetailed(
            lyrics: lyrics,
            transcript: transcript
        )
        _ = try writeConsolidatedAnalysis(
            knownTextRoot,
            detectorBoundaries: [[58], [58.4]],
            alignmentReport: knownText,
            includeSystemHierarchy: includeSystemHierarchy
        )
        _ = try writeConsolidatedAnalysis(
            recognizedRoot,
            detectorBoundaries: [[58], [58.4]],
            alignmentReport: recognized,
            includeSystemHierarchy: includeSystemHierarchy
        )
        let recognizedProof = try #require(
            AnalysisMeasurementProofStore.url(dataRoot: recognizedRoot)
        )
        let knownTextProof = try #require(
            AnalysisMeasurementProofStore.url(dataRoot: knownTextRoot)
        )
        try Data(contentsOf: recognizedProof).write(to: knownTextProof, options: .atomic)

        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: knownTextRoot)
        }
    }

    @Test("analysis gate reproduces the earliest strongest terminal consensus")
    func analysisGateAcceptsPreferredOutroBoundary() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = LyricsAlignment.alignDetailed(
            lyrics: "[Verse]\nopen words\n[Chorus]\nwide open",
            transcript: [
                .init(text: "open", start: 16.1, end: 16.3),
                .init(text: "words", start: 16.3, end: 16.5),
                .init(text: "wide", start: 40.1, end: 40.3),
                .init(text: "open", start: 40.3, end: 40.5),
            ]
        )
        let url = try writeConsolidatedAnalysis(
            root,
            detectorBoundaries: [[16, 40, 58, 62], [16.4, 40.4, 58.4, 62.4]],
            alignmentReport: report,
            includeSystemHierarchy: false,
            duration: 68
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let sections = try #require(object["sections"] as? [[String: Any]])
        #expect(sections.compactMap { ($0["start"] as? NSNumber)?.doubleValue } == [0, 16, 40, 58])
        try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)

        var tampered = object
        var resolution = try #require(tampered["structure_resolution"] as? [String: Any])
        var evidence = try #require(resolution["boundary_evidence"] as? [[String: Any]])
        evidence[evidence.count - 1]["time"] = 62.0
        resolution["boundary_evidence"] = evidence
        tampered["structure_resolution"] = resolution
        try JSONSerialization.data(withJSONObject: tampered).write(to: url)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
        }
    }

    @Test("analysis gate accepts reviewable native evidence without a system hierarchy")
    func analysisGateAcceptsNativeOnlyArtifact() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeConsolidatedAnalysis(
            root,
            detectorBoundaries: [[8, 16, 24, 32, 40], [12, 20, 28, 36]],
            includeSystemHierarchy: false
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let resolution = try #require(object["structure_resolution"] as? [String: Any])
        #expect(resolution["status"] as? String == "review_required")
        try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
    }

    @Test("analysis gate independently rejects tampered boundary evidence")
    func analysisGateRejectsTamperedBoundaryEvidence() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeConsolidatedAnalysis(root, detectorBoundaries: [[23.3], [25.1]])
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var resolution = try #require(object["structure_resolution"] as? [String: Any])
        resolution["candidate_boundary_count"] = 3
        object["structure_resolution"] = resolution
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
        }

        _ = try writeConsolidatedAnalysis(
            root,
            detectorBoundaries: [[23.3], [25.1]],
            includeSystemHierarchy: false
        )
        object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var sections = try #require(object["sections"] as? [[String: Any]])
        sections[1]["start"] = 22.0
        object["sections"] = sections
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
        }

        _ = try writeConsolidatedAnalysis(
            root,
            detectorBoundaries: [[23.3], [25.1]],
            includeSystemHierarchy: false
        )
        object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        sections = try #require(object["sections"] as? [[String: Any]])
        sections = [sections[0]]
        sections[0]["end"] = 64.0
        object["sections"] = sections
        resolution = try #require(object["structure_resolution"] as? [String: Any])
        resolution["accepted_boundary_count"] = 0
        resolution["discarded_boundary_count"] = 2
        resolution["boundary_evidence"] = []
        object["structure_resolution"] = resolution
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
        }

        _ = try writeConsolidatedAnalysis(
            root,
            detectorBoundaries: [[23.3], [25.1]],
            includeSystemHierarchy: false
        )
        object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var candidates = try #require(object["structure_candidates"] as? [[String: Any]])
        candidates[0]["source"] = "forged_detector"
        object["structure_candidates"] = candidates
        resolution = try #require(object["structure_resolution"] as? [String: Any])
        resolution["detector_sources"] = ["forged_detector", "essentia"]
        var evidence = try #require(resolution["boundary_evidence"] as? [[String: Any]])
        evidence[0]["detector_sources"] = ["forged_detector", "essentia"]
        resolution["boundary_evidence"] = evidence
        object["structure_resolution"] = resolution
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
        }
    }

    @Test("analysis gate rejects contradictory system diagnostics")
    func analysisGateRejectsContradictorySystemDiagnostics() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeConsolidatedAnalysis(root, detectorBoundaries: [[23.3], [25.1]])
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var diagnostics = try #require(object["stage_diagnostics"] as? [[String: Any]])
        diagnostics.append([
            "stage": "music_understanding",
            "status": "failed",
            "detail": "Contradictory duplicate.",
        ])
        object["stage_diagnostics"] = diagnostics
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
        }
    }

    @Test("analysis gate independently reconstructs lyric labels from alignment")
    func analysisGateRejectsTamperedLyricEvidence() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = LyricsAlignment.alignDetailed(
            lyrics: "[Intro]\nopen words\n[Verse]\nverse words",
            transcript: [
                .init(text: "open", start: 0.1, end: 0.3),
                .init(text: "words", start: 0.3, end: 0.5),
                .init(text: "verse", start: 20.0, end: 20.2),
                .init(text: "words", start: 20.2, end: 20.4),
            ]
        )
        let url = try writeConsolidatedAnalysis(
            root,
            detectorBoundaries: [[19.6], [20.2]],
            alignmentReport: report
        )
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var resolution = try #require(object["structure_resolution"] as? [String: Any])
        var evidence = try #require(resolution["boundary_evidence"] as? [[String: Any]])
        evidence[0]["lyric_marker"] = "tampered"
        resolution["boundary_evidence"] = evidence
        object["structure_resolution"] = resolution
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
        }
    }

    @Test("project track discovery rejects a symlink outside the project")
    func projectTrackRejectsSymlinkEscape() throws {
        let cleanup = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "song-symlink-\(UUID().uuidString)",
                isDirectory: true
            )
        let root = cleanup.appendingPathComponent("project/pipeline")
        let outside = cleanup.appendingPathComponent("outside.wav")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("audio"),
            withIntermediateDirectories: true
        )
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("audio/song.wav"),
            withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: cleanup) }

        #expect(AudioProjectLayout.songFiles(dataRoot: root).isEmpty)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireProjectTrack(dataRoot: root)
        }
    }

    @Test("musicvideo registers deterministic hard-gate requirements per phase")
    func requirementRegistered() {
        PackCatalog.register(MusicvideoPack())
        let registry = PackCatalog.registry(activePack: "musicvideo")
        // The per-phase acceptance harness: every content phase has a deterministic requirement.
        for phase in ["project_init", "analysis", "brief", "production_design", "treatment",
                      "storyboard", "bible", "shotlist", "sanity", "frames", "render"] {
            #expect(registry.gateRequirements[phase] != nil, "\(phase) must have a gate requirement")
        }
        #expect(registry.gateRequirements["cover"] == nil)
        for phase in MusicvideoPipelineLineage.phases {
            #expect(
                registry.phaseLineageProviders[phase] != nil,
                "\(phase) must have a lineage provider"
            )
        }
        // A generic project carries none.
        #expect(PackCatalog.registry(activePack: nil).gateRequirements["analysis"] == nil)
    }

    @Test("registered gates reject missing, changed, and stale phase lineage")
    func lineageRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let labels = [[
            "index": "0",
            "label": "intro",
            "confidence": "0.9",
        ]]
        try writeAnalysis(
            root,
            beats: [0, 0.5, 1],
            downbeats: [0, 2],
            duration: 12,
            sectionLabels: labels
        )
        PackCatalog.register(MusicvideoPack())
        let registry = PackCatalog.registry(activePack: "musicvideo")
        let analysisRequirement = try #require(
            registry.gateRequirements["analysis"]
        )
        #expect(throws: GateBlocked.self) {
            try analysisRequirement(root)
        }
        let analysisProvider = try #require(
            registry.phaseLineageProviders["analysis"]
        )
        try PipelineLineageStore.record(
            phase: "analysis",
            snapshot: try analysisProvider(root),
            dataRoot: root
        )
        try analysisRequirement(root)

        let analysisURL = root.appendingPathComponent("analysis/song.json")
        try Data(#"{"phase":"brief"}"#.utf8).write(
            to: root.appendingPathComponent("analysis/affect.json"),
            options: .atomic
        )
        try analysisRequirement(root)

        var object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: analysisURL)
            ) as? [String: Any]
        )
        var interpretation = try #require(
            object["interpretation"] as? [String: Any]
        )
        interpretation["overall_character"] = "Changed after the phase write."
        object["interpretation"] = interpretation
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: analysisURL, options: .atomic)
        #expect(throws: GateBlocked.self) {
            try analysisRequirement(root)
        }

        try YAMLArtifactStore(dataRoot: root).save(
            try brief(),
            to: PipelineLayout.briefFile
        )
        try YAMLArtifactStore(dataRoot: root).save(
            ProjectMeta(project: "demo", mode: .section, budgetEur: 50),
            to: PipelineLayout.projectFile
        )
        let briefProvider = try #require(
            registry.phaseLineageProviders["brief"]
        )
        try PipelineLineageStore.record(
            phase: "brief",
            snapshot: try briefProvider(root),
            dataRoot: root
        )
        let briefRequirement = try #require(
            registry.gateRequirements["brief"]
        )
        try briefRequirement(root)

        interpretation["overall_character"] = "Changed again upstream."
        object["interpretation"] = interpretation
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: analysisURL, options: .atomic)
        #expect(throws: GateBlocked.self) {
            try briefRequirement(root)
        }
    }

    @Test("every release pipeline gate fails closed when its artifact is absent")
    func everyReleaseGateFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-gates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try YAMLArtifactStore(dataRoot: root).save(
            ProjectMeta(project: "demo", mode: .beat),
            to: PipelineLayout.projectFile
        )
        PackCatalog.register(MusicvideoPack())
        let registry = PackCatalog.registry(activePack: "musicvideo")
        for phase in [
            "project_init", "analysis", "brief", "production_design",
            "treatment", "storyboard", "bible", "shotlist", "sanity",
            "frames", "render",
        ] {
            let requirement = try #require(registry.gateRequirements[phase])
            #expect(throws: GateBlocked.self, "\(phase) must fail closed") {
                try requirement(root)
            }
        }
    }

    @Test("sanity gate accepts only a current report without errors")
    func sanityRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try SanityArtifactStore.save(
            report: SanityReport(project: "demo"),
            dataRoot: root
        )
        try MusicvideoGateChecks.requireCurrentSanity(dataRoot: root)

        try Data("changed".utf8).write(
            to: root.appendingPathComponent(PipelineLayout.briefFile)
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireCurrentSanity(dataRoot: root)
        }

        _ = try SanityArtifactStore.save(
            report: SanityReport(
                project: "demo",
                findings: [
                    Finding(
                        level: .error,
                        code: "BLOCKING",
                        message: "A blocking finding."
                    ),
                ]
            ),
            dataRoot: root
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireCurrentSanity(dataRoot: root)
        }
    }

    @Test("storyboard gate binds every section to the measured analysis timeline")
    func storyboardRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAnalysis(
            root,
            beats: [0, 0.5, 1],
            downbeats: [0, 2],
            duration: 12,
            sectionLabels: [[
                "index": "0",
                "label": "intro",
                "confidence": "0.9",
            ]]
        )
        let steps = try storyboardSteps()
        let valid = try Storyboard(
            meta: try StoryboardMeta(
                project: "demo",
                version: 1,
                generated: "2026-07-26T00:00:00Z",
                summaryOneline: "A measured opening."
            ),
            sections: [
                try Section(
                    id: "intro",
                    label: "intro",
                    timeStart: 0,
                    timeEnd: 12,
                    energy: "low",
                    function: "aufbau",
                    steps: steps
                ),
            ]
        )
        try StoryboardStore.save(valid, to: root)
        try MusicvideoGateChecks.requireRealStoryboard(dataRoot: root)

        let unanchored = try Storyboard(
            meta: try StoryboardMeta(
                project: "demo",
                version: 2,
                generated: "2026-07-26T00:00:00Z",
                summaryOneline: "An unanchored opening."
            ),
            sections: [
                try Section(
                    id: "intro",
                    label: "intro",
                    timeStart: 0,
                    timeEnd: 12,
                    energy: "low",
                    function: "aufbau",
                    steps: try storyboardSteps(firstBlocking: [[
                        "character_ref": "performer",
                        "position": "left third",
                        "pose": "standing",
                        "gaze": "toward the yard",
                        "relation_to_set": "beside the gate",
                        "set_anchor": "screen-left",
                    ]])
                ),
            ]
        )
        try StoryboardStore.save(unanchored, to: root)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealStoryboard(dataRoot: root)
        }

        let truncated = try Storyboard(
            meta: try StoryboardMeta(
                project: "demo",
                version: 3,
                generated: "2026-07-26T00:00:00Z",
                summaryOneline: "An incomplete opening."
            ),
            sections: [
                try Section(
                    id: "intro",
                    label: "intro",
                    timeStart: 0,
                    timeEnd: 6,
                    energy: "low",
                    function: "aufbau",
                    steps: steps
                ),
            ]
        )
        try StoryboardStore.save(truncated, to: root)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealStoryboard(dataRoot: root)
        }
    }

    @Test("planning gates accept coherent artifacts and enforce shot plan ownership")
    func coherentPlanningArtifacts() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAnalysis(
            root,
            beats: [0, 0.5, 1],
            downbeats: [0, 2],
            duration: 12,
            sectionLabels: [[
                "index": "0",
                "label": "intro",
                "confidence": "0.9",
            ]]
        )

        try YAMLArtifactStore(dataRoot: root).save(
            try brief(),
            to: PipelineLayout.briefFile
        )
        try YAMLArtifactStore(dataRoot: root).save(
            ProjectMeta(project: "demo", mode: .section, budgetEur: 50),
            to: PipelineLayout.projectFile
        )
        try MusicvideoGateChecks.requireRealBrief(dataRoot: root)

        try YAMLArtifactStore(dataRoot: root).save(
            try ProductionDesign(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                visualMedium: .animation2d,
                visualMediumNotes: "restrained hand-drawn animation",
                colorScript: ["intro": "Muted blue dawn."]
            ),
            to: "production_design/production_design.yaml"
        )
        try MusicvideoGateChecks.requireRealProductionDesign(dataRoot: root)

        try TreatmentStore.save(
            Treatment(
                meta: try TreatmentMeta(
                    project: "demo",
                    version: 1,
                    generated: "2026-07-26T00:00:00Z",
                    origin: .agentProposal,
                    generator: "test",
                    summaryOneline: "A restrained dawn resolves into motion."
                ),
                bodyMarkdown: "The restrained hand-drawn animation observes "
                    + "the empty yard before the day begins."
            ),
            to: root
        )
        try MusicvideoGateChecks.requireRealTreatment(dataRoot: root)

        let steps = try storyboardSteps()
        try StoryboardStore.save(
            try Storyboard(
                meta: try StoryboardMeta(
                    project: "demo",
                    version: 1,
                    generated: "2026-07-26T00:00:00Z",
                    summaryOneline: "A restrained dawn."
                ),
                sections: [
                    try Section(
                        id: "intro",
                        label: "intro",
                        timeStart: 0,
                        timeEnd: 12,
                        energy: "low",
                        function: "aufbau",
                        steps: steps
                    ),
                ]
            ),
            to: root
        )
        try MusicvideoGateChecks.requireRealStoryboard(dataRoot: root)

        let anchor = root.appendingPathComponent("bible/yard-wide.png")
        try FileManager.default.createDirectory(
            at: anchor.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("anchor".utf8).write(to: anchor)
        try YAMLArtifactStore(dataRoot: root).save(
            try Bible(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                look: LookGuide(style: "restrained hand-drawn animation"),
                locations: [
                    try Location(
                        id: "yard",
                        name: "Schoolyard",
                        visualPrompt: "A quiet schoolyard at blue hour.",
                        sheets: ["wide": "bible/yard-wide.png"]
                    ),
                ]
            ),
            to: PipelineLayout.bibleFile
        )
        try writeGeneratedBibleProof(
            root,
            path: "bible/yard-wide.png"
        )
        try MusicvideoGateChecks.requireRealBible(dataRoot: root)

        _ = try saveShotlist(try shotlist(), to: root)
        try MusicvideoGateChecks.requireRealShotlist(dataRoot: root)

        _ = try saveShotlist(
            try shotlist(generator: "shotlist-agent@write_shotlist"),
            to: root
        )
        try MusicvideoGateChecks.requireRealShotlist(dataRoot: root)

        _ = try saveShotlist(
            try shotlist(generator: "shotlist-agent@write_shotlist/v3"),
            to: root
        )
        try MusicvideoGateChecks.requireRealShotlist(dataRoot: root)

        _ = try saveShotlist(
            try shotlist(generator: Shotlist.agentWriterGenerator),
            to: root
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealShotlist(dataRoot: root)
        }

        let plan = try ShotProductionPlan(
            primaryAction: "The performer holds the opening pose.",
            cameraMovement: .static,
            narrativeBeat: .establish,
            renderability: .green,
            continuityLocks: []
        )
        _ = try saveShotlist(
            try shotlist(
                keyframeStrategy: .none,
                sourceMode: .imported,
                productionPlan: plan,
                generator: Shotlist.agentWriterGenerator
            ),
            to: root
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealShotlist(dataRoot: root)
        }

        _ = try saveShotlist(
            try shotlist(
                productionPlan: plan,
                generator: Shotlist.agentWriterGenerator
            ),
            to: root
        )
        try MusicvideoGateChecks.requireRealShotlist(dataRoot: root)
    }

    @Test("planning gates reject non-image reference files")
    func planningGateRejectsNonImageReference() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAnalysis(
            root,
            beats: [0, 0.5, 1],
            downbeats: [0, 2],
            duration: 12,
            sectionLabels: [[
                "index": "0",
                "label": "intro",
                "confidence": "0.9",
            ]]
        )
        try YAMLArtifactStore(dataRoot: root).save(
            try brief(),
            to: PipelineLayout.briefFile
        )
        try YAMLArtifactStore(dataRoot: root).save(
            ProjectMeta(project: "demo", mode: .section, budgetEur: 50),
            to: PipelineLayout.projectFile
        )
        let reference = root.appendingPathComponent(
            "production_design/refs/style.txt"
        )
        try FileManager.default.createDirectory(
            at: reference.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not an image".utf8).write(to: reference)
        try YAMLArtifactStore(dataRoot: root).save(
            try ProductionDesign(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                visualMedium: .animation2d,
                visualMediumNotes: "restrained hand-drawn animation",
                refs: [
                    ProductionDesignReference(
                        path: "production_design/refs/style.txt"
                    ),
                ]
            ),
            to: "production_design/production_design.yaml"
        )

        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealProductionDesign(
                dataRoot: root
            )
        }
    }

    @Test("bible gate requires every view demanded by the storyboard")
    func bibleRequiresStoryboardViews() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePlanningStyle(root)
        let steps = try storyboardSteps(locationView: "entrance")
        try StoryboardStore.save(
            try Storyboard(
                meta: try StoryboardMeta(
                    project: "demo",
                    version: 1,
                    generated: "2026-07-26T00:00:00Z",
                    summaryOneline: "The gate opens the film."
                ),
                sections: [
                    try Section(
                        id: "intro",
                        label: "intro",
                        timeStart: 0,
                        timeEnd: 12,
                        energy: "low",
                        function: "aufbau",
                        steps: steps
                    ),
                ]
            ),
            to: root
        )
        let anchor = root.appendingPathComponent("bible/wide.png")
        try FileManager.default.createDirectory(
            at: anchor.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("anchor".utf8).write(to: anchor)
        let missing = try Bible(
            project: "demo",
            generated: "2026-07-26T00:00:00Z",
            generator: "test",
            look: LookGuide(style: "restrained hand-drawn animation"),
            locations: [
                try Location(
                    id: "yard",
                    name: "Schoolyard",
                    visualPrompt: "A quiet schoolyard.",
                    sheets: ["wide": "bible/wide.png"]
                ),
            ]
        )
        try YAMLArtifactStore(dataRoot: root).save(
            missing,
            to: PipelineLayout.bibleFile
        )
        try writeGeneratedBibleProof(
            root,
            path: "bible/wide.png"
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealBible(dataRoot: root)
        }
    }

    @Test("frames gate requires every role, compiled prompt, complete current audit, and exact hash")
    func framesRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try ShotProductionPlan(
            primaryAction: "The performer crosses the doorway.",
            cameraMovement: .static,
            renderability: .green,
            continuityLocks: ["red scarf stays tied at the left shoulder"]
        )
        let current = try shotlist(productionPlan: plan)
        _ = try saveShotlist(current, to: root)
        let image = root.appendingPathComponent("media/s001-start.png")
        try FileManager.default.createDirectory(
            at: image.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("frame-v1".utf8).write(to: image)
        let prompt = try #require(current.shots.first)
            .stillProductionPromptRequirements
            .joined(separator: ". ")
        func frames(_ providerPrompt: String) -> FramesManifest {
            FramesManifest(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                shots: [
                    ShotFrames(
                        shotId: "s001",
                        keyframeStrategy: "start",
                        frames: [
                            FrameEntry(
                                role: "start",
                                path: "media/s001-start.png",
                                runwayModel: "image-model",
                                providerPrompt: providerPrompt
                            ),
                        ]
                    ),
                ]
            )
        }
        try saveFramesManifest(frames(prompt), dataRoot: root)
        let digest = SHA256.hash(data: try Data(contentsOf: image))
            .map { String(format: "%02x", $0) }
            .joined()
        let checks = Dictionary(uniqueKeysWithValues: standardAuditCheckKeys.map {
            ($0, AuditCheck(status: .clean))
        })
        try saveFrameAudit(
            try FrameAudit(
                shotId: "s001",
                renderPath: "media/s001-start.png",
                renderSha256: digest,
                generated: "2026-07-26T00:00:00Z",
                auditor: "test",
                checks: checks,
                overall: .clean
            ),
            dataRoot: root
        )
        try MusicvideoGateChecks.requireRealFrames(dataRoot: root)

        try saveFramesManifest(
            frames("A compiled prompt for another shot."),
            dataRoot: root
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealFrames(dataRoot: root)
        }
        try saveFramesManifest(
            frames(prompt + ". The view glides forward."),
            dataRoot: root
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealFrames(dataRoot: root)
        }
        try saveFramesManifest(frames(prompt), dataRoot: root)
        try Data("frame-v2".utf8).write(to: image)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealFrames(dataRoot: root)
        }
    }

    @Test("render gate requires a real project video for every generated shot")
    func renderRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try saveShotlist(
            try shotlist(keyframeStrategy: .none),
            to: root
        )
        let video = root.appendingPathComponent("media/s001.mp4")
        try FileManager.default.createDirectory(
            at: video.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("video".utf8).write(to: video)
        var manifest = RenderManifest(project: "demo", phase: "final")
        record(
            &manifest,
            shotId: "s001",
            output: "media/s001.mp4",
            costEur: 1,
            phase: "final"
        )
        let proof = RenderProofManifest(
            project: "demo",
            phase: "final",
            entries: [
                "s001": RenderProofEntry(
                    shotId: "s001",
                    output: "media/s001.mp4",
                    outputSha256: try FileDigest.sha256(of: video),
                    providerPrompt: "Compiled provider prompt.",
                    generationModel: "video-model"
                ),
            ]
        )
        try saveRenderManifest(manifest, dataRoot: root)
        try saveRenderProofManifest(proof, dataRoot: root)
        try MusicvideoGateChecks.requireRealRender(dataRoot: root)

        try Data("replacement".utf8).write(to: video)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealRender(dataRoot: root)
        }
    }

    @Test("render gate binds the provider prompt to the current production plan")
    func renderPromptProductionPlanRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try ShotProductionPlan(
            primaryAction: "The performer crosses the doorway.",
            cameraMovement: .dollyIn,
            renderability: .green,
            matchActionCue: "Cut as the right foot reaches the threshold.",
            continuityLocks: ["red scarf stays tied at the left shoulder"]
        )
        let current = try shotlist(
            keyframeStrategy: .none,
            productionPlan: plan
        )
        _ = try saveShotlist(current, to: root)
        let video = root.appendingPathComponent("media/s001.mp4")
        try FileManager.default.createDirectory(
            at: video.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("video".utf8).write(to: video)
        var manifest = RenderManifest(project: "demo", phase: "final")
        record(
            &manifest,
            shotId: "s001",
            output: "media/s001.mp4",
            costEur: 1,
            phase: "final"
        )
        try saveRenderManifest(manifest, dataRoot: root)
        let prompt = try #require(current.shots.first)
            .videoProductionPromptRequirements
            .joined(separator: ". ")
        func proof(_ providerPrompt: String) throws -> RenderProofManifest {
            RenderProofManifest(
                project: "demo",
                phase: "final",
                entries: [
                    "s001": RenderProofEntry(
                        shotId: "s001",
                        output: "media/s001.mp4",
                        outputSha256: try FileDigest.sha256(of: video),
                        providerPrompt: providerPrompt,
                        generationModel: "video-model"
                    ),
                ]
            )
        }
        try saveRenderProofManifest(try proof(prompt), dataRoot: root)
        try MusicvideoGateChecks.requireRealRender(dataRoot: root)

        try saveRenderProofManifest(
            try proof("A compiled prompt for another shot."),
            dataRoot: root
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealRender(dataRoot: root)
        }
        try saveRenderProofManifest(
            try proof(prompt + ". The view pans right."),
            dataRoot: root
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealRender(dataRoot: root)
        }
    }

    @Test("render gate binds keyframe conditioning to the exact current frame")
    func renderConditioningRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try saveShotlist(try shotlist(), to: root)
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(
            at: media,
            withIntermediateDirectories: true
        )
        let frame = media.appendingPathComponent("s001-start.png")
        let video = media.appendingPathComponent("s001.mp4")
        try Data("frame-v1".utf8).write(to: frame)
        try Data("video".utf8).write(to: video)
        try saveFramesManifest(
            FramesManifest(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                shots: [
                    ShotFrames(
                        shotId: "s001",
                        keyframeStrategy: "start",
                        frames: [
                            FrameEntry(
                                role: "start",
                                path: "media/s001-start.png",
                                runwayModel: "image-model",
                                providerPrompt: "Compiled frame prompt."
                            ),
                        ]
                    ),
                ]
            ),
            dataRoot: root
        )
        var manifest = RenderManifest(project: "demo", phase: "final")
        record(
            &manifest,
            shotId: "s001",
            output: "media/s001.mp4",
            costEur: 1,
            phase: "final"
        )
        try saveRenderManifest(manifest, dataRoot: root)
        try saveRenderProofManifest(
            RenderProofManifest(
                project: "demo",
                phase: "final",
                entries: [
                    "s001": RenderProofEntry(
                        shotId: "s001",
                        output: "media/s001.mp4",
                        outputSha256: try FileDigest.sha256(of: video),
                        providerPrompt: "Compiled provider prompt.",
                        generationModel: "video-model",
                        startFrame: RenderInputProof(
                            path: "media/s001-start.png",
                            sha256: try FileDigest.sha256(of: frame)
                        )
                    ),
                ]
            ),
            dataRoot: root
        )
        try MusicvideoGateChecks.requireRealRender(dataRoot: root)

        try Data("frame-v2".utf8).write(to: frame)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealRender(dataRoot: root)
        }
    }

    @Test("render gate binds a chained shot to the predecessor's exact last frame")
    func chainedRenderConditioningRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let song = try Song(
            title: "song",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: 8
        )
        let first = try Shot(
            id: "s001",
            section: "verse",
            timeStart: 0,
            timeEnd: 4,
            durationS: 4,
            type: .performance,
            description: "The opening composition.",
            visualPrompt: "A measured opening composition.",
            mood: "restrained",
            keyframeStrategy: .none
        )
        let chained = try Shot(
            id: "s002",
            section: "verse",
            timeStart: 4,
            timeEnd: 8,
            durationS: 4,
            type: .performance,
            description: "Continue the composition.",
            visualPrompt: "The previous composition continues.",
            mood: "restrained",
            keyframeStrategy: .none,
            seedanceInputMode: .keyframe,
            chainWithPreviousEnd: true
        )
        _ = try saveShotlist(
            try Shotlist(
                schema_: shotlistSchemaVersion,
                mode: .section,
                project: "demo",
                song: song,
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                shots: [first, chained]
            ),
            to: root
        )
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(
            at: media,
            withIntermediateDirectories: true
        )
        let firstVideo = media.appendingPathComponent("s001.mp4")
        let secondVideo = media.appendingPathComponent("s002.mp4")
        let predecessorFrame = media.appendingPathComponent(
            "s001-last.png"
        )
        try Data("first-video".utf8).write(to: firstVideo)
        try Data("second-video".utf8).write(to: secondVideo)
        try Data("predecessor-frame-v1".utf8).write(
            to: predecessorFrame
        )
        var manifest = RenderManifest(project: "demo", phase: "final")
        record(
            &manifest,
            shotId: "s001",
            output: "media/s001.mp4",
            costEur: 1,
            phase: "final",
            lastFramePath: "media/s001-last.png"
        )
        record(
            &manifest,
            shotId: "s002",
            output: "media/s002.mp4",
            costEur: 1,
            phase: "final"
        )
        try saveRenderManifest(manifest, dataRoot: root)
        try saveRenderProofManifest(
            RenderProofManifest(
                project: "demo",
                phase: "final",
                entries: [
                    "s001": RenderProofEntry(
                        shotId: "s001",
                        output: "media/s001.mp4",
                        outputSha256: try FileDigest.sha256(
                            of: firstVideo
                        ),
                        providerPrompt: "Compiled first prompt.",
                        generationModel: "video-model"
                    ),
                    "s002": RenderProofEntry(
                        shotId: "s002",
                        output: "media/s002.mp4",
                        outputSha256: try FileDigest.sha256(
                            of: secondVideo
                        ),
                        providerPrompt: "Compiled chained prompt.",
                        generationModel: "video-model",
                        startFrame: RenderInputProof(
                            path: "media/s001-last.png",
                            sha256: try FileDigest.sha256(
                                of: predecessorFrame
                            )
                        )
                    ),
                ]
            ),
            dataRoot: root
        )

        try MusicvideoGateChecks.requireRealRender(dataRoot: root)

        try Data("predecessor-frame-v2".utf8).write(
            to: predecessorFrame
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealRender(dataRoot: root)
        }
    }

    @Test("render gate requires the exact deterministic reference plan")
    func renderReferencePlanRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try YAMLArtifactStore(dataRoot: root).save(
            try brief(),
            to: PipelineLayout.briefFile
        )
        let reference = root.appendingPathComponent("bible/hero-front.png")
        try FileManager.default.createDirectory(
            at: reference.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("reference".utf8).write(to: reference)
        try YAMLArtifactStore(dataRoot: root).save(
            try Bible(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                characters: [
                    try Character(
                        id: "hero",
                        name: "Hero",
                        visualPrompt: "A restrained hand-drawn performer.",
                        sheets: ["front": "bible/hero-front.png"]
                    ),
                ]
            ),
            to: PipelineLayout.bibleFile
        )
        let song = try Song(
            title: "song",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: 12
        )
        let shot = try Shot(
            id: "s001",
            section: "intro",
            timeStart: 0,
            timeEnd: 12,
            durationS: 12,
            type: .performance,
            description: "A reference-bound shot.",
            visualPrompt: "@Image1 performs in a wide frame.",
            mood: "restrained",
            characterRefs: ["hero"],
            keyframeStrategy: .none,
            seedanceInputMode: .reference
        )
        _ = try saveShotlist(
            try Shotlist(
                schema_: shotlistSchemaVersion,
                mode: .section,
                project: "demo",
                song: song,
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                shots: [shot]
            ),
            to: root
        )
        let video = root.appendingPathComponent("media/s001.mp4")
        try FileManager.default.createDirectory(
            at: video.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("video".utf8).write(to: video)
        var manifest = RenderManifest(project: "demo", phase: "final")
        record(
            &manifest,
            shotId: "s001",
            output: "media/s001.mp4",
            costEur: 1,
            phase: "final"
        )
        try saveRenderManifest(manifest, dataRoot: root)
        func saveProof(referenceImages: [RenderInputProof]) throws {
            try saveRenderProofManifest(
                RenderProofManifest(
                    project: "demo",
                    phase: "final",
                    entries: [
                        "s001": RenderProofEntry(
                            shotId: "s001",
                            output: "media/s001.mp4",
                            outputSha256: try FileDigest.sha256(of: video),
                            providerPrompt: "Compiled provider prompt.",
                            generationModel: "video-model",
                            referenceImages: referenceImages
                        ),
                    ]
                ),
                dataRoot: root
            )
        }
        try saveProof(referenceImages: [
            RenderInputProof(
                path: "bible/hero-front.png",
                sha256: try FileDigest.sha256(of: reference)
            ),
        ])
        try MusicvideoGateChecks.requireRealRender(dataRoot: root)

        try saveProof(referenceImages: [])
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealRender(dataRoot: root)
        }
    }

    @Test("render gate binds AI enhancement to its declared source video")
    func enhancedRenderSourceRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(
            at: media,
            withIntermediateDirectories: true
        )
        let source = media.appendingPathComponent("source.mp4")
        let substitute = media.appendingPathComponent("substitute.mp4")
        let output = media.appendingPathComponent("enhanced.mp4")
        try Data("source".utf8).write(to: source)
        try Data("substitute".utf8).write(to: substitute)
        try Data("enhanced".utf8).write(to: output)
        let song = try Song(
            title: "song",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: 12
        )
        let shot = try Shot(
            id: "s001",
            section: "intro",
            timeStart: 0,
            timeEnd: 12,
            durationS: 12,
            type: .performance,
            sourceMode: .aiEnhanced,
            description: "Restyle the imported performance.",
            visualPrompt: "Preserve motion and restyle the surface.",
            mood: "restrained",
            keyframeStrategy: .none,
            sourcePath: "media/source.mp4"
        )
        _ = try saveShotlist(
            try Shotlist(
                schema_: shotlistSchemaVersion,
                mode: .section,
                project: "demo",
                song: song,
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                shots: [shot]
            ),
            to: root
        )
        var manifest = RenderManifest(project: "demo", phase: "final")
        record(
            &manifest,
            shotId: "s001",
            output: "media/enhanced.mp4",
            costEur: 1,
            phase: "final"
        )
        try saveRenderManifest(manifest, dataRoot: root)
        func saveProof(sourcePath: String, sourceURL: URL) throws {
            try saveRenderProofManifest(
                RenderProofManifest(
                    project: "demo",
                    phase: "final",
                    entries: [
                        "s001": RenderProofEntry(
                            shotId: "s001",
                            output: "media/enhanced.mp4",
                            outputSha256: try FileDigest.sha256(of: output),
                            providerPrompt: "Compiled enhancement prompt.",
                            generationModel: "runway/aleph2",
                            sourceVideo: RenderInputProof(
                                path: sourcePath,
                                sha256: try FileDigest.sha256(of: sourceURL)
                            )
                        ),
                    ]
                ),
                dataRoot: root
            )
        }
        try saveProof(
            sourcePath: "media/source.mp4",
            sourceURL: source
        )
        try MusicvideoGateChecks.requireRealRender(dataRoot: root)

        try saveProof(
            sourcePath: "media/substitute.mp4",
            sourceURL: substitute
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealRender(dataRoot: root)
        }
    }

    @Test("shotlist lineage binds referenced media to exact bytes")
    func shotlistReferenceLineage() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(
            at: media,
            withIntermediateDirectories: true
        )
        let source = media.appendingPathComponent("source.mp4")
        let reference = media.appendingPathComponent("reference.png")
        try Data("source-v1".utf8).write(to: source)
        try Data("reference-v1".utf8).write(to: reference)
        let song = try Song(
            title: "song",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: 12
        )
        let sourceShot = try Shot(
            id: "s001",
            section: "intro",
            timeStart: 0,
            timeEnd: 6,
            durationS: 6,
            type: .performance,
            sourceMode: .aiEnhanced,
            description: "Enhance the source.",
            visualPrompt: "Preserve the motion.",
            mood: "restrained",
            keyframeStrategy: .none,
            sourcePath: "media/source.mp4"
        )
        let referencedShot = try Shot(
            id: "s002",
            section: "intro",
            timeStart: 6,
            timeEnd: 12,
            durationS: 6,
            type: .performance,
            description: "Generate from the approved reference.",
            visualPrompt: "Preserve the approved identity.",
            mood: "restrained",
            keyframeStrategy: .none,
            seedanceInputMode: .reference,
            referenceImageRefs: ["media/reference.png"]
        )
        _ = try saveShotlist(
            try Shotlist(
                schema_: shotlistSchemaVersion,
                mode: .section,
                project: "demo",
                song: song,
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                shots: [sourceShot, referencedShot]
            ),
            to: root
        )

        let before = try MusicvideoPipelineLineage.snapshot(
            phase: "shotlist",
            dataRoot: root
        )
        try Data("source-v2".utf8).write(to: source)
        let afterSource = try MusicvideoPipelineLineage.snapshot(
            phase: "shotlist",
            dataRoot: root
        )
        #expect(before.artifactFingerprint != afterSource.artifactFingerprint)
        #expect(before.inputFingerprint != afterSource.inputFingerprint)

        try Data("reference-v2".utf8).write(to: reference)
        let afterReference = try MusicvideoPipelineLineage.snapshot(
            phase: "shotlist",
            dataRoot: root
        )
        #expect(
            afterSource.artifactFingerprint
                != afterReference.artifactFingerprint
        )
    }

    @Test("empty Frames and Render manifests are valid for an imported-only shot list")
    func importedOnlyPreparation() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let song = try Song(
            title: "song",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: 12
        )
        let imported = try Shot(
            id: "s001",
            section: "intro",
            timeStart: 0,
            timeEnd: 12,
            durationS: 12,
            type: .performance,
            sourceMode: .imported,
            description: "An imported performance clip.",
            visualPrompt: "The imported performance.",
            mood: "restrained",
            keyframeStrategy: .none
        )
        _ = try saveShotlist(
            try Shotlist(
                schema_: shotlistSchemaVersion,
                mode: .section,
                project: "demo",
                song: song,
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                shots: [imported]
            ),
            to: root
        )

        try MusicvideoPhasePreparation.frames(dataRoot: root)
        let frames = try loadFramesManifest(dataRoot: root)
        #expect(frames.shots.isEmpty)
        try MusicvideoGateChecks.requireRealFrames(dataRoot: root)

        try MusicvideoPhasePreparation.render(dataRoot: root)
        let render = try loadRenderManifest(dataRoot: root, phase: "final")
        let proof = try loadRenderProofManifest(
            dataRoot: root,
            phase: "final"
        )
        #expect(render.entries.isEmpty)
        #expect(proof.entries.isEmpty)
        try MusicvideoGateChecks.requireRealRender(dataRoot: root)
    }

    @Test("checkApprovable passes with no requirement and rethrows a blocked one")
    func checkApprovable() throws {
        let root = FileManager.default.temporaryDirectory
        try GateGuard.checkApprovable(phase: "brief", dataRoot: root, requirement: nil)
        #expect(throws: GateBlocked.self) {
            try GateGuard.checkApprovable(phase: "analysis", dataRoot: root, requirement: { _ in throw GateBlocked("nope") })
        }
    }

    @Test("requireChain blocks until every upstream gate is approved")
    func requireChainBlocks() throws {
        var gates = Gates(project: "p")
        GatesOperations.approve(&gates, phase: "project_init")
        #expect(throws: GateBlocked.self) {
            try GateGuard.requireChain(gates, order: coreGatePhases, through: "brief")
        }
        GatesOperations.approve(&gates, phase: "brief")
        try GateGuard.requireChain(gates, order: coreGatePhases, through: "brief")
    }

    @Test("requirePriorApproved enforces in-order approval")
    func priorApproved() throws {
        var gates = Gates(project: "p")
        // The first phase has no predecessors — always approvable.
        try GateGuard.requirePriorApproved(gates, order: coreGatePhases, phase: "project_init")
        // brief needs project_init first.
        #expect(throws: GateBlocked.self) {
            try GateGuard.requirePriorApproved(gates, order: coreGatePhases, phase: "brief")
        }
        GatesOperations.approve(&gates, phase: "project_init")
        try GateGuard.requirePriorApproved(gates, order: coreGatePhases, phase: "brief")
    }
}
