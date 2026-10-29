import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import NexGenEngine
import UniformTypeIdentifiers

@MainActor
enum ProductionAnimatedStillOwnerAcceptance {
    static func run(output: URL) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested else { throw GateBlocked("Animated-still acceptance requires its isolated native process.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let generation = try ProductionV2GenerationAcceptance()
        defer { generation.close() }
        let runtime = ProductionV2RecordingRuntime()
        let original = try await ProductionPlanningAcceptanceFixture.makeScript(agentService: runtime.service())
        let editor = original.editor
        generation.configure(editor: editor)
        let context = ProductionPlanningAcceptanceFixture.Context(document: original.document, packageURL: original.packageURL,
            dataRoot: original.dataRoot, executor: generation.executor(editor: editor))
        defer { editor.agentService.cancel(); context.document.close() }
        NSDocumentController.shared.addDocument(context.document)
        if context.document.windowControllers.isEmpty { context.document.makeWindowControllers() }
        guard let window = context.document.windowControllers.compactMap({ $0 as? EditorWindowController }).first?.window else {
            throw GateBlocked("The animated-still document has no actual editor window.")
        }
        window.setContentSize(AppTheme.Window.projectMin)
        context.document.showWindows(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "animated-still-owner")
        do {
            await editor.refreshEngineState()
            guard editor.agentService.send(text: "Acceptance transport: retain this actual Core phase context.", mentions: [], hidden: true) else {
                throw GateBlocked("The actual recording runtime could not start its document session.")
            }
            try await driver.wait("animated-still recording context") { !editor.agentService.isStreaming && editor.agentService.currentSessionId != nil }
            try await driver.click("editor.workspace.production", in: window, enabled: false)
            let source = try await ProductionSourceModeFixture.makeMovingVideo()
            let image = try await ProductionSourceModeFixture.firstFramePNG(source: source)
            try image.write(to: output.appendingPathComponent("actual-provider-image.png"), options: .atomic)
            _ = try await ProductionV2PlanningAcceptance.run(context: context, sourceVideo: source, driver: driver,
                generatedFirstShot: true, sketchGeneration: generation)
            try await ProductionV2PreRenderAcceptance.references(context: context, driver: driver)
            let proposed = try await generation.proposal(context: context)
            _ = try await ProductionPlanningAcceptanceFixture.promoteImported(in: context, generatedShots: [proposed])
            let projection = try await ProductionSourceModesOwnerAcceptance.selectAnimatedStill(context: context, driver: driver)
            guard let shot = projection.shots.first, projection.requiredFrameRoles(for: shot.id) == ["start"],
                  projection.shots.dropFirst().allSatisfy({ $0.sourceMode == .imported }) else {
                throw GateBlocked("The native delivery choice does not require exactly one actual start image.")
            }
            try await ProductionV2PlanningAcceptance.approve("shotlist", artifact: ProductionPlanProjectionV1.versionPath(projection.header.revision),
                next: "sanity", context: context, driver: driver)
            try await ProductionPlanningAcceptanceFixture.prepareImportedSanity(in: context)
            try await ProductionV2PlanningAcceptance.selectPhase("sanity", context: context, driver: driver)
            try await ProductionV2PlanningAcceptance.approve("sanity", artifact: PipelineLayout.sanityReportFile,
                next: "frames", context: context, driver: driver)
            try await ProductionPlanningAcceptanceFixture.run("run_phase", args: ["phase": "frames"], in: context)
            try await ProductionV2PlanningAcceptance.selectPhase("frames", context: context, driver: driver)
            let candidate = try await ProductionFramesOwnerAcceptance.generate(shotID: shot.id, role: "start", image: image,
                context: context, generation: generation, driver: driver)
            try await ProductionFramesOwnerAcceptance.select(candidate, context: context, driver: driver)
            try await ProductionFramesOwnerAcceptance.audit(candidate, context: context, driver: driver)
            let root = context.dataRoot
            let frames = try await Task.detached {
                let manifest = try ProductionPlanFramesV1.requireCurrent(projection: projection, dataRoot: root)
                try PipelineProductionFramesWriter.requireCurrent(projection: projection, dataRoot: root)
                return manifest
            }.value
            guard frames.shots.count == 1, frames.shots.first?.shotId == shot.id,
                  frames.shots.first?.frames.map(\.role) == ["start"] else {
                throw GateBlocked("Animated-still delivery created unrelated final-video boundary images.")
            }
            try await ProductionV2PlanningAcceptance.approve("frames", artifact: PipelineLayout.framesManifestFile,
                next: "render_review", context: context, driver: driver)
            try await ProductionV2PreRenderAcceptance.reviewCurrentInputs(context: context, driver: driver)
            let beforeRenderSpend = editor.generationLog.spendEvents
            try await ProductionPlanningAcceptanceFixture.run("next_render_shot", args: ["phase": "final"], in: context)
            try await ProductionPlanningAcceptanceFixture.run("record_render", args: ["phase": "final", "shot_id": shot.id], in: context)
            let delivery = try await ProductionV2FilmAcceptance.run(context: context, driver: driver, output: output, requiresReviewedTake: false)
            guard editor.generationLog.spendEvents == beforeRenderSpend,
                  let movie = delivery["movie"] as? String, URL(fileURLWithPath: movie).lastPathComponent == movie else {
                throw GateBlocked("Animated-still final delivery submitted another provider generation or lost the actual movie.")
            }
            let proof = try await Task.detached { try PipelineProductionAssemblyWriter.requireCurrent(dataRoot: root) }.value
            guard let placement = proof.placements.first(where: { $0.shotID == shot.id }), placement.sourceKind == .stillImage,
                  placement.takeID == nil, placement.output.sha256 == candidate.candidate.usage.outputSHA256,
                  let clip = editor.timeline.tracks.flatMap(\.clips).first(where: { $0.id == placement.clipID }),
                  let scale = clip.scaleTrack, scale.keyframes.count == 2,
                  scale.keyframes.first?.frame == 0, scale.keyframes.last?.frame == clip.durationFrames - 1,
                  let first = scale.keyframes.first?.value, let last = scale.keyframes.last?.value,
                  abs(last.a / first.a - 1.08) < 0.000_001, abs(last.b / first.b - 1.08) < 0.000_001 else {
                throw GateBlocked("The actual still placement lost its exact selected image, zoom track or no-Take delivery contract.")
            }
            let motion = try await measureMotion(movie: output.appendingPathComponent(movie), clip: clip,
                fps: editor.timeline.fps, output: output)
            let files = try await Task.detached {
                try exportEvidence(root: root, shotID: shot.id, candidate: candidate, projection: projection, output: output)
            }.value
            try driver.record("actual animated still exported", fields: motion)
            let result: [String: Any] = ["schema": "animated-still-owner-acceptance/v1", "shotID": shot.id,
                "projectionRevision": projection.header.revision, "actualImageSHA256": candidate.candidate.usage.outputSHA256,
                "candidateID": candidate.id, "frameRoles": ["start"], "finalVideoRoute": false,
                "finalProviderGenerations": 0, "finalSpendEventsUnchanged": true, "actualTake": false,
                "timelineClipID": clip.id, "timelineFrames": clip.durationFrames, "fps": editor.timeline.fps,
                "keyframeStartScale": [first.a, first.b], "keyframeEndScale": [last.a, last.b],
                "motion": motion, "delivery": delivery, "files": files, "nativeEvidence": driver.result(),
                "provider": "isolated real image HTTP adapter; native timeline animation; no final-video request",
                "liveProvider": false, "imageQualityClaim": false, "offGridSongEndClaim": false]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("animated-still-result.json"), options: .atomic)
            return result
        } catch { driver.failure(error); throw error }
    }

