import Foundation
import CoreImage
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Portable immutable LUT resources")
struct ProjectEffectResourcesTests {
    @Test func realColorToolKeepsDifferentLUTsWithTheSameFilename() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("Color.ngv")
        try Fixtures.prepareProjectPackage(at: package)
        _ = try ProjectIdentity.uuid(for: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        defer { editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: root) }
        let first = Clip(mediaRef: "image-a", mediaType: .image, sourceClipType: .image, startFrame: 0, durationFrames: 30)
        let second = Clip(mediaRef: "image-b", mediaType: .image, sourceClipType: .image, startFrame: 30, durationFrames: 30)
        editor.timeline.tracks = [Track(type: .video, clips: [first, second])]
        let originals = try inputs(root: root)
        let executor = ToolExecutor(editor: editor)
        let appliedFirst = await executor.execute(name: "apply_color", args: ["clipIds": [first.id], "lut": ["path": originals.0.path]])
        #expect(!appliedFirst.isError)
        let firstPath = try #require(editor.clipFor(id: first.id)?.effects?.first(where: { $0.type == "color.lut" })?.params["path"]?.string)
        let appliedSecond = await executor.execute(name: "apply_color", args: ["clipIds": [second.id], "lut": ["path": originals.1.path]])
        #expect(!appliedSecond.isError)
        let secondPath = try #require(editor.clipFor(id: second.id)?.effects?.first(where: { $0.type == "color.lut" })?.params["path"]?.string)
        #expect(firstPath != secondPath)
        #expect(ProjectEffectResources.isPortable(firstPath) && ProjectEffectResources.isPortable(secondPath))
        let home = try #require(editor.workingRoot)
        #expect(try Data(contentsOf: home.appendingPathComponent(firstPath)) == cube(false))
        #expect(try Data(contentsOf: home.appendingPathComponent(secondPath)) == cube(true))
        #expect(editor.clipFor(id: first.id)?.effects?.first(where: { $0.type == "color.lut" })?.params["name"]?.string == "Look.cube")
        let reassigned = await executor.execute(name: "apply_color", args: ["clipIds": [first.id], "lut": ["path": secondPath]])
        #expect(!reassigned.isError)
        let changed = try #require(editor.clipFor(id: first.id)?.effects?.first(where: { $0.type == "color.lut" }))
        #expect(changed.params["path"]?.string == secondPath)
        #expect(changed.params["name"]?.string == nil)
    }

    @Test func saveAsMoveReopenAndExportRetainActualLUTBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("Before.ngv")
        try Fixtures.prepareProjectPackage(at: package)
        _ = try ProjectIdentity.uuid(for: package)
        let original = try inputs(root: root).0
        let document = try await VideoProject.load(from: package)
        let editor = document.editorViewModel
        defer { document.close(); editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: root) }
        var clip = Clip(mediaRef: "image", mediaType: .image, sourceClipType: .image, startFrame: 0, durationFrames: 30)
        clip.effects = [.init(type: "color.lut", params: ["path": .init(string: original.path)])]
        editor.timeline.tracks = [Track(type: .video, clips: [clip])]
        let copy = root.appendingPathComponent("Saved copy.ngv")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: copy, ofType: VideoProject.typeIdentifier, for: .saveToOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let moved = root.appendingPathComponent("Moved.ngv")
        try FileManager.default.moveItem(at: copy, to: moved)
        try FileManager.default.removeItem(at: original)
        let reopened = try await VideoProject.load(from: moved)
        defer { reopened.close(); reopened.editorViewModel.releaseWorkingCopy() }
        let timeline = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: moved.appendingPathComponent(Project.timelineFilename)))
        let bindings = try ProjectEffectResources.capture(timeline: timeline, projectRoot: moved)
        #expect(bindings.count == 1)
        #expect(try Data(contentsOf: bindings[0].url) == cube(false))
        #expect(ProjectIdentity.existingUUID(for: package) != ProjectIdentity.existingUUID(for: moved))
        let resolver = MediaResolver(manifest: { MediaManifest() }, projectURL: { moved })
        let source = try ExportQueue.SourceBinding.interchange(timeline: timeline, resolver: resolver)
        let frozen = try source.freeze(jobID: UUID().uuidString, isCancelled: { false })
        defer { frozen.remove() }
        let frozenResolver = frozen.resolver(basedOn: resolver)
        let frozenBindings = try ProjectEffectResources.capture(timeline: timeline, resolver: frozenResolver)
        #expect(frozenBindings.count == 1)
        #expect(frozenBindings[0].url.path.hasPrefix(frozen.root.path + "/"))
        let resource = try #require(frozen.files.first { $0.ref.hasPrefix("effect resource ") })
        #expect(try Data(contentsOf: resource.url) == cube(false))
        try frozen.verify()
        try cube(true).write(to: bindings[0].url)
        #expect(throws: (any Error).self) { try source.verify() }
        #expect(throws: (any Error).self) { try ProjectEffectResources.capture(timeline: timeline, projectRoot: moved) }
        #expect(throws: (any Error).self) { try ProjectEffectResources.portable(timeline, projectRoot: moved) }
        #expect(LUTLoader.load(path: bindings[0].path) != nil)
        try ProjectEffectResources.requireCurrent(frozenBindings)
        try FileManager.default.removeItem(at: bindings[0].url)
        #expect(throws: (any Error).self) { try ProjectEffectResources.capture(timeline: timeline, projectRoot: moved) }
        try ProjectEffectResources.requireCurrent(frozenBindings)
        try frozen.verify()
    }

    @Test func offlineLegacyLUTOpensForVisibleRelinkButCannotSaveOrExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("Offline legacy.ngv")
        let missing = root.appendingPathComponent("missing/Original look.cube").path
        var clip = Clip(mediaRef: "image", mediaType: .image, sourceClipType: .image, startFrame: 0, durationFrames: 30)
        clip.effects = [.init(type: "color.lut", params: ["path": .init(string: missing)])]
        var timeline = Timeline(); timeline.tracks = [Track(type: .video, clips: [clip])]
        try Fixtures.prepareProjectPackage(at: package, timeline: timeline)
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = try ProjectEffectResources.open(timeline: timeline, projectRoot: package)
        #expect(opened.timeline == timeline)
        #expect(opened.problems.count == 1)
        #expect(opened.problems[0].clipID == clip.id)
        #expect(opened.problems[0].name == "Original look.cube")
        #expect(opened.problems[0].message.contains("Relink or remove"))
        #expect(throws: (any Error).self) { try ProjectEffectResources.portable(timeline, projectRoot: package) }
        #expect(throws: (any Error).self) { try ProjectEffectResources.capture(timeline: timeline, projectRoot: package) }
        let document = try await VideoProject.load(from: package)
        defer { document.close(); document.editorViewModel.releaseWorkingCopy() }
        document.makeWindowControllers()
        #expect(document.editorViewModel.effectResourceProblems == opened.problems)
    }


    @Test func missingOrTamperedPortableLUTOpensForRecoveryButCannotSaveOrExport() async throws {
        for tampered in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let package = root.appendingPathComponent("Portable recovery.ngv")
            let bytes = cube(false)
            let path = ProjectEffectResources.directory + "/" + FileDigest.sha256(of: bytes) + ".cube"
            var clip = Clip(mediaRef: "image", mediaType: .image, sourceClipType: .image, startFrame: 0, durationFrames: 30)
            clip.effects = [.init(type: "color.lut", params: ["path": .init(string: path), "name": .init(string: "Camera look.cube")])]
            var timeline = Timeline(); timeline.tracks = [Track(type: .video, clips: [clip])]
            try Fixtures.prepareProjectPackage(at: package, timeline: timeline)
            defer { try? FileManager.default.removeItem(at: root) }
            if tampered {
                let url = package.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try cube(true).write(to: url)
            }
            let opened = try ProjectEffectResources.open(timeline: timeline, projectRoot: package)
            #expect(opened.timeline == timeline)
            #expect(opened.problems.count == 1)
            #expect(opened.problems[0].path == path)
            #expect(opened.problems[0].name == "Camera look.cube")
            #expect(throws: (any Error).self) { try ProjectEffectResources.portable(timeline, projectRoot: package) }
            #expect(throws: (any Error).self) { try ProjectEffectResources.capture(timeline: timeline, projectRoot: package) }
            let document = try await VideoProject.load(from: package)
            defer { document.close(); document.editorViewModel.releaseWorkingCopy() }
            document.makeWindowControllers()
            #expect(document.editorViewModel.effectResourceProblems == opened.problems)
            #expect(document.editorViewModel.timeline == timeline)
        }
    }

    @Test func legacyAbsoluteLUTRendersFromFrozenBytesAfterOriginalChangesOrDisappears() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Legacy look.cube")
        let expected = cube(true)
        try expected.write(to: original)
        var clip = Clip(mediaRef: "image", mediaType: .image, sourceClipType: .image, startFrame: 0, durationFrames: 30)
        clip.effects = [.init(type: "color.lut", params: ["path": .init(string: original.path), "intensity": .init(value: 1)])]
        var timeline = Timeline(); timeline.tracks = [Track(type: .video, clips: [clip])]
        let resolver = MediaResolver(manifest: { MediaManifest() }, projectURL: { root })
        let source = try ExportQueue.SourceBinding.interchange(timeline: timeline, resolver: resolver)
        let frozen = try source.freeze(jobID: UUID().uuidString, isCancelled: { false })
        defer { frozen.remove() }
        let frozenResolver = frozen.resolver(basedOn: resolver)
        let bindings = try ProjectEffectResources.capture(timeline: timeline, resolver: frozenResolver)
        #expect(bindings.count == 1)
        #expect(bindings[0].url != original)
        try cube(false).write(to: original)
        try FileManager.default.removeItem(at: original)
        let rendering = try ProjectEffectResources.renderTimeline(timeline, bindings: bindings)
        let effect = try #require(rendering.tracks.first?.clips.first?.effects?.first)
        let path = try #require(effect.params["path"]?.string)
        #expect(ProjectEffectResources.isPortable(path))
        #expect(timeline.tracks[0].clips[0].effects?[0].params["path"]?.string == original.path)
        let lut = try #require(LUTLoader.load(path: path))
        let input = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let rendered = LUTTetraKernel.apply(input, cube: lut, key: path, intensity: 1)
        var pixel = [Float](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]).render(rendered,
            toBitmap: &pixel, rowBytes: 16, bounds: input.extent, format: .RGBAf, colorSpace: nil)
        #expect(abs(pixel[0] - 0.2) < 0.001 && abs(pixel[1] - 0.8) < 0.001 && abs(pixel[2] - 0.6) < 0.001)
        try frozen.verify()
        try cube(false).write(to: bindings[0].url)
        #expect(throws: (any Error).self) { try ProjectEffectResources.renderTimeline(timeline, bindings: bindings) }
    }

    private func inputs(root: URL) throws -> (URL, URL) {
        let first = root.appendingPathComponent("first/Look.cube")
        let second = root.appendingPathComponent("second/Look.cube")
        for (url, inverted) in [(first, false), (second, true)] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try cube(inverted).write(to: url)
        }
        return (first, second)
    }

    private func cube(_ inverted: Bool) -> Data {
        let rows = (0..<8).map { index in
            [index & 1, (index >> 1) & 1, (index >> 2) & 1].map { String(inverted ? 1 - $0 : $0) }.joined(separator: " ")
        }
        return Data(("LUT_3D_SIZE 2\n" + rows.joined(separator: "\n") + "\n").utf8)
    }
}
