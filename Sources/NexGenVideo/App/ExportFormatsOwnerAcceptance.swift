import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum ExportFormatsOwnerAcceptance {
    private typealias Support = ExportOwnerAcceptanceSupport

    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let directory = output.appendingPathComponent("export-formats-\(Int(scale * 100))", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw Support.failed("Export evidence requires a fresh directory.") }
        let context = try await Support.make(directory: directory, scale: scale)
        defer { context.document.close() }
        let driver = context.driver, window = context.window, editor = context.editor
        do {
            try await Support.workspace(context)
            let bounds = window.contentView!.bounds
            let timeline = editor.timeline
            guard editor.declaredPluginBinding == nil, !editor.hasProductionPipeline, timeline.fps == 24,
                  timeline.width == 180, timeline.height == 320, timeline.totalFrames == 48 else { throw Support.failed("The plain portrait export fixture changed.") }
            try await driver.reveal("export.require-sequence", in: window)
            guard driver.state("export.require-sequence", in: window) == false else { throw Support.failed("Plain editing unexpectedly requires production review.") }
            try await driver.click("export.require-sequence", in: window, enabled: false)
            try await driver.wait("explicit review requirement selected") { driver.state("export.require-sequence", in: window) == true }
            let rejectedURL = directory.appendingPathComponent("Review required.mp4")
            let existingJobs = Set(ExportQueue.shared.jobs(ownerKey: editor.openWorkingCopyKey).map(\.id))
            try await driver.click("export.start", in: window)
            try await driver.saveFile(rejectedURL, in: window)
            try await driver.wait("unreviewed generic export refused") { driver.text("export.error", in: window) != nil }
            guard !FileManager.default.fileExists(atPath: rejectedURL.path),
                  Set(ExportQueue.shared.jobs(ownerKey: editor.openWorkingCopyKey).map(\.id)) == existingJobs else { throw Support.failed("The required-review export published or enqueued an unreviewed film.") }
            try await driver.reveal("export.error", in: window); try driver.capture("review-required-refusal", target: window)
            try driver.record("explicit review requirement blocks publication", fields: ["error": driver.text("export.error", in: window) ?? "",
                "outputExists": false, "jobCount": existingJobs.count])
            try await driver.click("export.require-sequence", in: window, enabled: false)
            try await driver.wait("plain editing review option disabled") { driver.state("export.require-sequence", in: window) == false }

            let variants: [(String, VideoCodec, ExportResolution, String, Int, Int)] = [
                ("h264-720", .h264, .r720p, "master", 720, 1280),
                ("hevc-1080", .h265, .r1080p, "derivative", 1080, 1920),
                ("prores-original", .prores, .matchTimeline, "master", 180, 320),
                ("h264-2k", .h264, .r1440p, "derivative", 1440, 2560),
                ("hevc-4k", .h265, .r4k, "master", 2160, 3840)]
            var deliveries: [[String: Any]] = []
            for (index, variant) in variants.enumerated() {
                let (name, codec, resolution, target, width, height) = variant
                let settings: NSWindow
                if index == 0 {
                    try await AppNativeMenuAcceptance.choose(["File", "Export…"], in: window, driver: driver)
                    settings = try await driver.sheet("export.mode")
                } else { settings = window }
                try await Support.select("export.codec", title: codec.rawValue, in: settings, driver: driver)
                try await Support.select("export.resolution", title: resolution.rawValue, in: settings, driver: driver)
                try await Support.select("export.target", title: target == "master" ? "Master" : "Derivative", expected: target, in: settings, driver: driver)
                try await driver.reveal("export.start", in: settings); try driver.capture(name + "-settings", target: settings)
                let destination = directory.appendingPathComponent(name).appendingPathExtension(codec.exportFormat.fileExtension)
                let job = try await Support.start(destination, context: context, in: settings)
                if index == 0 {
                    try await driver.wait("native export menu job finishes", seconds: 120) { job.status.isTerminal }
                    guard job.status == .completed else { throw Support.failed(job.failure ?? "Native menu export failed.") }
                    try driver.capture("native-menu-completed", target: settings)
                    try await driver.click("export.cancel", in: settings)
                    try await driver.wait("native export menu closes") { !editor.showExportDialog && window.isKeyWindow }
                }
                try await Support.complete(job, context: context)
                let probe = try await Task.detached { try await Support.decode(destination, evidence: directory.appendingPathComponent(name + "-decoded")) }.value
                let expectedCodec = codec == .h264 ? "avc1" : codec == .h265 ? "hvc1" : "apcn"
                guard probe.codec == expectedCodec, probe.width == width, probe.height == height, probe.fps == 24,
                      probe.frames.count == 48, abs(probe.duration - 2) < 0.05, editor.timeline == timeline else { throw Support.failed("The actual codec, portrait size, clock, duration or source timeline changed.") }
                try Support.recordJob(job, context: context, name: name)
                try driver.capture(name + "-qc", target: window)
                deliveries.append(["name": name, "jobID": job.id, "codec": codec.rawValue, "resolution": resolution.rawValue,
                    "target": target, "width": width, "height": height, "output": destination.lastPathComponent, "sha256": probe.sha256])
            }
            try await interchange(context)
            try await projectCopy(context, scale: scale)
            try await Support.save(context)
            guard !editor.hasProductionPipeline, editor.timeline == timeline else { throw Support.failed("Generic export changed the film or created production gates.") }
            try await negativeCopies(context, scale: scale)
            return ["directory": directory.lastPathComponent, "viewport": [bounds.width, bounds.height], "effectiveScale": scale,
                "deliveries": deliveries, "interactions": driver.interactions, "screenshots": driver.screenshots]
        } catch { driver.failure(error); throw error }
    }

    private static func interchange(_ context: Support.Context) async throws {
        let driver = context.driver, window = context.window
        try await Support.select("export.mode", title: ExportMode.xml.rawValue, in: window, driver: driver)
        let warning = "Text, blend modes, flips, adjustments, effects, and keyframe easing aren't included in XMEML."
        try await driver.reveal("export.xml.warning.0", in: window)
        guard driver.text("export.xml.warning.0", in: window) == warning else { throw Support.failed("XML losses are not visibly explained.") }
        try driver.capture("xml-loss-warning", target: window)
        let xml = try await Support.start(context.directory.appendingPathComponent("handoff.xml"), context: context)
        try await Support.complete(xml, context: context); try Support.recordJob(xml, context: context, name: "xmeml")
        guard xml.warnings.contains(warning) else { throw Support.failed("The actual XML job omitted its loss warning.") }
        try await driver.reveal("export.job.warning.0", in: window)
        guard driver.text("export.job.warning.0", in: window) == warning else { throw Support.failed("The completed XML warning is not visible.") }
        try driver.capture("xml-completed", target: window)
        for (version, target) in [(FCPXMLVersion.v1_10, FCPXMLTarget.finalCutPro), (.v1_14, .resolve)] {
            try await Support.select("export.mode", title: ExportMode.fcpxml.rawValue, in: window, driver: driver)
            try await Support.select("export.fcpxml.version", title: version.rawValue, in: window, driver: driver)
            try await Support.select("export.fcpxml.target", title: target.displayName, expected: target.rawValue, in: window, driver: driver)
            try await driver.reveal("export.start", in: window)
            try driver.capture("fcpxml-" + version.rawValue + "-settings", target: window)
            let name = "handoff-" + version.rawValue
            let job = try await Support.start(context.directory.appendingPathComponent(name + ".fcpxml"), context: context)
            try await Support.complete(job, context: context)
            guard let report = job.fcpxmlReport, report.version == version, report.target == target,
                  report.mediaBindings.count == 2 else { throw Support.failed("The native FCPXML export did not validate the selected profile and real media.") }
            try Support.recordJob(job, context: context, name: name)
            try await driver.reveal("export.fcpxml.report", in: window)
            guard driver.text("export.fcpxml.report", in: window) == version.rawValue + ":" + report.outputSHA256 else { throw Support.failed("The validated FCPXML result is not visible.") }
            try driver.capture(name + "-report", target: window)
        }
    }

    private static func projectCopy(_ context: Support.Context, scale: Double) async throws {
        let driver = context.driver, window = context.window, editor = context.editor
        try await Support.select("export.mode", title: ExportMode.ngvProject.rawValue, in: window, driver: driver)
        try await driver.reveal("export.start", in: window); try driver.capture("project-copy-settings", target: window)
        let destination = context.directory.appendingPathComponent("Portable copy.ngv", isDirectory: true)
        let originalID = ProjectIdentity.existingKey(for: context.package)
        let job = try await Support.start(destination, context: context)
        try await Support.complete(job, context: context)
        guard let report = job.projectReport, report.missing.isEmpty, report.collected == ["export-sound"], report.copiedInternal == 1,
              ProjectIdentity.existingKey(for: destination) != originalID else { throw Support.failed("The project copy did not collect its actual external media with a new identity.") }
        try Support.recordJob(job, context: context, name: "portable")
        let copy = try await Support.open(package: destination, directory: context.directory, scale: scale, name: "export-copy-reopen")
        defer { copy.document.close(); window.makeKeyAndOrderFront(nil) }
        guard copy.editor.timeline == editor.timeline, let root = copy.editor.workingRoot else { throw Support.failed("The exported copy reopened a different timeline.") }
        for entry in copy.editor.mediaManifest.entries {
            guard case .project(let relative) = entry.source, !relative.contains(".."),
                  let original = editor.mediaResolver.resolveURL(for: entry.id), let bundled = copy.editor.mediaResolver.resolveURL(for: entry.id),
                  bundled.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/"),
                  try FileDigest.sha256(of: original) == FileDigest.sha256(of: bundled) else { throw Support.failed("The portable copy still depends on external or changed media.") }
        }
        try await NativeEditingOwnerAcceptance.workspace(.edit, editor: copy.editor, window: copy.window, driver: copy.driver)
        try GenericNLEAcceptance.pointerOnRuler(frame: 24, window: copy.window, driver: copy.driver)
        try await copy.driver.wait("actual copied film preview") { copy.editor.currentFrame == 24 }
        try copy.driver.capture("portable-reopened", target: copy.window)
        try copy.driver.record("portable copy opened independently", fields: ["originalID": originalID ?? "", "copyID": ProjectIdentity.existingKey(for: destination) ?? "",
            "mediaIDs": copy.editor.mediaManifest.entries.map(\.id).sorted(), "timelineSHA256": try ExportArtwork.timelineHash(copy.editor.timeline)])
    }
    private static func negativeCopies(_ context: Support.Context, scale: Double) async throws {
        let package = context.directory.appendingPathComponent("Missing source.ngv", isDirectory: true)
        try FileManager.default.copyItem(at: context.package, to: package)
        try ProjectIdentity.regenerate(at: package)
        var manifest = try JSONDecoder().decode(MediaManifest.self, from: Data(contentsOf: package.appendingPathComponent(Project.manifestFilename)))
        let absent = MediaAsset(id: "missing-card", url: context.directory.appendingPathComponent("Absent card.png"), type: .image, name: "Absent card", duration: 0)
        manifest.entries.append(absent.toManifestEntry(projectURL: package))
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent(Project.manifestFilename))
        let missing = try await Support.open(package: package, directory: context.directory, scale: scale, name: "export-missing-media")
        defer { missing.document.close(); context.window.makeKeyAndOrderFront(nil) }
        try await Support.workspace(missing)
        try await Support.select("export.mode", title: ExportMode.ngvProject.rawValue, in: missing.window, driver: missing.driver)
        try await missing.driver.reveal("export.project.missing", in: missing.window)
        guard missing.driver.text("export.project.missing", in: missing.window) == "1" else { throw Support.failed("The missing project media was not visibly reported before export.") }
        try missing.driver.capture("missing-media-before-copy", target: missing.window)
        let copy = context.directory.appendingPathComponent("Copy with missing media.ngv", isDirectory: true)
        let job = try await Support.start(copy, context: missing)
        try await Support.complete(job, context: missing)
        guard job.projectReport?.missing.map(\.id) == ["missing-card"], !job.warnings.isEmpty else { throw Support.failed("The partial project copy falsely reported complete media.") }
        try Support.recordJob(job, context: missing, name: "missing-copy")
        try await missing.driver.reveal("export.job.warning.0", in: missing.window)
        guard missing.driver.text("export.job.warning.0", in: missing.window) == "1 media file could not be included." else { throw Support.failed("The completed partial-copy warning is missing.") }
        try missing.driver.capture("missing-media-after-copy", target: missing.window)

        let rejected = context.directory.appendingPathComponent("Stale destination.ngv", isDirectory: true)
        let replacement = context.directory.appendingPathComponent("Different source.ngv", isDirectory: true)
        try FileManager.default.copyItem(at: context.package, to: replacement)
        try ProjectIdentity.regenerate(at: replacement)
        let owner = missing.editor.openWorkingCopyKey
        try await missing.driver.click("export.start", in: missing.window)
        try await missing.driver.wait("real stale-target save panel") { NSApp.windows.contains { $0 is NSSavePanel && $0.isKeyWindow && $0.isVisible } }
        // Deliberately invalidate the captured project while its real target panel is open.
        missing.editor.projectURL = replacement
        try await missing.driver.wait("actual source owner changed") { missing.editor.openWorkingCopyKey != owner }
        let newOwner = missing.editor.openWorkingCopyKey
        try await missing.driver.saveFile(rejected, in: missing.window)
        try await missing.driver.wait("stale native project export refused") {
            missing.driver.text("export.error", in: missing.window) == "The project changed while choosing the export destination."
        }
        guard !FileManager.default.fileExists(atPath: rejected.path),
              !ExportQueue.shared.jobs.contains(where: { $0.destinationURL == rejected }) else { throw Support.failed("The stale project chooser exported the replacement document.") }
        try await missing.driver.reveal("export.error", in: missing.window)
        try missing.driver.capture("stale-project-refused", target: missing.window)
        try missing.driver.record("deliberate source-owner invalidation refuses publication", fields: ["previousOwner": owner ?? "", "currentOwner": newOwner ?? "",
            "outputExists": false, "error": missing.driver.text("export.error", in: missing.window) ?? ""])
    }
}
