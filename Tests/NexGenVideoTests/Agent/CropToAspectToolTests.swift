import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NexGenVideo
import NexGenEngine

/// #199: the crop_to_aspect render-larger-then-crop invocation surface.
@MainActor
@Suite("crop_to_aspect tool")
struct CropToAspectToolTests {
    private func scaffold() throws -> (ToolHarness, URL, URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("crop-\(UUID().uuidString)", isDirectory: true)
        let home = tmp.appendingPathComponent("proj", isDirectory: true)
        _ = try ProjectScaffold.initProject(home: home, name: "demo", mode: .beat)
        try Fixtures.prepareProjectPackage(at: home)
        let harness = ToolHarness()
        harness.editor.projectURL = home
        let dataRoot = try #require(
            harness.editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
        )
        let productionPlan = try ShotProductionPlan(
            primaryAction: "The cyclist holds the starting pose.",
            cameraMovement: .static,
            renderability: .green,
            continuityLocks: ["The red bicycle remains screen-left."]
        )
        let shot = try Shot(
            id: "s001",
            section: "verse",
            timeStart: 0,
            timeEnd: 4,
            durationS: 4,
            type: .performance,
            description: "Cyclist at the start line",
            visualPrompt: "A cyclist crouches at the start line.",
            mood: "focused",
            productionPlan: productionPlan
        )
        let song = try Song(
            title: "t",
            audioPath: "a.wav",
            analysisPath: "an.json",
            bpm: 120,
            durationS: 4
        )
        _ = try saveShotlist(
            try Shotlist(
                schema_: shotlistSchemaVersion,
                mode: .section,
                project: "demo",
                song: song,
                generated: "2026-08-10",
                generator: "test",
                shots: [shot]
            ),
            to: dataRoot
        )
        return (harness, dataRoot, tmp)
    }

    private func writePNG(_ w: Int, _ h: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    @Test("crops a 2000x1000 master to 16:9 with exact centered geometry")
    func crop16x9() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let home = FrameInventory.projectHome(of: dataRoot)
        let master = home.appendingPathComponent("media/master.png")
        try writePNG(2000, 1000, to: master)
        let shot = try #require(
            try loadShotlist(dataRoot: dataRoot)?.shots.first { $0.id == "s001" }
        )
        var sourceInput = GenerationInput(
            prompt: "A cyclist crouches at the start line. "
                + "Continuity lock: The red bicycle remains screen-left.",
            model: "image-model",
            duration: 0,
            aspectRatio: "2:1"
        )
        sourceInput.intent = shot.visualPrompt
        sourceInput.promptShotId = shot.id
        sourceInput.promptProjectKey = h.editor.projectId ?? dataRoot
            .standardizedFileURL.resolvingSymlinksInPath().path
        sourceInput.promptShotFingerprint = try PromptCompiler.shotFingerprint(shot)
        h.editor.mediaAssets.append(
            MediaAsset(
                id: "master",
                url: master,
                type: .image,
                name: "master",
                generationInput: sourceInput
            )
        )

        let res = try await h.runOK("crop_to_aspect", args: [
            "project_dir": dataRoot.path,
            "aspect": "16:9",
            "path": master.path,
            "shot_id": "s001",
        ]) as? [String: Any]

        // 2000x1000 (aspect 2.0) wider than 16:9 → full height 1000, width = round(1000*16/9)=1778, centered.
        let size = try #require(res?["target_size"] as? [String: Any])
        #expect(size["width"] as? Int == 1778)
        #expect(size["height"] as? Int == 1000)
        let box = try #require(res?["box"] as? [String: Any])
        #expect(box["left"] as? Int == 111)
        #expect(box["right"] as? Int == 1889)
        // The cropped file was written into the media library and its pixels match the plan.
        let outRel = try #require(res?["output"] as? String)
        let outURL = home.appendingPathComponent(outRel)
        #expect(FileManager.default.fileExists(atPath: outURL.path))
        #expect(FrameRasterizer.pixelSize(of: outURL).map { $0.width } == 1778)
        let assetId = try #require(res?["asset_id"] as? String)
        let asset = try #require(h.editor.mediaAssets.first { $0.id == assetId })
        let input = try #require(asset.generationInput)
        #expect(input == sourceInput)

        _ = try await h.runOK("record_render", args: [
            "project_dir": dataRoot.path,
            "phase": "frames",
            "shot_id": "s001",
            "role": "start",
            "output": assetId,
        ])
        let recorded = try #require(
            try loadFramesManifest(dataRoot: dataRoot).shot("s001")?
                .frames.first { $0.role == "start" }
        )
        #expect(recorded.runwayModel == sourceInput.model)
        #expect(recorded.providerPrompt == sourceInput.prompt)
    }

    @Test("an unknown source errors, not crashes")
    func missingSource() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let raw = await h.runRaw("crop_to_aspect", args: [
            "project_dir": dataRoot.path,
            "aspect": "16:9",
            "shot_id": "s001",
        ])
        #expect(raw.isError)
    }

    @Test("rejects an unbound bible master before creating a crop")
    func unboundMaster() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let home = FrameInventory.projectHome(of: dataRoot)
        let master = home.appendingPathComponent("media/bible-master.png")
        try writePNG(2000, 1000, to: master)

        let raw = await h.runRaw("crop_to_aspect", args: [
            "project_dir": dataRoot.path,
            "aspect": "16:9",
            "path": master.path,
            "shot_id": "s001",
        ])

        #expect(raw.isError)
        #expect(
            ToolHarness.textOf(raw).contains(
                "requires a current shot-bound generated image"
            )
        )
        let crop = home.appendingPathComponent("media/bible-master-crop-16x9.png")
        #expect(!FileManager.default.fileExists(atPath: crop.path))
    }
}
