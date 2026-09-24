import Foundation
import Testing
@testable import NexGenVideo

@Suite("export_project tool", .serialized)
@MainActor
struct ExportProjectToolTests {
    private func openProject(_ harness: ToolHarness, name: String = "Project") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-project-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("\(name).ngv", isDirectory: true)
        try Fixtures.prepareProjectPackage(at: package, timeline: harness.editor.timeline)
        harness.editor.projectURL = package
        return root
    }

    @Test func rejectsInvalidArguments() async {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "missing", start: 0, duration: 30)]),
        ]))

        let cases: [([String: Any], String)] = [
            (["outputPath": "/tmp/out.mp4", "codec": "VP9"], "codec"),
            (["outputPath": "/tmp/out.mp4", "resolution": "8K"], "resolution"),
            (["mode": "edl", "outputPath": "/tmp/out.xml"], "mode"),
            (["mode": "xml", "codec": "H.264", "outputPath": "/tmp/out.xml"], "codec only applies"),
            (["mode": "xml", "version": "1.10", "outputPath": "/tmp/out.xml"], "version and target only apply"),
            (["mode": "fcpxml", "version": "1.9", "outputPath": "/tmp/out.fcpxml"], "version must be"),
            (["mode": "fcpxml", "target": "premiere", "outputPath": "/tmp/out.fcpxml"], "target must be"),
            (["outputPath": "relative.mp4"], "absolute"),
            (["outputPath": "/tmp/out.mov", "codec": "H.264"], ".mp4"),
        ]

        for (args, message) in cases {
            let result = await h.runRaw("export_project", args: args)
            #expect(result.isError)
            #expect(ToolHarness.textOf(result).contains(message))
        }

        let emptyTimeline = await ToolHarness().runRaw("export_project", args: ["outputPath": "/tmp/out.mp4"])
        #expect(emptyTimeline.isError)
        #expect(ToolHarness.textOf(emptyTimeline).contains("timeline is empty"))
    }

    @Test func handlesDestinations() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "missing", start: 0, duration: 30)]),
        ]))
        let base = "export-tool-\(UUID().uuidString)"
        let projectRoot = try openProject(h, name: base)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: projectRoot)
        }

        let existingVideo = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-existing-\(UUID().uuidString).mp4")
        try Data("existing".utf8).write(to: existingVideo)
        defer { try? FileManager.default.removeItem(at: existingVideo) }

        let overwriteFalse = await h.runRaw("export_project", args: [
            "outputPath": existingVideo.path,
            "overwrite": false,
        ])
        #expect(overwriteFalse.isError)
        #expect(ToolHarness.textOf(overwriteFalse).contains("already exists"))

        let downloads = try #require(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        let existingXML = downloads.appendingPathComponent("\(base).xml")
        try Data("existing".utf8).write(to: existingXML)
        defer { try? FileManager.default.removeItem(at: existingXML) }

        let unique = try await h.runOK("export_project", args: ["mode": "xml"]) as? [String: Any]
        let uniquePath = try #require(unique?["path"] as? String)
        let uniqueURL = URL(fileURLWithPath: uniquePath)
        defer { try? FileManager.default.removeItem(at: uniqueURL) }
        #expect(uniqueURL.deletingLastPathComponent().standardizedFileURL == downloads.standardizedFileURL)
        #expect(uniqueURL.lastPathComponent == "\(base) 2.xml")

    }

    @Test func exportsXML() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "missing", start: 0, duration: 30)]),
        ]))
        let projectRoot = try openProject(h)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: projectRoot)
        }
        let xmlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: xmlURL) }
        let requestID = UUID().uuidString
        let xml = try await h.runOK("export_project", args: [
            "mode": "xml",
            "outputPath": xmlURL.path,
            "requestID": requestID,
        ]) as? [String: Any]
        var changed = h.editor.timeline
        changed.width += 100
        changed.tracks[0].clips[0].durationFrames = 90
        h.editor.timeline = changed
        let joined = try await h.runOK("export_project", args: [
            "mode": "xml",
            "outputPath": xmlURL.path,
            "requestID": requestID,
        ]) as? [String: Any]
        #expect(xml?["status"] as? String == "exported")
        #expect(xml?["mode"] as? String == "xml")
        #expect((xml?["jobID"] as? String) == (joined?["jobID"] as? String))
        #expect((xml?["width"] as? Int) == (joined?["width"] as? Int))
        #expect((joined?["durationFrames"] as? Int) == 30)
        #expect(try String(contentsOf: xmlURL, encoding: .utf8).contains("<xmeml version=\"4\">"))
    }

    @Test func exportsVersionedFCPXMLWithEvidence() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline())
        let projectRoot = try openProject(h)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: projectRoot)
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-\(UUID().uuidString).fcpxml")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let report = try await h.runOK("export_project", args: [
            "mode": "fcpxml",
            "version": "1.14",
            "target": "resolve",
            "outputPath": outputURL.path,
        ]) as? [String: Any]

        #expect(report?["status"] as? String == "exported")
        #expect(report?["version"] as? String == "1.14")
        #expect(report?["target"] as? String == "resolve")
        #expect(report?["schemaProfile"] as? String == "apple/fcpxml-dtd/1.14")
        #expect((report?["outputSha256"] as? String)?.count == 64)
        #expect(((report?["outputByteCount"] as? NSNumber)?.int64Value ?? 0) > 0)
        #expect((report?["featureMatrix"] as? [[String: Any]])?.isEmpty == false)
        #expect(try String(contentsOf: outputURL, encoding: .utf8).contains("<fcpxml version=\"1.14\">"))
    }

    @Test func videoRejoinReportsActualPendingTerminalAndInterruptedState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-video-\(UUID().uuidString)", isDirectory: true)
        let generated = try await ImageVideoGenerator.blackVideo(
            size: CGSize(width: 320, height: 180)
        )
        let source = root.appendingPathComponent("source.mov")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: generated, to: source)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaRef: "source", start: 0, duration: 30),
        ])])
        timeline.width = 320
        timeline.height = 180
        let h = ToolHarness(timeline: timeline)
        let packageRoot = try openProject(h, name: "VideoStatus")
        h.editor.mediaManifest.entries = [MediaManifestEntry(
            id: "source",
            name: "Source",
            type: .video,
            source: .external(absolutePath: source.path),
            duration: 1
        )]
        let dataRoot = try #require(h.editor.workingRoot.flatMap {
            DataRootResolver.dataRoot(of: $0)
        })
        try YAMLArtifactStore(dataRoot: dataRoot).save(
            ProjectMeta(project: "video-status", mode: .generic),
            to: PipelineLayout.projectFile
        )
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: packageRoot)
            try? FileManager.default.removeItem(at: root)
        }

        let pendingID = UUID().uuidString
        let pendingURL = root.appendingPathComponent("pending.mp4")
        await ExportCoordinator.acquireExport()
        var gateHeld = true
        defer {
            if gateHeld { ExportCoordinator.endExport() }
        }
        let pending = try await h.runOK("export_project", args: [
            "mode": "video",
            "codec": "H.264",
            "resolution": "720p",
            "outputPath": pendingURL.path,
            "requestID": pendingID,
        ]) as? [String: Any]
        #expect(pending?["status"] as? String == "pending")
        let pendingJobID = try #require(pending?["jobID"] as? String)
        ExportQueue.shared.cancel(jobID: pendingJobID)
        _ = await ExportQueue.shared.waitForCompletion(jobID: pendingJobID)
        let cancelled = try await h.runOK("export_project", args: [
            "mode": "video",
            "codec": "H.264",
            "resolution": "720p",
            "outputPath": pendingURL.path,
            "requestID": pendingID,
        ]) as? [String: Any]
        #expect(cancelled?["status"] as? String == "cancelled")
        #expect((cancelled?["error"] as? String)?.contains("cancelled") == true)
        ExportCoordinator.endExport()
        gateHeld = false

        let completedID = UUID().uuidString
        let completedURL = root.appendingPathComponent("completed.mp4")
        let started = try await h.runOK("export_project", args: [
            "mode": "video",
            "codec": "H.264",
            "resolution": "720p",
            "outputPath": completedURL.path,
            "requestID": completedID,
        ]) as? [String: Any]
        let completedJobID = try #require(started?["jobID"] as? String)
        _ = await ExportQueue.shared.waitForCompletion(jobID: completedJobID)
        let completed = try await h.runOK("export_project", args: [
            "mode": "video",
            "codec": "H.264",
            "resolution": "720p",
            "outputPath": completedURL.path,
            "requestID": completedID,
        ]) as? [String: Any]
        #expect(completed?["status"] as? String == "completed")
        #expect((completed?["outputSha256"] as? String)?.count == 64)
        #expect(((completed?["outputByteCount"] as? NSNumber)?.int64Value ?? 0) > 0)

        let failedID = UUID().uuidString
        let failedURL = root.appendingPathComponent("failed.mp4")
        try Data("original".utf8).write(to: failedURL)
        await ExportCoordinator.acquireExport()
        gateHeld = true
        let initial = try await h.runOK("export_project", args: [
            "mode": "video",
            "codec": "H.264",
            "resolution": "720p",
            "outputPath": failedURL.path,
            "requestID": failedID,
        ]) as? [String: Any]
        let failedJobID = try #require(initial?["jobID"] as? String)
        try Data("external replacement".utf8).write(to: failedURL, options: .atomic)
        ExportCoordinator.endExport()
        gateHeld = false
        _ = await ExportQueue.shared.waitForCompletion(jobID: failedJobID)
        let failed = try await h.runOK("export_project", args: [
            "mode": "video",
            "codec": "H.264",
            "resolution": "720p",
            "outputPath": failedURL.path,
            "requestID": failedID,
        ]) as? [String: Any]
        #expect(failed?["status"] as? String == "failed")
        #expect((failed?["error"] as? String)?.contains("destination changed") == true)

        let interruptedID = UUID().uuidString.lowercased()
        let interruptedURL = root.appendingPathComponent("interrupted.mp4")
        let interruptedSpec = try PipelineDeliveryStore.defaultSpec(
            id: "agent.H.264.720p",
            targetKind: .derivative,
            timeline: timeline,
            format: .h264,
            resolution: .r720p,
            requireSequenceReview: false
        )
        let interruptedAttempt = DeliveryAttemptV1(
            id: interruptedID,
            spec: interruptedSpec,
            finishedTimelineSHA256: FileDigest.sha256(
                of: try PipelineAssemblyStore.canonical(timeline)
            ),
            status: .queued,
            outputPath: interruptedURL.path,
            createdAt: "2026-09-24T00:00:00Z"
        )
        let currentURL = dataRoot.appendingPathComponent(
            "delivery/jobs/\(interruptedID)/current.v1.json"
        )
        try FileManager.default.createDirectory(
            at: currentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PipelineAssemblyStore.canonical(interruptedAttempt).write(to: currentURL)
        let interrupted = try await h.runOK("export_project", args: [
            "mode": "video",
            "codec": "H.264",
            "resolution": "720p",
            "outputPath": interruptedURL.path,
            "requestID": interruptedID,
        ]) as? [String: Any]
        #expect(interrupted?["status"] as? String == "interrupted")
        #expect((interrupted?["error"] as? String)?.contains("interrupted") == true)
    }
}
