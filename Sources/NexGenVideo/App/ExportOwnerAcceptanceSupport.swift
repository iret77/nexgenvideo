import AppKit
import AVFoundation
import CryptoKit
import NexGenEngine

@MainActor
enum ExportOwnerAcceptanceSupport {
    struct Context {
        let document: VideoProject
        let window: NSWindow
        let directory: URL
        let package: URL
        let driver: ProductionVisualSourcesDriver
        var editor: EditorViewModel { document.editorViewModel }
    }

    static func make(directory: URL, scale: Double, seconds: Double = 2, portrait: Bool = true,
                     name: String = "export-owner") async throws -> Context {
        let package = directory.appendingPathComponent("Export source.ngv", isDirectory: true)
        let media = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let video = media.appendingPathComponent("Moving source.mov"), audio = directory.appendingPathComponent("Original sound.wav")
        try await FullflowAcceptanceFixture.writeVideo(to: video, duration: seconds, fps: 24, warm: true)
        try FullflowAcceptanceFixture.writeTone(to: audio, duration: seconds)
        let assets = [MediaAsset(id: "export-picture", url: video, type: .video, name: "Moving source", duration: seconds),
                      MediaAsset(id: "export-sound", url: audio, type: .audio, name: "Original sound", duration: seconds)]
        for asset in assets { await asset.loadMetadata() }
        var timeline = Timeline(); timeline.width = portrait ? 180 : 320; timeline.height = portrait ? 320 : 180
        timeline.fps = 24; timeline.settingsConfigured = true
        let frames = Int((seconds * 24).rounded())
        timeline.tracks = [Track(type: .video, clips: [.init(id: "picture", mediaRef: assets[0].id, startFrame: 0, durationFrames: frames)]),
            Track(type: .audio, clips: [.init(id: "sound", mediaRef: assets[1].id, mediaType: .audio, sourceClipType: .audio, startFrame: 0, durationFrames: frames)])]
        var manifest = MediaManifest(); manifest.entries = assets.map { $0.toManifestEntry(projectURL: package) }
        try JSONEncoder().encode(timeline).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        _ = try ProjectIdentity.uuid(for: package)
        try JSONEncoder().encode(timeline).write(to: directory.appendingPathComponent("source-timeline.json"))
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("source-manifest.json"))
        return try await open(package: package, directory: directory, scale: scale, name: name)
    }

    static func open(package: URL, directory: URL, scale: Double, name: String) async throws -> Context {
        let document = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
        NSDocumentController.shared.addDocument(document); document.makeWindowControllers(); document.showWindows()
        NSApp.mainMenu = MainMenuBuilder.buildMenu()
        guard let window = document.windowControllers.first?.window else { document.close(); throw failed("The export document has no native window.") }
        window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let driver = ProductionVisualSourcesDriver(window: window, output: directory, name: name)
        try await driver.wait("actual export document") { window.isKeyWindow && window.contentView?.bounds.size == AppTheme.Window.projectMin }
        guard AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale else {
            document.close(); throw failed("The actual export interface scale differs from the requested scale.")
        }
        return Context(document: document, window: window, directory: directory, package: package, driver: driver)
    }

    static func workspace(_ context: Context) async throws {
        try await NativeEditingOwnerAcceptance.workspace(.export, editor: context.editor, window: context.window, driver: context.driver)
        try await context.driver.wait("actual export settings") { context.driver.text("export.mode", in: context.window) != nil }
    }

    static func select(_ id: String, title: String, expected: String? = nil, in window: NSWindow,
                       driver: ProductionVisualSourcesDriver) async throws {
        try await driver.menu(id, title: title, in: window)
        try await driver.wait("exact export selection " + id) { driver.text(id, in: window) == (expected ?? title) }
    }

    static func start(_ destination: URL, context: Context, in window: NSWindow? = nil) async throws -> ExportJob {
        let target = window ?? context.window, queue = ExportQueue.shared
        let before = Set(queue.jobs(ownerKey: context.editor.openWorkingCopyKey).map(\.id))
        try await context.driver.click("export.start", in: target)
        try await context.driver.saveFile(destination, in: target)
        try await context.driver.wait("actual export job registration", seconds: 45) {
            queue.jobs(ownerKey: context.editor.openWorkingCopyKey).contains { !before.contains($0.id) }
        }
        let added = queue.jobs(ownerKey: context.editor.openWorkingCopyKey).filter { !before.contains($0.id) }
        guard added.count == 1, let job = added.first else { throw failed("One native export action did not create exactly one job.") }
        return job
    }

    static func complete(_ job: ExportJob, context: Context) async throws {
        try await context.driver.wait("actual export completes: " + job.title, seconds: 120) { job.status.isTerminal }
        guard job.status == .completed, let url = job.destinationURL,
              FileManager.default.fileExists(atPath: url.path) else { throw failed(job.failure ?? "Export did not complete.") }
        try await context.driver.click("export.history." + job.id, in: context.window)
        if job.kind == .video {
            try await context.driver.wait("actual file QC") { context.driver.text("export.qc", in: context.window) == "passed" }
            try await context.driver.reveal("export.qc", in: context.window)
        }
    }

    static func save(_ context: Context) async throws {
        try context.driver.pressKey(1, characters: "s", modifiers: .command, in: context.window)
        try await context.driver.wait("native export project save", seconds: 30) { !context.document.isDocumentEdited }
        let saved = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: context.package.appendingPathComponent(Project.timelineFilename)))
        guard saved == context.editor.timeline else { throw failed("Native Save did not persist the export source timeline.") }
    }

    static func recordJob(_ job: ExportJob, context: Context, name: String) throws {
        var row: [String: Any] = ["id": job.id, "status": job.status.rawValue, "kind": job.kind.rawValue,
            "progress": job.progress, "warnings": job.warnings, "failure": job.failure as Any? ?? NSNull(),
            "outputSHA256": job.outputSHA256 as Any? ?? NSNull(), "output": job.destinationURL?.lastPathComponent as Any? ?? NSNull()]
        if let report = job.fcpxmlReport { row["fcpxml"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) }
        if let report = job.projectReport {
            row["package"] = ["collected": report.collected, "copiedInternal": report.copiedInternal,
                "missing": report.missing.map { ["id": $0.id, "name": $0.name] }, "bytes": report.totalBytes]
        }
        if job.kind == .video, let home = context.editor.workingRoot {
            let root = try ExportDataRoot.resolve(in: home)
            let attempt = try PipelineDeliveryStore.loadAttempt(id: job.id, dataRoot: root)
            row["attempt"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt))
        }
        try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .prettyPrinted])
            .write(to: context.directory.appendingPathComponent(name + "-job.json"), options: .atomic)
    }

    struct Probe: Codable, Sendable {
        struct Frame: Codable, Sendable {
            let value: Int64; let timescale: Int32; let width: Int; let height: Int
            let pixelSHA256: String; let centerLine: [UInt8]
        }
        let filename: String; let sha256: String; let codec: String; let width: Int; let height: Int
        let fps: Float; let duration: Double; let frames: [Frame]; let audioStart: Double
        let audioSamples: Int; let audioFile: String; let audioSHA256: String
    }

    nonisolated static func decode(_ url: URL, evidence: URL) async throws -> Probe {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let sound = try await asset.loadTracks(withMediaType: .audio).first,
              let format = try await video.load(.formatDescriptions).first else { throw failed("The actual export lost picture or sound.") }
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        let codec = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: subtype >> $0) }, encoding: .ascii) ?? "unknown"
        let size = CMVideoFormatDescriptionGetDimensions(format), fps = try await video.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); guard reader.startReading() else { throw reader.error ?? failed("The movie is not decodable.") }
        var frames: [Probe.Frame] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { throw failed("A decoded frame has no pixels.") }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            do {
                guard let base = CVPixelBufferGetBaseAddress(pixels) else { throw failed("Decoded pixels are unreadable.") }
                let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels), stride = CVPixelBufferGetBytesPerRow(pixels)
                var digest = SHA256(), line: [UInt8] = []
                for y in 0..<height { digest.update(data: Data(bytes: base.advanced(by: y * stride), count: width * 4)) }
                let row = base.advanced(by: (height / 2) * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<320 {
                    let column = min(width - 1, Int((Double(x) + 0.5) * Double(width) / 320))
                    line.append(contentsOf: [row[column * 4], row[column * 4 + 1], row[column * 4 + 2]])
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                frames.append(.init(value: time.value, timescale: time.timescale, width: width, height: height,
                    pixelSHA256: digest.finalize().map { String(format: "%02x", $0) }.joined(), centerLine: line))
            } catch { CVPixelBufferUnlockBaseAddress(pixels, .readOnly); throw error }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        guard reader.status == .completed, !frames.isEmpty else { throw reader.error ?? failed("The complete movie could not be decoded.") }
        let audio = try await pcm(asset: asset, track: sound)
        let audioURL = evidence.appendingPathExtension("f32")
        try audio.data.write(to: audioURL)
        let probe = Probe(filename: url.lastPathComponent, sha256: try FileDigest.sha256(of: url), codec: codec,
            width: Int(size.width), height: Int(size.height), fps: fps, duration: duration, frames: frames,
            audioStart: audio.start, audioSamples: audio.data.count / 4, audioFile: audioURL.lastPathComponent,
            audioSHA256: FileDigest.sha256(of: audio.data))
        try JSONEncoder().encode(probe).write(to: evidence.appendingPathExtension("json"))
        return probe
    }

    nonisolated static func pcm(asset: AVAsset, track: AVAssetTrack) async throws -> (data: Data, start: Double) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); guard reader.startReading() else { throw reader.error ?? failed("Exported audio cannot be decoded.") }
        var bytes = Data(), start: Double?
        while let sample = output.copyNextSampleBuffer() {
            if start == nil { start = CMSampleBufferGetPresentationTimeStamp(sample).seconds }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw failed("Decoded audio has no PCM bytes.") }
            let length = CMBlockBufferGetDataLength(block)
            if length == 0 { continue }
            var part = Data(count: length)
            let status = part.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw failed("PCM bytes cannot be read.") }; bytes.append(part)
        }
        guard reader.status == .completed, let start, !bytes.isEmpty else { throw reader.error ?? failed("Exported sound is incomplete.") }
        return (bytes, start)
    }

    nonisolated static func failed(_ message: String) -> GateBlocked { GateBlocked("Native export: " + message) }
}
