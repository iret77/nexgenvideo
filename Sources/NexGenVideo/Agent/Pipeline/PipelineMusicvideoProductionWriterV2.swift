import AVFoundation
import Foundation
import NexGenEngine

@MainActor
enum PipelineMusicvideoProductionWriterV2 {
    struct Prepared: Sendable {
        let revision: Int
        let projectID: String
        let proposedPlan: MusicvideoProductionPlanDraftV1
        let track: CanonicalArtifactReferenceV1
        let analysis: CanonicalArtifactReferenceV1
        let treatment: CanonicalArtifactReferenceV1
        let timing: CanonicalArtifactReferenceV1
        let inputs: [CanonicalArtifactReferenceV1]
        let segments: [MaterializedMusicPerformanceSegmentV1]
        let receipts: [CanonicalArtifactReferenceV1]
        let files: [(path: String, bytes: Data)]
        fileprivate init(revision: Int, projectID: String, proposedPlan: MusicvideoProductionPlanDraftV1,
                         track: CanonicalArtifactReferenceV1, analysis: CanonicalArtifactReferenceV1,
                         treatment: CanonicalArtifactReferenceV1, timing: CanonicalArtifactReferenceV1,
                         inputs: [CanonicalArtifactReferenceV1], segments: [MaterializedMusicPerformanceSegmentV1],
                         receipts: [CanonicalArtifactReferenceV1], files: [(path: String, bytes: Data)]) {
            self.revision = revision; self.projectID = projectID; self.proposedPlan = proposedPlan
            self.track = track; self.analysis = analysis; self.treatment = treatment; self.timing = timing
            self.inputs = inputs; self.segments = segments; self.receipts = receipts; self.files = files
        }
    }

