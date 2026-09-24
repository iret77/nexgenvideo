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
}
