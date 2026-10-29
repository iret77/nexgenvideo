import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum ManualVideoModesAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let name = "manual-video-modes-\(Int(scale * 100))"
        let directory = output.appendingPathComponent(name, isDirectory: true)
        let packageURL = directory.appendingPathComponent("Video modes.ngv", isDirectory: true)
        let media = packageURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try image(media.appendingPathComponent("first.png"), red: true)
        try image(media.appendingPathComponent("last.png"), red: false)
        let motion = try await ProductionSourceModeFixture.makeMovingVideo()
        defer { try? FileManager.default.removeItem(at: motion) }
        try FileManager.default.copyItem(at: motion, to: media.appendingPathComponent("motion.mov"))
        try FullflowAcceptanceFixture.writeTone(to: media.appendingPathComponent("timing.wav"), duration: 4)
        var assets: [MediaAsset] = []
        for (id, ext, type) in [("first", "png", ClipType.image), ("last", "png", .image), ("motion", "mov", .video), ("timing", "wav", .audio)] {
            let asset = MediaAsset(id: id, url: media.appendingPathComponent(id + "." + ext), type: type, name: id)
            await asset.loadMetadata(); assets.append(asset)
        }
        var timeline = Timeline(); timeline.width = 320; timeline.height = 180; timeline.fps = 30; timeline.settingsConfigured = true
        var manifest = MediaManifest(); manifest.entries = assets.map { $0.toManifestEntry(projectURL: packageURL) }
        try JSONEncoder().encode(timeline).write(to: packageURL.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(manifest).write(to: packageURL.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: packageURL.appendingPathComponent(Project.generationLogFilename))
        let defaultsName = name + "." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: defaultsName) else { throw GateBlocked("The video-mode defaults cannot be isolated.") }
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let catalog = ModelCatalog(); catalog.load(entries: ModelCatalog.launchEntries)
        let services = GenerationPanelServices(catalog: catalog, preferences: ModelPreferences(defaults: defaults),
            activation: { .init(active: [.init(provider: .fal, transport: .api)]) },
            quoteLoader: { _, _ in throw GenerationBackendError.transport("The isolated video adapter has no live price.") })
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ManualVideoModesHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ManualVideoModesHTTP.clear() }
        let document = try await VideoProject.load(from: packageURL, agentService: AgentService(refreshBackendStatusOnInit: false))
        let editor = document.editorViewModel
        editor.generationPanelServicesOverride = services
        editor.generationService.reconciliation = ProviderRunReconciliation(session: session,
            providerKey: { $0 == .fal ? "simulator-only-key" : nil }, falCharge: { _, _, _ in nil })
        NSDocumentController.shared.addDocument(document); document.makeWindowControllers(); document.showWindows()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The manual video window did not open.") }
        window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil)
        NSApp.mainMenu = MainMenuBuilder.buildMenu(); NSApp.activate(ignoringOtherApps: true)
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
        var closed = false
        defer { if !closed { document.close() } }
        let outputVideo = directory.appendingPathComponent("simulated-output.mov")
        try await FullflowAcceptanceFixture.writeVideo(to: outputVideo, duration: 4, fps: 30, warm: false)
        let outputBytes = try Data(contentsOf: outputVideo)
        let modelIDs = ["bytedance/seedance-2.5/text-to-video", "bytedance/seedance-2.5/image-to-video", "bytedance/seedance-2.5/reference-to-video"]
        func selectModel(_ index: Int) async throws {
            guard let model = catalog.video.first(where: { $0.id == modelIDs[index] }), services.target(model.id, sourceVideo: false).binding != nil else {
                throw GateBlocked("The existing Fal video adapter is absent from the isolated native catalog.")
            }
            try await driver.picker("generation.media.model", title: model.displayName, expected: model.id, in: window)
        }
        func durationFour() async throws {
            try await driver.click("generation.media.settings", in: window)
            let popup = try await popup(containing: "generation.media.option.Duration.4s", driver: driver)
            try await driver.click("generation.media.option.Duration.4s", in: popup, enabled: false)
            try driver.pressKey(53, characters: "\u{1b}", in: popup)
            try await driver.wait("video settings close") { window.isKeyWindow }
        }
        func pick(_ id: String, slot: String) async throws {
            try await driver.click("generation.media.pick." + slot, in: window)
            let popup = try await popup(containing: "library.pick." + id, driver: driver)
            try await driver.click("library.pick." + id, in: popup)
            try await driver.wait("native video reference assignment") {
                window.isKeyWindow && (slot == "References"
                    ? driver.text("generation.media.reference." + id, in: window) != nil
                    : driver.text("generation.media.slot." + slot, in: window) == id)
            }
        }
        func prepare(_ label: String) async throws -> GenerationPackageV1 {
            let count = ManualVideoModesHTTP.snapshot.requests.count
            try await driver.click("generation.media.review", in: window)
            try await driver.wait("native video review " + label) { driver.state("generation.media.approve", in: window) == true }
            try await driver.click("generation.media.package.details", in: window)
            try await driver.click("generation.media.package.copy-package", in: window)
            guard let text = NSPasteboard.general.string(forType: .string) else { throw GateBlocked("The reviewed video package was not copied.") }
            let package = try JSONDecoder().decode(GenerationPackageV1.self, from: Data(text.utf8))
            try package.validate()
            guard package.payload.modality == "video", package.payload.destination.kind == "media_library",
                  package.payload.generationInput.duration == 4, package.payload.generationInput.videoDuration == .seconds(4),
                  ManualVideoModesHTTP.snapshot.requests.count == count, editor.timeline == timeline else {
                throw GateBlocked("Video preparation dispatched, modified the film or lost the selected duration.")
            }
            try driver.capture(label + "-review", target: window)
            return package
        }
        func submit(_ package: GenerationPackageV1, label: String) async throws -> [String: Any] {
            ManualVideoModesHTTP.install(endpoint: package.payload.target.endpoint, output: outputBytes)
            try await driver.click("generation.media.approve", in: window)
            try await driver.wait("actual manual video completion " + label, seconds: 60) {
                editor.mediaAssets.contains { $0.generationInput?.generationPackageID == package.id && $0.generationStatus == .none }
            }
            guard let asset = editor.mediaAssets.first(where: { $0.generationInput?.generationPackageID == package.id && $0.generationStatus == .none }) else {
                throw GateBlocked("The approved video did not reach its library destination.")
            }
            let observed = ManualVideoModesHTTP.snapshot
            let submits = observed.requests.filter { $0.method == "POST" && $0.url.hasPrefix("https://queue.fal.run/") }
            guard submits.count == 1, let actual = submits.first,
                  let request = try JSONSerialization.jsonObject(with: actual.body) as? [String: Any],
                  request["prompt"] as? String == package.payload.prompt, request["duration"] as? String == "4",
                  observed.unexpected.isEmpty, observed.uploads.count == package.payload.references.count,
                  try FileDigest.sha256(of: asset.url) == FileDigest.sha256(of: outputBytes), editor.timeline == timeline else {
                throw GateBlocked("The manual video transport did not receive exactly the reviewed request.")
            }
            var uploads: [[String: String]] = []
            for (index, reference) in package.payload.references.enumerated() {
                let matches = observed.uploads.filter { FileDigest.sha256(of: $0.value) == reference.submittedSHA256 }
                guard matches.count == 1, let match = matches.first else { throw GateBlocked("A reviewed reference was omitted, replaced or ambiguously uploaded.") }
                let filename = label + "-input-\(index).bin"
                try match.value.write(to: directory.appendingPathComponent(filename))
                uploads.append(["assetID": reference.assetID, "url": match.key, "file": filename,
                    "sha256": reference.submittedSHA256, "sourceSHA256": reference.sourceSHA256])
            }
            let decoded = try await decode(asset.url)
            let artifacts = try ManualGenerationArtifacts.save(name: label, package: package, submit: actual.body,
                output: Data(contentsOf: asset.url), directory: directory)
            try driver.record("manual video transport", fields: ["kind": label, "packageID": package.id,
                "assetID": asset.id, "uploads": uploads, "decodedFrames": decoded, "liveProvider": false])
            return ["kind": label, "assetID": asset.id, "packageID": package.id, "artifacts": artifacts,
                "uploads": uploads, "decodedFrames": decoded]
        }
        do {
            try await NativeEditingOwnerAcceptance.workspace(.media, editor: editor, window: window, driver: driver)
            try await driver.click("media.action.Generate", in: window)
            try await driver.wait("actual video viewport and interface scale") {
                window.contentView?.bounds.size == AppTheme.Window.projectMin
                    && AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale
            }
            let bounds = window.contentView!.bounds
            try await driver.wait("manual video panel") { driver.state("generation.media.type.Video", in: window) != nil }
            try await driver.click("generation.media.type.Video", in: window, enabled: false)
            try await selectModel(0); try await durationFour()
            try await driver.fill("generation.media.intent", value: "A blue wall with one white shape moving slowly to the right.", in: window)
            let free = try await prepare("free")
            guard free.payload.references.isEmpty, free.payload.target.modelId == modelIDs[0] else { throw GateBlocked("Free video generation has unexpected source inputs.") }
            var results = [try await submit(free, label: "free")]
            try await selectModel(1); try await durationFour()
            try await driver.fill("generation.media.intent", value: "Move from the red opening frame to the blue closing frame.", in: window)
            try await driver.wait("missing first frame cannot be submitted") { driver.state("generation.media.review", in: window) == false }
            try await pick("first", slot: "First Frame"); try await pick("last", slot: "Last Frame")
            let frames = try await prepare("frames")
            guard frames.payload.generationInput.startFrameAssetId == "first", frames.payload.generationInput.endFrameAssetId == "last",
                  Set(frames.payload.references.map(\.assetID)) == ["first", "last"], frames.payload.references.count == 2 else {
                throw GateBlocked("First and Last Frame did not bind both exact selected images.")
            }
            results.append(try await submit(frames, label: "frames"))
            try await selectModel(2); try await durationFour()
            guard driver.text("generation.media.slot.First Frame", in: window) == nil,
                  driver.text("generation.media.slot.Last Frame", in: window) == nil else { throw GateBlocked("The reference model retained incompatible frame slots.") }
            try await pick("first", slot: "References"); try await pick("motion", slot: "References"); try await pick("timing", slot: "References")
            for (id, tag) in [("first", "@Image1"), ("motion", "@Video1"), ("timing", "@Audio1")] {
                guard driver.text("generation.media.reference." + id, in: window) == tag else { throw GateBlocked("The visible reference tag does not identify its exact source.") }
            }
            try await driver.fill("generation.media.intent", value: "Use @Image1 for the scene, @Video1 for movement and @Audio1 for timing.", in: window)
            try await driver.click("generation.media.reference.remove.motion", in: window)
            try await driver.wait("native reference removal") { driver.text("generation.media.reference.motion", in: window) == nil }
            try await pick("motion", slot: "References")
            let references = try await prepare("references")
            guard references.payload.generationInput.startFrameAssetId == nil, references.payload.generationInput.endFrameAssetId == nil,
                  references.payload.generationInput.referenceImageAssetIds == ["first"],
                  references.payload.generationInput.referenceVideoAssetIds == ["motion"],
                  references.payload.generationInput.referenceAudioAssetIds == ["timing"], references.payload.references.count == 3 else {
                throw GateBlocked("The multimodal request retained a frame or lost an assigned reference.")
            }
            results.append(try await submit(references, label: "references"))
            try await pick("first", slot: "References"); try await pick("motion", slot: "References"); try await pick("timing", slot: "References")
            try await selectModel(0)
            try await driver.wait("model switch clears incompatible references visibly") {
                driver.text("generation.media.reference.first", in: window) == nil
                    && driver.text("generation.media.reference.motion", in: window) == nil
                    && driver.text("generation.media.reference.timing", in: window) == nil
                    && driver.text("generation.media.error", in: window)?.contains("Reference slots were cleared") == true
            }
            try driver.capture("model-reset", target: window)
            try await driver.fill("generation.media.intent", value: "A quiet empty blue scene.", in: window)
            let cleared = try await prepare("cleared")
            guard cleared.payload.references.isEmpty else { throw GateBlocked("Cleared references remained hidden in the next package.") }
            try await driver.click("generation.media.discard", in: window)
            try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
            try await driver.wait("manual videos saved", seconds: 30) { !document.isDocumentEdited }
            document.close(); closed = true
            let reopened = try await VideoProject.load(from: packageURL, agentService: AgentService(refreshBackendStatusOnInit: false))
            NSDocumentController.shared.addDocument(reopened); reopened.makeWindowControllers()
            defer { reopened.close() }
            guard reopened.editorViewModel.timeline == timeline else { throw GateBlocked("Free generation changed the saved timeline.") }
            for result in results {
                guard let id = result["assetID"] as? String,
                      let asset = reopened.editorViewModel.mediaAssets.first(where: { $0.id == id }),
                      asset.generationInput?.generationPackageID == result["packageID"] as? String,
                      try FileDigest.sha256(of: asset.url) == FileDigest.sha256(of: outputBytes) else {
                    throw GateBlocked("A manually generated video or its reviewed request did not survive reopening.")
                }
            }
            try driver.record("native videos saved and reopened", fields: ["packageIDs": results.compactMap { $0["packageID"] as? String },
                "timelineSHA256": FileDigest.sha256(of: try JSONEncoder().encode(reopened.editorViewModel.timeline))])
            return ["directory": name, "progress": name + ".json", "project": "Video modes.ngv", "viewport": [bounds.width, bounds.height],
                "effectiveScale": scale, "liveProvider": false, "results": results,
                "interactions": driver.interactions, "screenshots": driver.screenshots]
        } catch { driver.failure(error); throw error }
    }

    private static func popup(containing id: String, driver: ProductionVisualSourcesDriver) async throws -> NSWindow {
        try await driver.wait("video popup " + id) { NSApp.windows.contains { $0.isVisible && WorkspaceUIAcceptance.probeFrame(identifier: id, in: $0) != nil } }
        guard let window = NSApp.windows.first(where: { $0.isVisible && WorkspaceUIAcceptance.probeFrame(identifier: id, in: $0) != nil }),
              window.isKeyWindow else { throw GateBlocked("The actual video popup did not take focus.") }
        return window
    }

    private static func image(_ url: URL, red: Bool) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw GateBlocked("The exact frame fixture cannot be allocated.")
        }
        for y in 0..<180 { for x in 0..<320 { bitmap.setColor(red ? .red : .blue, atX: x, y: y) } }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw GateBlocked("The frame fixture cannot be encoded.") }
        try data.write(to: url)
    }

    private static func decode(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw GateBlocked("The generated video has no decodable track.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw GateBlocked("The generated video cannot be decoded.") }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetImageBuffer(sample) != nil else { throw GateBlocked("A generated video frame has no image.") }
            count += 1
        }
        let duration = try await asset.load(.duration).seconds
        guard reader.status == .completed, count == 120, abs(duration - 4) < 0.01 else { throw GateBlocked("The generated video did not decode to the requested four seconds.") }
        return count
    }
}
