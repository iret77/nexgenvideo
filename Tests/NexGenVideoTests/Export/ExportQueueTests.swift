import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Export queue", .serialized)
@MainActor
struct ExportQueueTests {
    @Test("serial jobs join by stable ID, cancel pending work, and reject target collisions")
    func serializationJoinCancellationAndCollision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-queue-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("Queue.ngv", isDirectory: true)
        let firstURL = root.appendingPathComponent("first.xml")
        let cancelledURL = root.appendingPathComponent("cancelled.xml")
        let collisionURL = root.appendingPathComponent("collision.xml")
        let changedTargetURL = root.appendingPathComponent("changed.xml")
        let removedDirectory = root.appendingPathComponent("removed", isDirectory: true)
        let writerFailureURL = removedDirectory.appendingPathComponent("writer.xml")
        defer { try? FileManager.default.removeItem(at: root) }

        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(mediaRef: "offline", start: 0, duration: 30),
            ]),
        ])
        try Fixtures.prepareProjectPackage(at: package, timeline: timeline)
        let editor = EditorViewModel()
        editor.timeline = timeline
        editor.projectURL = package
        defer { editor.releaseWorkingCopy() }
        _ = try #require(editor.workingRoot)

        let queue = ExportQueue()
        await ExportCoordinator.acquireExport()
        var gateHeld = true
        defer {
            if gateHeld { ExportCoordinator.endExport() }
        }

        let requestID = UUID().uuidString
        let first = try queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: firstURL,
            projectName: "Queue",
            requestID: requestID
        )
        let joined = try queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: firstURL,
            projectName: "Queue",
            requestID: requestID
        )
        #expect(first === joined)
        #expect(throws: (any Error).self) {
            _ = try queue.enqueueInterchange(
                editor: editor,
                format: .xml,
                outputURL: root.appendingPathComponent("different.xml"),
                projectName: "Queue",
                requestID: requestID
            )
        }

        let cancelled = try queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: cancelledURL,
            projectName: "Queue"
        )
        queue.cancel(jobID: cancelled.id)
        #expect(cancelled.status == .cancelled)

        let collisionWinner = try queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: collisionURL,
            projectName: "Queue"
        )
        let collisionLoser = try queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: collisionURL,
            projectName: "Queue"
        )
        try Data("original target".utf8).write(to: changedTargetURL)
        let changedTarget = try queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: changedTargetURL,
            projectName: "Queue"
        )
        try Data("new owner bytes".utf8).write(to: changedTargetURL)
        try FileManager.default.createDirectory(
            at: removedDirectory,
            withIntermediateDirectories: true
        )
        let writerFailure = try queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: writerFailureURL,
            projectName: "Queue"
        )
        try FileManager.default.removeItem(at: removedDirectory)

        var changed = timeline
        changed.tracks[0].clips[0].durationFrames = 90
        editor.timeline = changed

        ExportCoordinator.endExport()
        gateHeld = false
        _ = await queue.waitForCompletion(jobID: first.id)
        _ = await queue.waitForCompletion(jobID: collisionWinner.id)
        _ = await queue.waitForCompletion(jobID: collisionLoser.id)
        _ = await queue.waitForCompletion(jobID: changedTarget.id)
        _ = await queue.waitForCompletion(jobID: writerFailure.id)

        #expect(first.status == .completed)
        #expect(collisionWinner.status == .completed)
        #expect(collisionLoser.status == .failed)
        #expect(collisionLoser.failure?.contains("destination changed") == true)
        #expect(changedTarget.status == .failed)
        #expect(writerFailure.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: writerFailureURL.path))
        #expect(try Data(contentsOf: changedTargetURL) == Data("new owner bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: cancelledURL.path))
        let xml = try String(contentsOf: firstURL, encoding: .utf8)
        #expect(xml.contains("<duration>30</duration>"))

        try Data("original target".utf8).write(to: changedTargetURL)
        let retry = try queue.retry(jobID: changedTarget.id)
        _ = await queue.waitForCompletion(jobID: retry.id)
        #expect(retry.status == .completed)
        #expect(try String(contentsOf: changedTargetURL, encoding: .utf8)
            .contains("<duration>30</duration>"))
    }

    @Test("a changed offline binding fails closed instead of silently substituting media")
    func sourceAppearanceAfterEnqueueFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-source-drift-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("Drift.ngv", isDirectory: true)
        let source = root.appendingPathComponent("late.mov")
        let output = root.appendingPathComponent("drift.xml")
        defer { try? FileManager.default.removeItem(at: root) }

        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(mediaRef: "late", start: 0, duration: 30),
            ]),
        ])
        try Fixtures.prepareProjectPackage(at: package, timeline: timeline)
        let editor = EditorViewModel()
        editor.timeline = timeline
        editor.mediaManifest.entries = [MediaManifestEntry(
            id: "late",
            name: "Late source",
            type: .video,
            source: .external(absolutePath: source.path),
            duration: 1
        )]
        editor.projectURL = package
        defer { editor.releaseWorkingCopy() }
        _ = try #require(editor.workingRoot)

        let queue = ExportQueue()
        await ExportCoordinator.acquireExport()
        var gateHeld = true
        defer {
            if gateHeld { ExportCoordinator.endExport() }
        }
        let job = try queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: output,
            projectName: "Drift"
        )
        try Data("new source".utf8).write(to: source)
        ExportCoordinator.endExport()
        gateHeld = false
        _ = await queue.waitForCompletion(jobID: job.id)

        #expect(job.status == .failed)
        #expect(job.failure?.contains("source changed") == true)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("closing a project cancels its queued work without changing another document")
    func closeCancelsOnlyOwningProject() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-close-\(UUID().uuidString)", isDirectory: true)
        let firstPackage = root.appendingPathComponent("First.ngv", isDirectory: true)
        let secondPackage = root.appendingPathComponent("Second.ngv", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixtures.prepareProjectPackage(at: firstPackage)
        try Fixtures.prepareProjectPackage(at: secondPackage)

        let firstEditor = EditorViewModel()
        firstEditor.projectURL = firstPackage
        let secondEditor = EditorViewModel()
        secondEditor.projectURL = secondPackage
        defer { secondEditor.releaseWorkingCopy() }
        let firstKey = try #require(firstEditor.openWorkingCopyKey)
        let secondKey = try #require(secondEditor.openWorkingCopyKey)

        await ExportCoordinator.acquireExport()
        var gateHeld = true
        defer {
            if gateHeld { ExportCoordinator.endExport() }
        }
        let firstJob = try ExportQueue.shared.enqueueInterchange(
            editor: firstEditor,
            format: .xml,
            outputURL: root.appendingPathComponent("first.xml"),
            projectName: "First"
        )
        let secondJob = try ExportQueue.shared.enqueueInterchange(
            editor: secondEditor,
            format: .xml,
            outputURL: root.appendingPathComponent("second.xml"),
            projectName: "Second"
        )

        firstEditor.releaseWorkingCopy()
        #expect(firstJob.status == .cancelled)
        #expect(secondJob.status == .pending)
        #expect(ExportQueue.shared.jobs(ownerKey: firstKey).contains { $0.id == firstJob.id })
        #expect(ExportQueue.shared.jobs(ownerKey: secondKey).contains { $0.id == secondJob.id })

        ExportCoordinator.endExport()
        gateHeld = false
        _ = await ExportQueue.shared.waitForCompletion(jobID: secondJob.id)
        #expect(secondJob.status == .completed)
    }

    @Test("cancelling preparation stops before rendering and records no success")
    func cancelPreparing() async throws {
        let fixture = try await makeDeliveryFixture(
            name: "CancelPreparing",
            durationFrames: 150,
            extensionBytes: 32 * 1_048_576
        )
        defer { fixture.remove() }
        let queue = ExportQueue()
        let output = fixture.root.appendingPathComponent("cancel-preparing.mp4")
        let job = try queue.enqueueDelivery(
            editor: fixture.editor,
            spec: fixture.spec,
            format: .h264,
            resolution: .r720p,
            outputURL: output
        )

        let reachedPreparing = await wait(job, for: .preparing)
        #expect(reachedPreparing)
        queue.cancel(jobID: job.id)
        _ = await queue.waitForCompletion(jobID: job.id)

        #expect(job.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let attempt = try PipelineDeliveryStore.loadAttempt(
            id: job.id,
            dataRoot: fixture.dataRoot
        )
        #expect(attempt.status == .cancelled)
        #expect(attempt.outputSHA256 == nil)
    }

    @Test("cancelling an active renderer leaves no output or success receipt")
    func cancelExporting() async throws {
        let fixture = try await makeDeliveryFixture(
            name: "CancelExporting",
            durationFrames: 150
        )
        defer { fixture.remove() }
        let queue = ExportQueue()
        let output = fixture.root.appendingPathComponent("cancel-exporting.mp4")
        let job = try queue.enqueueDelivery(
            editor: fixture.editor,
            spec: fixture.spec,
            format: .h264,
            resolution: .r720p,
            outputURL: output
        )

        let reachedExporting = await wait(job, for: .exporting)
        #expect(reachedExporting)
        queue.cancel(jobID: job.id)
        _ = await queue.waitForCompletion(jobID: job.id)

        #expect(job.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let attempt = try PipelineDeliveryStore.loadAttempt(
            id: job.id,
            dataRoot: fixture.dataRoot
        )
        #expect(attempt.status == .cancelled)
        #expect(attempt.probeQC == nil)
    }

    @Test("a successful job receipts its queued cut without selecting it over a newer edit")
    func successfulReceiptKeepsQueuedTimelineIdentity() async throws {
        let fixture = try await makeDeliveryFixture(
            name: "ExactReceipt",
            durationFrames: 30
        )
        defer { fixture.remove() }
        let queue = ExportQueue()
        let output = fixture.root.appendingPathComponent("exact.mp4")

        await ExportCoordinator.acquireExport()
        var gateHeld = true
        defer {
            if gateHeld { ExportCoordinator.endExport() }
        }
        let job = try queue.enqueueDelivery(
            editor: fixture.editor,
            spec: fixture.spec,
            format: .h264,
            resolution: .r720p,
            outputURL: output
        )
        var changed = fixture.timeline
        changed.tracks[0].clips[0].durationFrames = 60
        fixture.editor.timeline = changed
        ExportCoordinator.endExport()
        gateHeld = false
        _ = await queue.waitForCompletion(jobID: job.id)

        #expect(job.status == .completed)
        let attempt = try PipelineDeliveryStore.loadAttempt(
            id: job.id,
            dataRoot: fixture.dataRoot
        )
        let outputSHA256 = try FileDigest.sha256(of: output)
        #expect(attempt.status == .succeeded)
        #expect(attempt.outputSHA256 == outputSHA256)
        #expect(attempt.probeQC?.passed == true)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.dataRoot.appendingPathComponent(
                PipelineDeliveryStore.selectionPath
            ).path
        ))
    }

    @Test("FCPXML publishes its relink media beside the final document")
    func fcpxmlPublishesBoundRelinkMedia() async throws {
        let fixture = try await makeDeliveryFixture(
            name: "FCPXMLRelink",
            durationFrames: 30,
            projectMedia: true
        )
        defer { fixture.remove() }
        let queue = ExportQueue()
        let output = fixture.root.appendingPathComponent("timeline.fcpxml")
        let job = try queue.enqueueInterchange(
            editor: fixture.editor,
            format: .fcpxml,
            outputURL: output,
            projectName: "Relink"
        )
        _ = await queue.waitForCompletion(jobID: job.id)

        let mediaDirectory = FCPXMLExporter.mediaDirectory(for: output)
        let document = try String(contentsOf: output, encoding: .utf8)
        #expect(job.status == .completed)
        #expect(FileManager.default.fileExists(atPath: mediaDirectory.path))
        #expect(document.contains("timeline%20Media"))
        #expect(!document.contains("NexGenVideoExportQueue"))
        #expect(!document.contains(".partial"))
        #expect(job.fcpxmlReport?.mediaBindings.allSatisfy {
            !$0.sourceURL.contains("NexGenVideoExportQueue")
                && !$0.sourceURL.contains(".partial")
        } == true)
    }

    @Test("restart marks active delivery interrupted, cleans its partials, and does not auto-retry")
    func interruptedRestartIsHonest() async throws {
        let fixture = try await makeDeliveryFixture(
            name: "InterruptedRestart",
            durationFrames: 30
        )
        defer { fixture.remove() }
        let id = UUID().uuidString.lowercased()
        let output = fixture.root.appendingPathComponent("restart.mp4")
        try Data("existing finished export".utf8).write(to: output)
        let attempt = DeliveryAttemptV1(
            id: id,
            spec: fixture.spec,
            finishedTimelineSHA256: FileDigest.sha256(
                of: try PipelineAssemblyStore.canonical(fixture.timeline)
            ),
            status: .running,
            outputPath: output.path,
            createdAt: "2026-09-24T00:00:00Z"
        )
        let current = fixture.dataRoot.appendingPathComponent(
            "delivery/jobs/\(id)/current.v1.json"
        )
        try FileManager.default.createDirectory(
            at: current.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PipelineAssemblyStore.canonical(attempt).write(to: current)
        let partial = fixture.root.appendingPathComponent(".restart.\(id).partial.mp4")
        try Data("partial".utf8).write(to: partial)
        let snapshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NexGenVideoExportQueue/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("snapshot".utf8).write(to: snapshot.appendingPathComponent("source"))

        let queue = ExportQueue()
        let ownerKey = try #require(fixture.editor.openWorkingCopyKey)
        queue.loadPersistedDeliveryJobs(ownerKey: ownerKey, dataRoot: fixture.dataRoot)

        let job = try #require(queue.jobs(ownerKey: ownerKey).first { $0.id == id })
        #expect(job.status == .interrupted)
        #expect(!queue.canRetry(jobID: id))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        #expect(try Data(contentsOf: output) == Data("existing finished export".utf8))
        #expect(try PipelineDeliveryStore.loadAttempt(
            id: id,
            dataRoot: fixture.dataRoot
        ).status == .interrupted)
    }

    private struct DeliveryFixture {
        let root: URL
        let editor: EditorViewModel
        let dataRoot: URL
        let timeline: Timeline
        let spec: DeliverySpecV1

        func remove() {
            editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeDeliveryFixture(
        name: String,
        durationFrames: Int,
        extensionBytes: Int = 0,
        projectMedia: Bool = false
    ) async throws -> DeliveryFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-delivery-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("\(name).ngv", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let generated = try await ImageVideoGenerator.blackVideo(
            size: CGSize(width: 320, height: 180)
        )
        let source = root.appendingPathComponent("source.mov")
        try FileManager.default.copyItem(at: generated, to: source)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaRef: "source", start: 0, duration: durationFrames),
        ])])
        timeline.width = 320
        timeline.height = 180
        try Fixtures.prepareProjectPackage(at: package, timeline: timeline)

        let editor = EditorViewModel()
        editor.projectURL = package
        editor.timeline = timeline
        let workingRoot = try #require(editor.workingRoot)
        let mediaSource: MediaSource
        if projectMedia {
            let relativePath = "media/source.mov"
            let projectSource = workingRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: projectSource.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: projectSource)
            mediaSource = .project(relativePath: relativePath)
        } else {
            mediaSource = .external(absolutePath: source.path)
        }
        editor.mediaManifest.entries = [MediaManifestEntry(
            id: "source",
            name: "Source",
            type: .video,
            source: mediaSource,
            duration: 5
        )]
        let dataRoot = try #require(DataRootResolver.dataRoot(of: workingRoot))
        try YAMLArtifactStore(dataRoot: dataRoot).save(
            ProjectMeta(project: name.lowercased(), mode: .generic),
            to: PipelineLayout.projectFile
        )

        var extensionRefs: [String] = []
        if extensionBytes > 0 {
            let extensionURL = dataRoot.appendingPathComponent("assets/bound.bin")
            try FileManager.default.createDirectory(
                at: extensionURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(atPath: extensionURL.path, contents: nil) else {
                throw ToolError("Could not create the delivery extension fixture.")
            }
            let handle = try FileHandle(forWritingTo: extensionURL)
            let chunk = Data(repeating: 0x5a, count: 1_048_576)
            for _ in 0..<(extensionBytes / chunk.count) {
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
            extensionRefs = ["assets/bound.bin"]
        }

        _ = try PipelineDeliveryStore.adoptCurrentTimeline(
            editor: editor,
            requireSequenceReview: false
        )
        let spec = try PipelineDeliveryStore.defaultSpec(
            id: "master.h264.720p",
            targetKind: .master,
            timeline: timeline,
            format: .h264,
            resolution: .r720p,
            requireSequenceReview: false,
            extensionRefs: extensionRefs
        )
        return DeliveryFixture(
            root: root,
            editor: editor,
            dataRoot: dataRoot,
            timeline: timeline,
            spec: spec
        )
    }

    private func wait(
        _ job: ExportJob,
        for status: ExportJobStatus
    ) async -> Bool {
        for _ in 0..<1_000 {
            if job.status == status { return true }
            if job.status.isTerminal { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
}
