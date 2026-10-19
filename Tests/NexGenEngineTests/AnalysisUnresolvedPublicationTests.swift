import Foundation
import NexGenEngine
import Testing
@testable import MusicvideoPlugin

@Suite("Measured unresolved analysis publication")
struct AnalysisUnresolvedPublicationTests {
    private func fixture() throws -> (URL, URL, Data) {
        let root = try AnalysisRunnerPlumbingTests.makeProject(name: "Unresolved measurement")
        let song = root.appendingPathComponent("audio/unresolved.wav")
        try Data("Isolated structural validator source; native owner decodes a genuine WAV separately.".utf8).write(to: song)
        let hash = try FileDigest.sha256(of: song)
        let raw = AudioAnalysis(sampleRate: 48_000, durationS: 8, bpm: 120,
            beats: stride(from: 0.0, through: 8.0, by: 0.5).map { $0 }, downbeats: [0], downbeatSource: "beat-transformer",
            sections: [.init(index: 0, start: 0, end: 8, cluster: 0)], energyCurve: [], tempoCurve: [])
        let canonical = try MusicvideoAnalysisRunner.toCanonicalDetailed(raw,
            project: "Unresolved measurement", songPath: "audio/unresolved.wav", songSha256: hash)
        #expect(canonical.structureResolution.status == .needsReview)
        let data = try MusicvideoAnalysisRunner.encodeArtifact(canonical.analysis, structureResolution: canonical.structureResolution,
            stageDiagnostics: [.init(stage: "native_dsp", status: .succeeded, detail: "Explicit structural fixture"),
                .init(stage: "neural_beat_grid", status: .succeeded, detail: "One measured downbeat cannot establish a bar duration.")])
        let artifact = try #require(AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: root))
        try data.write(to: artifact)
        try AnalysisMeasurementProofStore.save(.init(project: "Unresolved measurement", songSHA256: hash, lyricsAlignment: nil), dataRoot: root)
        return (root, artifact, data)
    }

    @Test func genuineConsolidatorUnresolvedResultCanPublishButCannotBeInterpretedOrApproved() throws {
        let (root, _, _) = try fixture()
        try MusicvideoGateChecks.requireMeasuredAnalysis(dataRoot: root)
        #expect(throws: (any Error).self) { try MusicvideoGateChecks.requireInterpretableAnalysis(dataRoot: root) }
        #expect(throws: (any Error).self) { try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root) }
    }

    @Test func unresolvedPublicationRejectsChangedSourceAndMissingMeasurementProof() throws {
        let (root, _, _) = try fixture()
        let song = root.appendingPathComponent("audio/unresolved.wav")
        let original = try Data(contentsOf: song)
        try Data("Changed source".utf8).write(to: song)
        #expect(throws: (any Error).self) { try MusicvideoGateChecks.requireMeasuredAnalysis(dataRoot: root) }
        try original.write(to: song)
        let proof = try #require(AnalysisMeasurementProofStore.url(dataRoot: root))
        try Data("Unreadable proof".utf8).write(to: proof)
        #expect(throws: (any Error).self) { try MusicvideoGateChecks.requireMeasuredAnalysis(dataRoot: root) }
    }

    @Test func unresolvedPublicationRebuildsCanonicalCandidatesInsteadOfTrustingAStatusFlag() throws {
        let (root, file, bytes) = try fixture()
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["stage_diagnostics"] = [] },
            { $0["pipeline_stages"] = ["load_audio", "rhythm", "features", "structure"] },
            { object in
                var resolution = object["structure_resolution"] as! [String: Any]
                resolution["candidate_boundary_count"] = 999; object["structure_resolution"] = resolution
            },
            { object in
                var sections = object["sections"] as! [[String: Any]]
                sections[0]["source"] = "measured_consensus"; object["sections"] = sections
            },
            { object in
                var sections = object["sections"] as! [[String: Any]]
                sections[0]["end"] = 7.5; object["sections"] = sections
            },
            { $0["downbeats"] = [0, 2, 4, 6, 8] },
        ]
        for mutation in mutations {
            var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            mutation(&object)
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            #expect(throws: (any Error).self) { try MusicvideoGateChecks.requireMeasuredAnalysis(dataRoot: root) }
        }
        try bytes.write(to: file)
        try MusicvideoGateChecks.requireMeasuredAnalysis(dataRoot: root)
    }
}
