import AVFoundation
import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Render review preparation cannot publish for a withdrawn turn")
struct RenderReviewPreparationCancellationTests {
    private actor ExportBarrier {
        var arrivals = 0
        var waiters: [CheckedContinuation<Void, any Error>] = []
        var deadline: Task<Void, Never>?
        func arrive() async throws {
            arrivals += 1
            if arrivals == 2 {
                deadline?.cancel()
                let pending = waiters; waiters.removeAll()
                pending.forEach { $0.resume() }
            } else {
                deadline = Task {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    let pending = waiters; waiters.removeAll()
                    pending.forEach { $0.resume(throwing: GateBlocked("Both media preparations must reach the actual exporter.")) }
                }
                try await withCheckedThrowingContinuation { waiters.append($0) }
            }
        }
    }

    @MainActor private final class PublishedReceipt {
        let url: URL
        var firstBytes: Data?
        init(_ url: URL) { self.url = url }
        func observe() throws {
            if firstBytes == nil, FileManager.default.fileExists(atPath: url.path) {
                firstBytes = try Data(contentsOf: url)
            }
        }
    }
    @MainActor private final class Validation {
        var calls = 0
        let cancelTask: Bool
        init(cancelTask: Bool) { self.cancelTask = cancelTask }
        func requireCurrent() throws {
            calls += 1
            if calls == 3 {
                if cancelTask { withUnsafeCurrentTask { $0?.cancel() } }
                else { throw CancellationError() }
            }
        }
    }