    nonisolated private static func exportEvidence(root: URL, shotID: String,
        candidate: PipelineProductionFrameCandidates.Item, projection: ProductionPlanProjectionV1, output: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        let paths = [
            (ProductionPlanProjectionV1.versionPath(projection.header.revision), "actual-projection.v5.yaml"),
            (ShotPlanningPromotionV1.versionPath(projection.header.revision), "actual-promotion.json"),
            (PipelineLayout.framesManifestFile, "actual-frames.yaml"),
            (PipelineProductionFramesWriter.receiptPath(shotID: shotID, role: "start"), "actual-frame-receipt.json"),
            (PipelineProductionRenderWriter.stillPath(shotID), "actual-still-delivery.json"),
            (ProductionPlanAssemblyProofV1.relativePath, "actual-assembly.json"),
            (candidate.candidate.receipt.generation.package.path, "actual-image-package.json"),
            (GenerationOutputReceipt.path(assetID: candidate.candidate.receipt.generation.assetID), "actual-image-output.json"),
            (candidate.candidate.receipt.frame.path, "actual-selected-frame.png"),
            ("frames/\(shotID)-start.audit.yaml", "actual-frame-audit.yaml"),
            ("frames/\(shotID)-start.acceptance.json", "actual-frame-acceptance.json")]
        for (path, name) in paths {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: root))
            try bytes.write(to: output.appendingPathComponent(name), options: .atomic)
            files[name] = FileDigest.sha256(of: bytes)
        }
        guard let audit = try loadFrameAudit(dataRoot: root, shotId: shotID, role: "start") else { throw GateBlocked("The selected still has no actual saved frame audit.") }
        let auditBytes = try PlanningWriterIO.json(audit)
        try auditBytes.write(to: output.appendingPathComponent("actual-frame-audit.json"), options: .atomic)
        files["actual-frame-audit.json"] = FileDigest.sha256(of: auditBytes)
        return files
    }

    private struct Bounds: Sendable {
        let minX: Int, minY: Int, maxX: Int, maxY: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var json: [Int] { [minX, minY, maxX, maxY] }
    }

    private struct Motion: Sendable {
        let firstFrame: Int, lastFrame: Int
        let first: Bounds, last: Bounds
        let digests: [String]
        let widthRatio: Double, heightRatio: Double
    }

    private static func measureMotion(movie: URL, clip: Clip, fps: Int, output: URL) async throws -> [String: Any] {
        let measured: Motion = try await Task.detached {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            var observations: [Bounds] = [], digests: [String] = []
            let frames = [clip.startFrame, clip.endFrame - 1]
            for (index, frame) in frames.enumerated() {
                let time = CMTime(value: Int64(frame), timescale: Int32(fps))
                let decoded = try await generator.image(at: time)
                guard CMTimeCompare(decoded.actualTime, time) == 0 else { throw GateBlocked("The exported motion observation decoded another actual frame.") }
                observations.append(try redBounds(decoded.image))
                let data = NSMutableData()
                guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
                CGImageDestinationAddImage(encoder, decoded.image, nil)
                guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
                let bytes = data as Data
                try bytes.write(to: output.appendingPathComponent(index == 0 ? "still-first-decoded.png" : "still-last-decoded.png"), options: .atomic)
                digests.append(FileDigest.sha256(of: bytes))
            }
            let first = observations[0], last = observations[1]
            let widthRatio = Double(last.width) / Double(first.width), heightRatio = Double(last.height) / Double(first.height)
            guard digests[0] != digests[1], widthRatio > 1.03, widthRatio < 1.13,
                  heightRatio > 1.03, heightRatio < 1.13 else { throw GateBlocked("The exported actual red shape does not visibly grow with its declared native zoom.") }
            return Motion(firstFrame: frames[0], lastFrame: frames[1], first: first, last: last,
                digests: digests, widthRatio: widthRatio, heightRatio: heightRatio)
        }.value
        return ["firstFrame": measured.firstFrame, "lastFrame": measured.lastFrame,
            "firstBounds": measured.first.json, "lastBounds": measured.last.json,
            "decodedPNGSHA256": measured.digests, "widthRatio": measured.widthRatio, "heightRatio": measured.heightRatio,
            "actualDecodedFrames": true, "pixelQualityClaim": false]
    }

    nonisolated private static func redBounds(_ image: CGImage) throws -> Bounds {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width < 10_000, height < 10_000 else { throw CocoaError(.fileReadCorruptFile) }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw CocoaError(.fileReadCorruptFile) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4, red = Int(bytes[index]), green = Int(bytes[index + 1]), blue = Int(bytes[index + 2])
                if red > 90, red > green * 2, red > blue * 2 {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { throw GateBlocked("The decoded actual film frame has no known red source shape.") }
        return .init(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }
}
