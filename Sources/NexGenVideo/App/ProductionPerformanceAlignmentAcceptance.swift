import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum ProductionPerformanceAlignmentAcceptance {
    static func bind(_ base: MusicvideoProductionPlanDraftV1,
                     context: ProductionPlanningAcceptanceFixture.Context) async throws -> MusicvideoProductionPlanDraftV1 {
        let root = context.dataRoot
        return try await Task.detached {
            let board = try PlanningWriterIO.storyboard(dataRoot: root)
            guard board.timing.shots.count == 2, let track = board.timing.audio?.source,
                  board.timing.shots.first?.startTicks == 0 else { throw failed("The performance fixture needs two actual contiguous song shots.") }
            let file = try AVAudioFile(forReading: ProjectLocalFile.requireHash(track.sha256, at: track.path, dataRoot: root))
            let rate = file.processingFormat.sampleRate
            guard rate.isFinite, (8_000...192_000).contains(rate), rate.rounded() == rate, file.length > 0 else {
                throw failed("The actual original song has no valid native sample interval.")
            }
            let segment = MusicPerformanceSegmentDraftV1(id: "native-performance-phrase", shotIDs: board.timing.shots.map(\.id),
                sourceStartSample: 0, sourceEndSample: file.length, sampleRate: Int(rate), timelineStartSeconds: 0,
                purpose: .timingOnly, performerIDs: [], audibleVoiceIDs: [], mouthOwnership: [],
                routeInputRoleID: CoreReferenceInputSlotIDV1.audioTiming,
                phraseBoundaryEvidence: "The complete approved original-song interval spans these two contiguous shots, from sample zero to the actual decoded source end.")
            return .init(performanceSegments: [segment], finalMix: base.finalMix, visualArc: base.visualArc, coverage: base.coverage)
        }.value
    }

    static func run(context: ProductionPlanningAcceptanceFixture.Context, takeID: String, rangeID: String,
                    driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        let root = context.dataRoot
        let projection = try await Task.detached { try ProductionPlanningLineageV2.projection(dataRoot: root) }.value
        let music = try await Task.detached { try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: root) }.value
        guard projection.shots.count == 2, let generated = projection.shots.first(where: { $0.sourceMode == .generated }),
              let imported = projection.shots.first(where: { $0.sourceMode == .imported }),
              music.performanceSegments.count == 1, let segment = music.performanceSegments.first,
              Set(segment.draft.shotIDs) == Set(projection.shots.map(\.id)), segment.draft.purpose == .timingOnly,
              segment.draft.performerIDs.isEmpty, segment.draft.mouthOwnership.isEmpty else {
            throw failed("The native alignment scenario is not the actual mixed two-shot timing segment.")
        }
        try await ProductionV2PlanningAcceptance.selectPhase("render", context: context, driver: driver)
        var receipts: [[String: Any]] = []
        for shot in projection.shots {
            receipts.append(try await review(shotID: shot.id, context: context, driver: driver, suffix: "initial"))
        }
        let selected = try await Task.detached { try PipelineProductionRenderWriter.requireSelected(shotID: generated.id, dataRoot: root) }.value
        guard selected.selection.takeID == takeID, selected.selection.nativeRange?.id == rangeID else {
            throw failed("The actual native range was not selected before its alignment review.")
        }
        let importedReceipt = try await pointer(shotID: imported.id, root: root)
        try await select(whole: true, takeID: takeID, rangeID: rangeID, shotID: generated.id, context: context, driver: driver)
        try await requireBlocked(generated.id, context: context, driver: driver)
        guard try await pointer(shotID: imported.id, root: root) == importedReceipt else { throw failed("Changing the generated take altered the imported shot's alignment.") }
        receipts.append(try await review(shotID: generated.id, context: context, driver: driver, suffix: "whole-take"))
        try await select(whole: false, takeID: takeID, rangeID: rangeID, shotID: generated.id, context: context, driver: driver)
        try await requireBlocked(generated.id, context: context, driver: driver)
        receipts.append(try await review(shotID: generated.id, context: context, driver: driver, suffix: "restored-range"))
        let final = try await PipelineProductionAssemblyController.capture(editor: context.editor)
        guard final.state == .ready else { throw failed("Current explicit alignment did not restore assembly readiness.") }
        try driver.record("native multi-shot performance alignment", fields: ["shotIDs": segment.draft.shotIDs,
            "generatedShotID": generated.id, "importedShotID": imported.id, "sourceStartSample": segment.draft.sourceStartSample,
            "sourceEndSample": segment.draft.sourceEndSample, "sampleRate": segment.draft.sampleRate,
            "takeChangeRevokedAlignment": true, "rangeChangeRevokedAlignment": true, "finalAssemblyReady": true])
        return ["shotIDs": segment.draft.shotIDs, "sourceStartSample": segment.draft.sourceStartSample,
            "sourceEndSample": segment.draft.sourceEndSample, "sampleRate": segment.draft.sampleRate,
            "purpose": segment.draft.purpose.rawValue, "receipts": receipts,
            "nativeGeneratedAndImportedEntries": true, "nativeWholePreviewAndConfirmation": true,
            "takeAndRangeChangesBlockAssembly": true, "finalAssemblyReady": true]
    }

    private static func review(shotID: String, context: ProductionPlanningAcceptanceFixture.Context,
                               driver: ProductionVisualSourcesDriver, suffix: String) async throws -> [String: Any] {
        let editor = context.editor, root = context.dataRoot, window = driver.window
        let expected = try await Task.detached {
            try PipelineProductionPerformanceAlignment.candidate(shotID: shotID,
                projection: ProductionPlanningLineageV2.projection(dataRoot: root), dataRoot: root)
        }.value
        guard let expected else { throw failed("The actual shot has no performance phrase binding.") }
        let initialPointer = try await pointer(shotID: shotID, root: root)
        try await driver.click("performance.alignment.open." + shotID, in: window)
        var sheet = try await driver.sheet("performance.alignment.sheet")
        try await driver.wait("actual phrase preview prepared", seconds: 60) { driver.state("performance.alignment.play", in: sheet) == true }
        guard driver.state("performance.alignment.confirm", in: sheet) == false else { throw failed("An unreviewed phrase can be confirmed.") }
        try await driver.click("performance.alignment.close", in: sheet)
        try await driver.wait("prepared phrase preview cancelled") { window.attachedSheet == nil && window.isKeyWindow }
        guard try await pointer(shotID: shotID, root: root) == initialPointer else { throw failed("Closing a preview recorded alignment without confirmation.") }
        try await driver.click("performance.alignment.open." + shotID, in: window)
        sheet = try await driver.sheet("performance.alignment.sheet")
        try await driver.wait("actual simultaneous phrase player ready", seconds: 60) {
            ProductionNativePlaybackAcceptance.player("performance.alignment.player", in: sheet)?.currentItem?.status == .readyToPlay
        }
        guard let player = ProductionNativePlaybackAcceptance.player("performance.alignment.player", in: sheet),
              let item = player.currentItem, let asset = item.asset as? AVURLAsset,
              player.rate == 0, player.currentTime().seconds < 0.01,
              CMTimeCompare(item.forwardPlaybackEndTime, expected.duration.cmTime) == 0,
              try await asset.loadTracks(withMediaType: .video).count == 1,
              try await asset.loadTracks(withMediaType: .audio).count == 1,
              let previewHash = driver.text("performance.alignment.player", in: sheet) else {
            throw failed("The visible player is not the exact simultaneous video/song preview with its rational playback boundary.")
        }
        let previewURL = asset.url
        guard try await Task.detached(operation: { try FileDigest.sha256(of: previewURL) }).value == previewHash else {
            throw failed("The visible phrase preview bytes do not match their exact native binding.")
        }
        try await driver.reveal("performance.alignment.player", in: sheet)
        try driver.visible(["performance.alignment.player", "performance.alignment.close", "performance.alignment.confirm"], in: sheet)
        try await driver.click("performance.alignment.play", in: sheet)
        try await driver.wait("actual image and original phrase playing") { player.rate > 0 && player.currentTime().seconds > 0 }
        try driver.capture("alignment-playing-" + shotID + "-" + suffix, target: sheet)
        try await driver.wait("entire rational phrase interval played", seconds: expected.duration.cmTime.seconds + 5) {
            player.rate == 0 && CMTimeCompare(player.currentTime(), CMTimeSubtract(expected.duration.cmTime,
                CMTime(value: 1, timescale: expected.duration.timescale))) >= 0
        }
        try await driver.click("performance.alignment.observe", in: sheet, enabled: false)
        try await driver.wait("explicit watched and listened confirmation") { driver.state("performance.alignment.observe", in: sheet) == true }
        guard driver.state("performance.alignment.confirm", in: sheet) == false else { throw failed("An alignment with no actual observation is confirmable.") }
        let note = "Played the complete image range with the original song from \(expected.songStart.value)/\(expected.songStart.timescale) for \(expected.duration.value)/\(expected.duration.timescale); the moving test shape preserves this timing."
        try await driver.fill("performance.alignment.observation", value: note, in: sheet)
        try await driver.click("performance.alignment.confirm", in: sheet)
        try await driver.wait("native exact alignment receipt recorded", seconds: 60) { driver.text("performance.alignment.recorded", in: sheet)?.count == 64 }
        let written = try await Task.detached {
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
            _ = try PipelineProductionPerformanceAlignment.requireCurrent(shotID: shotID, projection: projection, dataRoot: root)
            let reference = try PlanningWriterIO.read(CanonicalArtifactReferenceV1.self,
                at: PipelineProductionPerformanceAlignment.currentPath(shotID), dataRoot: root)
            let receipt = try PlanningWriterIO.read(PipelineProductionPerformanceAlignment.Receipt.self, at: reference.path, dataRoot: root)
            return (reference, receipt)
        }.value
        guard written.1.binding == expected, written.1.preview.sha256 == previewHash,
              written.1.observation == note, written.1.watchedAndListened, written.1.reviewer == "native-user",
              driver.text("performance.alignment.recorded", in: sheet) == written.0.sha256 else {
            throw failed("The saved native receipt differs from the actually played binding and typed observation.")
        }
        let destination = driver.output.appendingPathComponent("alignment-" + shotID + "-" + suffix + ".mov")
        let receiptFile = destination.deletingPathExtension().appendingPathExtension("json")
        try await Task.detached {
            try FileManager.default.copyItem(at: ProjectLocalFile.requireHash(written.0.sha256,
                at: written.0.path, dataRoot: root), to: receiptFile)
            try FileManager.default.copyItem(at: ProjectLocalFile.requireHash(written.1.preview.sha256,
                at: written.1.preview.path, dataRoot: root), to: destination)
        }.value
        try driver.capture("alignment-confirmed-" + shotID + "-" + suffix, target: sheet)
        try await driver.click("performance.alignment.close", in: sheet)
        try await driver.wait("confirmed phrase sheet closed") { window.attachedSheet == nil && window.isKeyWindow }
        let result: [String: Any] = ["shotID": shotID, "receiptSHA256": written.0.sha256, "previewSHA256": previewHash,
            "previewFile": destination.lastPathComponent, "receiptFile": receiptFile.lastPathComponent, "videoSHA256": expected.video.sha256,
            "songSHA256": expected.originalSong.sha256, "songStart": [expected.songStart.value, Int64(expected.songStart.timescale)],
            "duration": [expected.duration.value, Int64(expected.duration.timescale)], "observation": note,
            "observedSeconds": player.currentTime().seconds, "preparedCancelPreservedReceipt": true]
        try driver.record("native exact performance alignment", fields: result)
        return result
    }

    private static func pointer(shotID: String, root: URL) async throws -> Data? {
        try await Task.detached { () throws -> Data? in
            let path = PipelineProductionPerformanceAlignment.currentPath(shotID)
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else { return nil }
            return try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: root))
        }.value
    }

    private static func requireBlocked(_ shotID: String, context: ProductionPlanningAcceptanceFixture.Context,
                                       driver: ProductionVisualSourcesDriver) async throws {
        let root = context.dataRoot
        let stale = try await Task.detached {
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
            do { _ = try PipelineProductionPerformanceAlignment.requireCurrent(shotID: shotID, projection: projection, dataRoot: root); return false }
            catch { return true }
        }.value
        let assembly = try await PipelineProductionAssemblyController.capture(editor: context.editor)
        guard stale, assembly.state == .blocked else { throw failed("A changed native take/range retained stale alignment or assembly authority.") }
        try await driver.wait("stale alignment visible in the owner surface", seconds: 30) {
            driver.state("performance.alignment.status." + shotID, in: driver.window) == false
                && driver.text("production.assembly.state", in: driver.window) == "blocked"
        }
        try driver.capture("alignment-stale-selection-" + UUID().uuidString, target: driver.window)
    }

    private static func select(whole: Bool, takeID: String, rangeID: String, shotID: String,
                               context: ProductionPlanningAcceptanceFixture.Context, driver: ProductionVisualSourcesDriver) async throws {
        let root = context.dataRoot, window = driver.window
        try await driver.click("take.open", in: window)
        let sheet = try await driver.sheet("take.picker")
        try await driver.picker("take.picker", title: try await ProductionV2TakeAcceptance.pickerTitle(takeID: takeID, context: context), expected: takeID, in: sheet)
        try await driver.wait("previously reviewed actual take loaded") { driver.state("take.use", in: sheet) == true }
        if whole { try await driver.click("take.use", in: sheet) }
        else {
            try await ProductionNativeDisclosureAcceptance.toggle("take.range.open", content: "take.range.start", expanded: true, driver: driver, in: sheet)
            try await driver.click("take.range.use." + rangeID, in: sheet)
        }
        try await driver.wait("explicit native performance selection changed", seconds: 30) {
            guard let selected = try? PipelineProductionRenderWriter.requireSelected(shotID: shotID, dataRoot: root) else { return false }
            return selected.selection.takeID == takeID && selected.selection.nativeRange?.id == (whole ? nil : rangeID)
        }
        try await driver.click("take.close", in: sheet)
        try await driver.wait("take selection sheet closed") { window.attachedSheet == nil && window.isKeyWindow }
    }

    nonisolated private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native performance alignment: " + message) }
}
