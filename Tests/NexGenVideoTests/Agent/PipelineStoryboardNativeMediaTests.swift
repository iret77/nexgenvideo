import AppKit
import AVFoundation
import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Native Storyboard source frames and external confirmations")
struct PipelineStoryboardNativeMediaTests {
    @Test func externalConfirmationRequiresNativeReviewAndBindsReceiptBytes() async throws {
        let (context, board) = try await storyboard()
        defer { context.document.close() }
        let shot = try #require(board.timing.shots.first)
        let moment = try #require(shot.moments.first)
        let image = try externalImage()
        let candidate = try await PipelineStoryboardNativeMedia.prepareExternal(from: image, shotID: shot.id,
            momentID: moment.id, expectedFingerprint: board.fingerprint, editor: context.editor)
        await #expect(throws: (any Error).self) {
            try await PipelineStoryboardNativeMedia.confirmExternal(candidate, sourceDescription: " ", editor: context.editor)
        }
        #expect(try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false).fingerprint == board.fingerprint)
        let assigned = try await PipelineStoryboardNativeMedia.confirmExternal(candidate,
            sourceDescription: "Director-supplied layout drawing", editor: context.editor)
        #expect(assigned.sketchProblems[moment.id] == nil)
        let proof = try #require(assigned.sketchProofs.values.first(where: { $0.momentID == moment.id }))
        guard case .externalConfirmed = proof.source else { Issue.record("Expected genuine external confirmation"); return }
        let references = try PipelineStoryboardNativeMedia.references(proof, dataRoot: context.dataRoot)
        let receipt = try #require(references.first(where: { $0.role == "host.storyboard-external-confirmation" }))
        #expect(assigned.references.contains(where: { $0.path == receipt.path && $0.sha256 == receipt.sha256 }))
        _ = try await ProductionPlanningAcceptanceFixture.attachSketches(in: context)
        let current = try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false)
        let freshCandidate = try await PipelineStoryboardNativeMedia.prepareExternal(from: image, shotID: shot.id,
            momentID: moment.id, expectedFingerprint: current.fingerprint, editor: context.editor)
        let replaced = try await PipelineStoryboardNativeMedia.confirmExternal(freshCandidate,
            sourceDescription: "Reviewed layout drawing", editor: context.editor)
        let replacedProof = try #require(replaced.sketchProofs.values.first(where: { $0.momentID == moment.id }))
        let replacedReceipt = try #require(PipelineStoryboardNativeMedia.references(replacedProof, dataRoot: context.dataRoot)
            .first(where: { $0.role == "host.storyboard-external-confirmation" }))
        try Data("changed native receipt".utf8).write(to: context.dataRoot.appendingPathComponent(replacedReceipt.path))
        await #expect(throws: (any Error).self) {
            try await ProductionPlanningAcceptanceFixture.approve("storyboard", in: context)
        }
        let repairable = try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false)
        #expect(repairable.sketchProblems[moment.id] != nil)
    }

    @Test func staleAndCompetingNativeCandidatesCannotAssign() async throws {
        let (context, board) = try await storyboard()
        defer { context.document.close() }
        let shot = try #require(board.timing.shots.first), moment = try #require(shot.moments.first)
        let candidate = try await PipelineStoryboardNativeMedia.prepareExternal(from: externalImage(), shotID: shot.id,
            momentID: moment.id, expectedFingerprint: board.fingerprint, editor: context.editor)
        let lease = try #require(context.editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: context.dataRoot, label: "Other native edit"))
        await #expect(throws: (any Error).self) {
            try await PipelineStoryboardNativeMedia.confirmExternal(candidate, sourceDescription: "Reviewed layout", editor: context.editor)
        }
        context.editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: context.dataRoot, id: lease)
        let newer = try await PipelineStoryboardEditor.apply(.setMoment(shotID: shot.id, momentID: moment.id,
            offsetTicks: moment.offsetTicks, intent: moment.intent + " with the door visible"),
            expectedFingerprint: board.fingerprint, editor: context.editor)
        await #expect(throws: (any Error).self) {
            try await PipelineStoryboardNativeMedia.confirmExternal(candidate, sourceDescription: "Reviewed layout", editor: context.editor)
        }
        #expect(try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false).fingerprint == newer.fingerprint)
    }

    @Test func agentFileToolsCannotPublishNativeMediaEvidence() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = try ProjectScaffold.initProject(home: home, name: "Native media authority", mode: .generic)
        _ = try ProjectLocalFile.ensureDirectory("import", dataRoot: root)
        let bytes = Data("File tools must reject native destinations before copying".utf8)
        try bytes.write(to: root.appendingPathComponent("import/candidate.png"))
        let harness = ToolHarness()
        let id = UUID().uuidString.lowercased()
        for path in ["storyboard/source-media/\(id)/source.mov", "storyboard/source-media/\(id)/selection.v1.json",
                     "storyboard/source-frame-receipts/\(id).v1.json", "storyboard/external-sketch-receipts/\(id).v1.json"] {
            let result = await harness.runRaw("copy_project_file", args: ["project_dir": root.path,
                "from": "import/candidate.png", "to": path])
            #expect(result.isError)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
            let imported = await harness.runRaw("import_media", args: ["source": ["path": root.appendingPathComponent("import/candidate.png").path], "destination": path])
            #expect(imported.isError)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        }
    }

    @Test func cancelledPreparationCannotPublish() async throws {
        let (context, board) = try await storyboard()
        defer { context.document.close() }
        let shot = try #require(board.timing.shots.first), moment = try #require(shot.moments.first)
        let image = try externalImage()
        let task = Task {
            try await PipelineStoryboardNativeMedia.prepareExternal(from: image, shotID: shot.id,
                momentID: moment.id, expectedFingerprint: board.fingerprint, editor: context.editor)
        }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false).fingerprint == board.fingerprint)
    }

    @Test func actualDecodedFrameBindsOriginalVideoActualTimeAndNativeReceipt() async throws {
        let (context, board) = try await storyboard()
        defer { context.document.close() }
        let video = try await makeVideo()
        let shot = try #require(board.timing.shots.first), moment = try #require(shot.moments.first)
        let source = try await PipelineStoryboardNativeMedia.importSource(from: video,
            expectedFingerprint: board.fingerprint, editor: context.editor)
        #expect(source.originalFilename == video.lastPathComponent)
        #expect(source.durationTicks > 0)
        let candidate = try await PipelineStoryboardNativeMedia.prepareFrame(source: source,
            sourceTick: source.timebase.ticksPerSecond / 3, shotID: shot.id, momentID: moment.id,
            expectedFingerprint: board.fingerprint, editor: context.editor)
        #expect(!candidate.previewData.isEmpty)
        #expect(candidate.sourceTick >= 0 && candidate.sourceTick < candidate.sourceDurationTicks)
        #expect(candidate.sourceTick * source.timebase.ticksPerSecond
            == candidate.requestedSourceTick * candidate.timebase.ticksPerSecond)
        let assigned = try await PipelineStoryboardNativeMedia.assignFrame(candidate, editor: context.editor)
        #expect(assigned.sketchProblems[moment.id] == nil)
        let proof = try #require(assigned.sketchProofs.values.first(where: { $0.momentID == moment.id }))
        guard case .sourceFrame(let original, let clock, let tick, let duration, _) = proof.source else {
            Issue.record("Expected source-frame proof"); return
        }
        #expect(original == source.source)
        #expect(clock == candidate.timebase && tick == candidate.sourceTick && duration == candidate.sourceDurationTicks)
        let closure = try PipelineStoryboardNativeMedia.references(proof, dataRoot: context.dataRoot)
        #expect(closure.contains(where: { $0.path.hasSuffix("/selection.v1.json") }))
        #expect(closure.contains(where: { $0.role == "host.storyboard-source-frame-selection" }))
        for reference in closure {
            #expect(assigned.references.contains(where: { $0.path == reference.path && $0.sha256 == reference.sha256 }))
        }
        await #expect(throws: (any Error).self) {
            try await PipelineStoryboardNativeMedia.prepareFrame(source: source, sourceTick: source.durationTicks,
                shotID: shot.id, momentID: moment.id, expectedFingerprint: assigned.fingerprint, editor: context.editor)
        }
        let receiptReference = try #require(closure.first(where: { $0.role == "host.storyboard-source-frame-selection" }))
        let receiptURL = context.dataRoot.appendingPathComponent(receiptReference.path)
        let receiptBytes = try Data(contentsOf: receiptURL)
        var invalidReceipt = try #require(JSONSerialization.jsonObject(with: receiptBytes) as? [String: Any])
        invalidReceipt["projectKey"] = "another-project"
        try JSONSerialization.data(withJSONObject: invalidReceipt).write(to: receiptURL)
        #expect(throws: (any Error).self) { try PipelineStoryboardNativeMedia.requireCurrent(proof, dataRoot: context.dataRoot) }
        try receiptBytes.write(to: receiptURL)
        invalidReceipt = try #require(JSONSerialization.jsonObject(with: receiptBytes) as? [String: Any])
        var invalidTime = try #require(invalidReceipt["actualTime"] as? [String: Any])
        invalidTime["value"] = 0
        invalidReceipt["actualTime"] = invalidTime
        try JSONSerialization.data(withJSONObject: invalidReceipt).write(to: receiptURL)
        #expect(throws: (any Error).self) { try PipelineStoryboardNativeMedia.requireCurrent(proof, dataRoot: context.dataRoot) }
        try receiptBytes.write(to: receiptURL)
        var complete = assigned
        let external = try externalImage()
        for other in complete.timing.shots {
            for otherMoment in other.moments where otherMoment.id != moment.id {
                let sketch = try await PipelineStoryboardNativeMedia.prepareExternal(from: external, shotID: other.id,
                    momentID: otherMoment.id, expectedFingerprint: complete.fingerprint, editor: context.editor)
                complete = try await PipelineStoryboardNativeMedia.confirmExternal(sketch,
                    sourceDescription: "Native reviewed layout", editor: context.editor)
            }
        }
        try await ProductionPlanningAcceptanceFixture.approve("storyboard", in: context)
        #expect(context.editor.projectState?.nextPhaseName == "shot_planning")
        await #expect(throws: (any Error).self) {
            try await PipelineStoryboardNativeMedia.importSource(from: video,
                expectedFingerprint: complete.fingerprint, editor: context.editor)
        }
        try Data("changed source video".utf8).write(to: context.dataRoot.appendingPathComponent(original.path))
        #expect(throws: (any Error).self) { try PipelineStoryboardNativeMedia.requireCurrent(proof, dataRoot: context.dataRoot) }
    }

    private func storyboard() async throws -> (ProductionPlanningAcceptanceFixture.Context, StoryboardBundleSnapshot) {
        let context = try await ProductionPlanningAcceptanceFixture.makeScript()
        var ready = false
        defer { if !ready { context.document.close() } }
        try await ProductionPlanningAcceptanceFixture.approve("script", in: context)
        let board = try await ProductionPlanningAcceptanceFixture.writeStoryboard(in: context)
        ready = true
        return (context, board)
    }

    private func externalImage() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Director-layout-\(UUID().uuidString).png")
        guard let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for y in 0..<32 { for x in 0..<32 { image.setColor(x < 16 ? .white : .black, atX: x, y: y) } }
        guard let data = image.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
        return url
    }

    private func makeVideo() async throws -> URL {
        try await Task.detached {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Source-original-\(UUID().uuidString).mov")
            let writer = try AVAssetWriter(url: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 32, AVVideoHeightKey: 32])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
            guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<3 {
                var waits = 0
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    waits += 1
                    guard waits < 1_000, writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                    try await Task.sleep(for: .milliseconds(5))
                }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                      let buffer else { throw CocoaError(.fileWriteUnknown) }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let bytes = CVPixelBufferGetBaseAddress(buffer) {
                    memset(bytes, Int32(frame * 80), CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 3)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
            }
            writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            return url
        }.value
    }
}