    private func files(_ root: URL) throws -> [String: String] {
        let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        return try Dictionary(uniqueKeysWithValues: paths.filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }.map { (String($0.path.dropFirst(root.path.count + 1)), try FileDigest.sha256(of: $0)) })
    }

    @Test func withdrawalAfterActualRangeExportLeavesNoMediaReceiptOrCanonicalMutation() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeScript()
        defer { context.document.close() }
        let original = try await ProductionPlanningAcceptanceFixture.makeSourceVideo()
        defer { try? FileManager.default.removeItem(at: original) }
        _ = try ProjectLocalFile.ensureDirectory("sources", dataRoot: context.dataRoot)
        let path = "sources/actual-video.mov"
        try FileManager.default.copyItem(at: original, to: context.dataRoot.appendingPathComponent(path))
        let source = try PlanningWriterIO.reference(path, id: "original-video", role: "core.source-video", dataRoot: context.dataRoot)
        let selection = PipelineProductionInputMedia.Selection(source: source,
            timebase: .init(ticksPerSecond: 600, fpsNumerator: 30), startTicks: 600, durationTicks: 1200, modality: .video)
        let access = try PipelinePlanningWriteAccess(dataRoot: context.dataRoot,
            declaration: .init(packName: nil, binding: nil, productionContract: .current), phase: "script")
        let before = try files(context.dataRoot)
        for cancelTask in [false, true] {
            let validation = Validation(cancelTask: cancelTask)
            let operation = Task {
                try await PipelineProductionInputMedia.prepare(selection, access: access,
                    revalidate: { try validation.requireCurrent() })
            }
            await #expect(throws: CancellationError.self) { _ = try await operation.value }
            #expect(validation.calls == 3)
            #expect(try files(context.dataRoot) == before)
        }
        let prepared = try await PipelineProductionInputMedia.prepare(selection, access: access)
        let cached = try await PipelineProductionInputMedia.prepare(selection, access: access)
        #expect(prepared == cached)
        let receipt = try PipelineProductionInputMedia.requirePrepared(selection, dataRoot: context.dataRoot)
        #expect(receipt.reference == prepared)
        #expect(receipt.receipt.selection == selection)
        let withdrawn = Task {
            try await PipelineProductionInputMedia.prepare(selection, access: access, revalidate: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        await #expect(throws: CancellationError.self) { _ = try await withdrawn.value }
    }

    @Test func nativeCaptureUsesActualPhaseLeaseAndRepeatedUnchangedReviewIsStable() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeImportedAssembly()
        defer { context.document.close() }
        let home = try #require(context.editor.workingRoot)
        try NativeGateWriter.rewind(projectDir: home, targetPhase: "render_review", declaredPack: nil,
            declaredProductionContract: .current, executionCoordinator: context.editor.pipelinePhaseRunCoordinator)
        let first = try await PipelineRenderReviewWriter.capture(editor: context.editor)
        let before = try files(context.dataRoot)
        let lease = try #require(context.editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: context.dataRoot, label: "Competing native edit"))
        var leaseHeld = true
        defer { if leaseHeld { context.editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: context.dataRoot, id: lease) } }
        do {
            _ = try await PipelineRenderReviewWriter.capture(editor: context.editor)
            Issue.record("Capture ignored the competing native edit")
        } catch let error as GateBlocked {
            #expect(error.message.contains("Wait for the current production job"))
        }
        #expect(context.editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: context.dataRoot, id: lease))
        #expect(try files(context.dataRoot) == before)
        context.editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: context.dataRoot, id: lease)
        leaseHeld = false
        let repeated = try await PipelineRenderReviewWriter.capture(editor: context.editor)
        #expect(repeated == first)
        #expect(try files(context.dataRoot) == before)
    }

    @Test func concurrentActualExportsPublishOnlyOneImmutableReceipt() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeScript()
        defer { context.document.close() }
        let original = try await ProductionPlanningAcceptanceFixture.makeSourceVideo()
        defer { try? FileManager.default.removeItem(at: original) }
        _ = try ProjectLocalFile.ensureDirectory("sources", dataRoot: context.dataRoot)
        let path = "sources/concurrent-video.mov"
        try FileManager.default.copyItem(at: original, to: context.dataRoot.appendingPathComponent(path))
        let source = try PlanningWriterIO.reference(path, id: "concurrent-video", role: "core.source-video", dataRoot: context.dataRoot)
        let selection = PipelineProductionInputMedia.Selection(source: source,
            timebase: .init(ticksPerSecond: 600, fpsNumerator: 30), startTicks: 600, durationTicks: 1200, modality: .video)
        let access = try PipelinePlanningWriteAccess(dataRoot: context.dataRoot,
            declaration: .init(packName: nil, binding: nil, productionContract: .current), phase: "script")
        let identity = FileDigest.sha256(of: try PlanningWriterIO.json(selection))
        let receiptURL = context.dataRoot.appendingPathComponent("execution/materialized-media/\(identity).v1.json")
        let observed = PublishedReceipt(receiptURL)
        let barrier = ExportBarrier()
        let export: @Sendable (URL, CMTimeRange, AssetPhysicalModalityV1, URL) async throws -> CMTime = { source, range, modality, destination in
            try await barrier.arrive()
            return try await PipelineProductionInputMedia.exportRange(source: source, range: range, modality: modality, to: destination)
        }
        async let first = PipelineProductionInputMedia.prepare(selection, access: access,
            revalidate: { try observed.observe() }, exportMedia: export)
        async let second = PipelineProductionInputMedia.prepare(selection, access: access,
            revalidate: { try observed.observe() }, exportMedia: export)
        let results = try await (first, second)
        #expect(await barrier.arrivals == 2)
        #expect(results.0 == results.1)
        let firstBytes = try #require(observed.firstBytes)
        #expect(try Data(contentsOf: receiptURL) == firstBytes)
        let published = try JSONDecoder().decode(PipelineProductionInputMedia.Receipt.self, from: firstBytes)
        let current = try PipelineProductionInputMedia.requirePrepared(selection, dataRoot: context.dataRoot)
        #expect(current.receipt == published)
        #expect(current.receipt.recordedAt == published.recordedAt)
    }
    @Test func cacheReadRefusesSourceOutputAndReceiptChangesMadeByTheFinalValidator() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeScript()
        defer { context.document.close() }
        let original = try await ProductionPlanningAcceptanceFixture.makeSourceVideo()
        defer { try? FileManager.default.removeItem(at: original) }
        _ = try ProjectLocalFile.ensureDirectory("sources", dataRoot: context.dataRoot)
        let path = "sources/cache-fence-video.mov"
        let sourceURL = context.dataRoot.appendingPathComponent(path)
        try FileManager.default.copyItem(at: original, to: sourceURL)
        let source = try PlanningWriterIO.reference(path, id: "cache-fence-video", role: "core.source-video", dataRoot: context.dataRoot)
        let selection = PipelineProductionInputMedia.Selection(source: source,
            timebase: .init(ticksPerSecond: 600, fpsNumerator: 30), startTicks: 600, durationTicks: 1200, modality: .video)
        let access = try PipelinePlanningWriteAccess(dataRoot: context.dataRoot,
            declaration: .init(packName: nil, binding: nil, productionContract: .current), phase: "script")
        let prepared = try await PipelineProductionInputMedia.prepare(selection, access: access)
        let receipt = try PipelineProductionInputMedia.requirePrepared(selection, dataRoot: context.dataRoot)
        let baseline = try files(context.dataRoot)
        for target in [sourceURL, context.dataRoot.appendingPathComponent(receipt.receipt.output.path),
                       context.dataRoot.appendingPathComponent(prepared.path)] {
            let bytes = try Data(contentsOf: target)
            var calls = 0
            await #expect(throws: GateBlocked.self) {
                _ = try await PipelineProductionInputMedia.prepare(selection, access: access, revalidate: {
                    calls += 1
                    if calls == 2 { try (bytes + Data([0x31])).write(to: target, options: .atomic) }
                })
            }
            #expect(calls == 2)
            try bytes.write(to: target, options: .atomic)
            #expect(try files(context.dataRoot) == baseline)
        }
        #expect(try await PipelineProductionInputMedia.prepare(selection, access: access) == prepared)
    }

    @Test func sourceChangeAfterTheActualExportCannotPublishThePreparedMedia() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeScript()
        defer { context.document.close() }
        let original = try await ProductionPlanningAcceptanceFixture.makeSourceVideo()
        defer { try? FileManager.default.removeItem(at: original) }
        _ = try ProjectLocalFile.ensureDirectory("sources", dataRoot: context.dataRoot)
        let path = "sources/post-export-fence-video.mov"
        let sourceURL = context.dataRoot.appendingPathComponent(path)
        try FileManager.default.copyItem(at: original, to: sourceURL)
        let originalBytes = try Data(contentsOf: sourceURL)
        defer { try? originalBytes.write(to: sourceURL, options: .atomic) }
        let source = try PlanningWriterIO.reference(path, id: "post-export-video", role: "core.source-video", dataRoot: context.dataRoot)
        let selection = PipelineProductionInputMedia.Selection(source: source,
            timebase: .init(ticksPerSecond: 600, fpsNumerator: 30), startTicks: 600, durationTicks: 1200, modality: .video)
        let access = try PipelinePlanningWriteAccess(dataRoot: context.dataRoot,
            declaration: .init(packName: nil, binding: nil, productionContract: .current), phase: "script")
        let baseline = try files(context.dataRoot)
        var calls = 0
        await #expect(throws: GateBlocked.self) {
            _ = try await PipelineProductionInputMedia.prepare(selection, access: access, revalidate: {
                calls += 1
                if calls == 3 { try (originalBytes + Data([0x31])).write(to: sourceURL, options: .atomic) }
            })
        }
        #expect(calls == 3)
        try originalBytes.write(to: sourceURL, options: .atomic)
        #expect(try files(context.dataRoot) == baseline)
        _ = try await PipelineProductionInputMedia.prepare(selection, access: access)
    }

}