    static func prepare(proposal: PipelineProductionPlanWriter.Proposal, revision: Int,
                        access: PipelinePlanningWriteAccess) async throws -> Prepared? {
        guard access.workflow.packID == "musicvideo" else {
            guard proposal.musicvideoPlan == nil else { throw GateBlocked("Song performance planning belongs to the Music Video workflow.") }
            return nil
        }
        guard access.phase == "shotlist", let proposed = proposal.musicvideoPlan else {
            throw GateBlocked("The Music Video Shot List needs its song performance, visual arc and coverage plan.")
        }
        try access.revalidate()
        let registry = PackCatalog.registry(activePack: access.workflow.packID)
        guard let gate = try PhaseContractRuntime.gateRequirement(workflow: access.workflow, phase: "analysis", registry: registry),
              let artifacts = registry.phaseArtifactProviders["analysis"],
              let lineage = try PhaseContractRuntime.lineageProvider(workflow: access.workflow, phase: "analysis", registry: registry) else {
            throw GateBlocked("The verified Music Video analysis contract is unavailable. Reopen the project.")
        }
        let root = access.dataRoot
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try gate(root)
            try PipelineLineageStore.requireCurrent(phase: "analysis", snapshot: lineage(root), dataRoot: root)
            let board = try PlanningWriterIO.storyboard(dataRoot: root)
            guard let track = board.timing.audio?.source, board.timing.audio?.offsetTicks == 0,
                  let analysisURL = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: root) else {
                throw GateBlocked("Use the approved original song and its verified analysis for performance planning.")
            }
            let analysis = try PlanningWriterIO.reference(FrameInventory.relativePath(of: analysisURL, to: root),
                id: "music-analysis", role: "musicvideo.analysis", dataRoot: root)
            let causality = try TreatmentCausalityStoreV2.requireCurrent(dataRoot: root)
            let treatment = causality.treatmentReference
            guard let timing = board.references.first(where: { $0.path == StoryboardTimingV1.versionPath(board.timing.header.revision) }) else {
                throw GateBlocked("The canonical Storyboard timing reference is missing.")
            }
            var inputs = try artifacts(root).map { path in
                try PlanningWriterIO.reference(path, id: "music-analysis-input-" + FileDigest.sha256(of: Data(path.utf8)),
                    role: "musicvideo.analysis-evidence", dataRoot: root)
            } + [track, analysis, treatment, timing] + causality.header.inputs
                + [try PlanningWriterIO.reference(TreatmentCausalityV2.versionPath(causality.header.revision),
                    id: "music-treatment-causality", role: "musicvideo.treatment-causality", dataRoot: root)]
            let audioURL = try ProjectLocalFile.requireHash(track.sha256, at: track.path, dataRoot: root)
            var segments: [MaterializedMusicPerformanceSegmentV1] = []
            var receipts: [CanonicalArtifactReferenceV1] = []
            var files: [(path: String, bytes: Data)] = []
            try MusicvideoProductionValidatorV1.validate(proposed)
            for original in proposed.performanceSegments {
                try Task.checkCancellation()
                let draft = try normalized(original, analysis: analysis)
                let exported = try export(audioURL: audioURL, draft: draft)
                let directory = ShotPlanningPromotionV1.planningDirectory(revision: revision) + "/performance-audio/"
                    + FileDigest.sha256(of: Data(draft.id.utf8))
                let outputPath = directory + "/segment.wav"
                let output = PlanningWriterIO.reference(outputPath, id: "music-audio-" + draft.id,
                    role: "musicvideo.performance-audio", bytes: exported.bytes)
                let receipt = MusicPerformanceAudioReceiptV2(projectID: board.timing.header.projectID, revision: revision,
                    segmentID: draft.id, source: track, output: output, startSample: draft.sourceStartSample,
                    endSample: draft.sourceEndSample, sourceFrameCount: exported.sourceFrames, exportedSampleCount: exported.samples,
                    sampleRate: draft.sampleRate, channels: exported.channels, byteCount: Int64(exported.bytes.count),
                    recordedAt: ISO8601DateFormatter().string(from: Date()))
                let receiptPath = directory + "/receipt.v2.json"
                let receiptBytes = try PlanningWriterIO.json(receipt)
                let receiptRef = PlanningWriterIO.reference(receiptPath, id: "music-audio-receipt-" + draft.id,
                    role: "host.music-performance-audio", bytes: receiptBytes)
                files += [(outputPath, exported.bytes), (receiptPath, receiptBytes)]
                receipts.append(receiptRef)
                segments.append(.init(draft: draft, sourceTrackPath: track.path, sourceTrackSHA256: track.sha256,
                    segmentPath: outputPath, segmentSHA256: output.sha256, segmentByteCount: Int64(exported.bytes.count), exportedSampleCount: exported.samples))
                inputs += [output, receiptRef]
            }
            _ = try MusicvideoProductionExtensionStoreV2.sections(analysis: analysis, timing: board.timing, dataRoot: root)
            for reference in inputs where !files.contains(where: { $0.path == reference.path }) {
                _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)
            }
            try gate(root)
            try Task.checkCancellation()
            return Prepared(revision: revision, projectID: board.timing.header.projectID, proposedPlan: proposed,
                track: track, analysis: analysis, treatment: treatment, timing: timing,
                inputs: inputs, segments: segments, receipts: receipts, files: files)
        }
        let prepared = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        try access.revalidate()
        return prepared
    }

    nonisolated private static func normalized(_ draft: MusicPerformanceSegmentDraftV1,
                                              analysis: CanonicalArtifactReferenceV1) throws -> MusicPerformanceSegmentDraftV1 {
        guard draft.lyricsAlignmentPath == nil || (draft.lyricsAlignmentPath == analysis.path && draft.lyricsAlignmentSHA256 == analysis.sha256) else {
            throw GateBlocked("Performance lyrics alignment must use the current independently verified song analysis.")
        }
        return .init(id: draft.id, shotIDs: draft.shotIDs, sourceStartSample: draft.sourceStartSample,
            sourceEndSample: draft.sourceEndSample, sampleRate: draft.sampleRate, timelineStartSeconds: draft.timelineStartSeconds,
            purpose: draft.purpose, performerIDs: draft.performerIDs, audibleVoiceIDs: draft.audibleVoiceIDs,
            mouthOwnership: draft.mouthOwnership,
            lyricsAlignmentPath: draft.purpose == .performedSong ? analysis.path : draft.lyricsAlignmentPath,
            lyricsAlignmentSHA256: draft.purpose == .performedSong ? analysis.sha256 : draft.lyricsAlignmentSHA256,
            routeInputRoleID: draft.routeInputRoleID, phraseBoundaryEvidence: draft.phraseBoundaryEvidence)
    }

    nonisolated static func export(audioURL: URL, draft: MusicPerformanceSegmentDraftV1) throws -> (bytes: Data, sourceFrames: Int64, samples: Int64, channels: Int) {
        let audio = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatInt16, interleaved: true)
        let format = audio.processingFormat
        guard format.sampleRate == Double(draft.sampleRate), format.channelCount > 0, format.channelCount <= 2,
              draft.sourceStartSample >= 0, draft.sourceEndSample > draft.sourceStartSample,
              draft.sourceEndSample <= audio.length else {
            throw GateBlocked("Select a real sample range inside the approved song at its measured sample rate.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("music-performance-" + UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let count = draft.sourceEndSample - draft.sourceStartSample
        audio.framePosition = draft.sourceStartSample
        var remaining = count
        do {
            let output = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false], commonFormat: .pcmFormatInt16, interleaved: true)
            while remaining > 0 {
                try Task.checkCancellation()
                let frames = AVAudioFrameCount(min(remaining, 65_536))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw GateBlocked("The song samples could not be read.") }
                try audio.read(into: buffer, frameCount: frames)
                guard buffer.frameLength > 0, Int64(buffer.frameLength) <= remaining else { throw GateBlocked("The song segment ended before its declared sample range.") }
                try output.write(from: buffer)
                remaining -= Int64(buffer.frameLength)
            }
        }
        let bytes = try Data(contentsOf: url)
        return (bytes, audio.length, count, Int(format.channelCount))
    }
}
