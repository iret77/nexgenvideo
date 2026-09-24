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
        let first = try await queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: firstURL,
            projectName: "Queue",
            requestID: requestID
        )
        let joined = try await queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: firstURL,
            projectName: "Queue",
            requestID: requestID
        )
        #expect(first === joined)
        await #expect(throws: (any Error).self) {
            _ = try await queue.enqueueInterchange(
                editor: editor,
                format: .xml,
                outputURL: root.appendingPathComponent("different.xml"),
                projectName: "Queue",
                requestID: requestID
            )
        }

        let cancelled = try await queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: cancelledURL,
            projectName: "Queue"
        )
        queue.cancel(jobID: cancelled.id)
        #expect(cancelled.status == .cancelled)

        let collisionWinner = try await queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: collisionURL,
            projectName: "Queue"
        )
        let collisionLoser = try await queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: collisionURL,
            projectName: "Queue"
        )
        try Data("original target".utf8).write(to: changedTargetURL)
        let changedTarget = try await queue.enqueueInterchange(
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
        let writerFailure = try await queue.enqueueInterchange(
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
        let job = try await queue.enqueueInterchange(
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
        let firstJob = try await ExportQueue.shared.enqueueInterchange(
            editor: firstEditor,
            format: .xml,
            outputURL: root.appendingPathComponent("first.xml"),
            projectName: "First"
        )
        let secondJob = try await ExportQueue.shared.enqueueInterchange(
            editor: secondEditor,
            format: .xml,
            outputURL: root.appendingPathComponent("second.xml"),
            projectName: "Second"
        )

        firstEditor.releaseWorkingCopy()
        #expect([.cancelling, .cancelled].contains(firstJob.status))
        #expect(secondJob.status == .pending)
        #expect(ExportQueue.shared.jobs(ownerKey: firstKey).contains { $0.id == firstJob.id })
        #expect(ExportQueue.shared.jobs(ownerKey: secondKey).contains { $0.id == secondJob.id })
        _ = await ExportQueue.shared.waitForCompletion(jobID: firstJob.id)
        #expect(firstJob.status == .cancelled)

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
        let enqueue = Task {
            try await queue.enqueueDelivery(
                editor: fixture.editor,
                spec: fixture.spec,
                format: .h264,
                resolution: .r720p,
                outputURL: output
            )
        }
        let ownerKey = try #require(fixture.editor.openWorkingCopyKey)
        var preparing: ExportJob?
        for _ in 0..<1_000 {
            preparing = queue.jobs(ownerKey: ownerKey).first { $0.status == .preparing }
            if preparing != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let job = try #require(preparing)
        queue.cancel(jobID: job.id)
        _ = await enqueue.result
        _ = await queue.waitForCompletion(jobID: job.id)

        #expect(job.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try PipelineDeliveryStore.listAttempts(dataRoot: fixture.dataRoot)
            .allSatisfy { $0.id != job.id })
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
        let job = try await queue.enqueueDelivery(
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
        let job = try await queue.enqueueDelivery(
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
        let job = try await queue.enqueueInterchange(
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

    @Test("editor refresh preserves queued and running delivery attempts owned by this process")
    func editorRefreshPreservesActiveDelivery() async throws {
        let fixture = try await makeDeliveryFixture(
            name: "RefreshActive",
            durationFrames: 150
        )
        defer { fixture.remove() }
        let queue = ExportQueue.shared
        let output = fixture.root.appendingPathComponent("refresh-active.mp4")
        await ExportCoordinator.acquireExport()
        var gateHeld = true
        defer {
            if gateHeld { ExportCoordinator.endExport() }
        }
        let job = try await queue.enqueueDelivery(
            editor: fixture.editor,
            spec: fixture.spec,
            format: .h264,
            resolution: .r720p,
            outputURL: output
        )

        await fixture.editor.refreshEngineState()
        let queued = try currentAttempt(id: job.id, dataRoot: fixture.dataRoot)
        #expect(queued.status == .queued)

        ExportCoordinator.endExport()
        gateHeld = false
        #expect(await wait(job, for: .exporting))
        await fixture.editor.refreshEngineState()
        let running = try currentAttempt(id: job.id, dataRoot: fixture.dataRoot)
        #expect(running.status == .running)

        queue.cancel(jobID: job.id)
        _ = await queue.waitForCompletion(jobID: job.id)
        #expect(job.status == .cancelled)
    }

    @Test("package snapshot survives a preceding delivery, later edits, and retry")
    func projectSnapshotKeepsEnqueuedTruthAcrossMixedQueueAndRetry() async throws {
        let fixture = try await makeDeliveryFixture(
            name: "MixedPackage",
            durationFrames: 30
        )
        defer { fixture.remove() }
        let queue = ExportQueue()
        let deliveryURL = fixture.root.appendingPathComponent("mixed.mp4")
        let packageURL = fixture.root.appendingPathComponent("MixedCopy.ngv", isDirectory: true)
        await ExportCoordinator.acquireExport()
        var gateHeld = true
        defer {
            if gateHeld { ExportCoordinator.endExport() }
        }

        let delivery = try await queue.enqueueDelivery(
            editor: fixture.editor,
            spec: fixture.spec,
            format: .h264,
            resolution: .r720p,
            outputURL: deliveryURL
        )
        let package = try await queue.enqueueProjectPackage(
            editor: fixture.editor,
            outputURL: packageURL
        )
        var changed = fixture.editor.timeline
        changed.tracks[0].clips[0].durationFrames = 90
        fixture.editor.timeline = changed
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data("external destination".utf8).write(
            to: packageURL.appendingPathComponent("owner.txt")
        )

        ExportCoordinator.endExport()
        gateHeld = false
        _ = await queue.waitForCompletion(jobID: delivery.id)
        _ = await queue.waitForCompletion(jobID: package.id)
        #expect(delivery.status == .completed)
        #expect(package.status == .failed)
        #expect(package.failure?.contains("destination changed") == true)

        try FileManager.default.removeItem(at: packageURL)
        changed.tracks[0].clips[0].durationFrames = 120
        fixture.editor.timeline = changed
        let retry = try queue.retry(jobID: package.id)
        _ = await queue.waitForCompletion(jobID: retry.id)

        #expect(retry.status == .completed)
        let exportedTimeline = try JSONDecoder().decode(
            Timeline.self,
            from: Data(contentsOf: packageURL.appendingPathComponent(Project.timelineFilename))
        )
        #expect(exportedTimeline.totalFrames == fixture.timeline.totalFrames)
        #expect(exportedTimeline.totalFrames == 30)
        let packagedDataRoot = try #require(DataRootResolver.dataRoot(of: packageURL))
        let packagedDelivery = try currentAttempt(id: delivery.id, dataRoot: packagedDataRoot)
        #expect(packagedDelivery.status == .queued)
        #expect(!FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent(".ngv-dirty").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent(".ngv-open-generation").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent(".ngv-materialized").path
        ))
    }

    @Test("a cancelled waiter returns without cancelling shared work")
    func waiterCancellationDoesNotCancelJoinedJob() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-waiter-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("Waiter.ngv", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        defer { editor.releaseWorkingCopy() }
        let ownerKey = try #require(editor.openWorkingCopyKey)
        let queue = ExportQueue()
        await ExportCoordinator.acquireExport()
        var gateHeld = true
        defer {
            if gateHeld { ExportCoordinator.endExport() }
        }
        let job = try await queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: root.appendingPathComponent("waiter.xml"),
            projectName: "Waiter"
        )
        let cancelledWaiter = Task { await queue.waitForCompletion(jobID: job.id) }
        let survivingWaiter = Task { await queue.waitForCompletion(jobID: job.id) }
        let idleWaiter = Task { await queue.waitUntilIdle(ownerKey: ownerKey) }

        cancelledWaiter.cancel()
        idleWaiter.cancel()
        let cancelledResult = await cancelledWaiter.value
        await idleWaiter.value
        #expect(cancelledResult?.id == job.id)
        #expect(job.status == .pending)

        ExportCoordinator.endExport()
        gateHeld = false
        let completed = await survivingWaiter.value
        #expect(completed?.status == .completed)
    }

    @Test("publish recovery rolls an interrupted FCPXML group back as one generation")
    func publishRecoveryRestoresGroupAndPreservesForeignChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-publish-recovery-\(UUID().uuidString)", isDirectory: true)
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        let document = root.appendingPathComponent("timeline.fcpxml")
        let media = root.appendingPathComponent("timeline Media", isDirectory: true)
        let jobID = UUID().uuidString.lowercased()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("old-document".utf8).write(to: document)
        try Data("old-media".utf8).write(to: media.appendingPathComponent("clip.mov"))

        let temporaryDocument = ExportQueue.DestinationBinding.makeTemporaryURL(
            url: document,
            jobID: jobID
        )
        let temporaryMedia = ExportQueue.DestinationBinding.makeTemporaryURL(
            url: media,
            jobID: jobID
        )
        try Data("new-document".utf8).write(to: temporaryDocument)
        try FileManager.default.createDirectory(at: temporaryMedia, withIntermediateDirectories: true)
        try Data("new-media".utf8).write(to: temporaryMedia.appendingPathComponent("clip.mov"))
        let publications = try [
            ExportPublishRecoveryStore.Publication(
                targetURL: document,
                temporaryURL: temporaryDocument,
                initialState: ExportQueue.PathState.capture(document),
                initialIdentity: try ExportFileIdentity.capture(document),
                publishedState: ExportQueue.PathState.capture(temporaryDocument),
                publishedIdentity: try ExportFileIdentity.capture(temporaryDocument),
                jobID: jobID,
                expectsDirectory: false
            ),
            ExportPublishRecoveryStore.Publication(
                targetURL: media,
                temporaryURL: temporaryMedia,
                initialState: ExportQueue.PathState.capture(media),
                initialIdentity: try ExportFileIdentity.capture(media),
                publishedState: ExportQueue.PathState.capture(temporaryMedia),
                publishedIdentity: try ExportFileIdentity.capture(temporaryMedia),
                jobID: jobID,
                expectsDirectory: true
            ),
        ]

        #expect(throws: (any Error).self) {
            _ = try ExportPublishRecoveryStore.publish(
                publications,
                root: recovery,
                crashAfterMutationForTesting: 3
            )
        }
        try Data("foreign-document".utf8).write(to: document, options: .atomic)
        try Data("foreign-temp-media".utf8).write(
            to: temporaryMedia.appendingPathComponent("clip.mov"),
            options: .atomic
        )
        try ExportPublishRecoveryStore.recoverAll(root: recovery)
        try ExportPublishRecoveryStore.recoverAll(root: recovery)

        #expect(try Data(contentsOf: document) == Data("old-document".utf8))
        #expect(try Data(contentsOf: media.appendingPathComponent("clip.mov")) == Data("old-media".utf8))
        let conflicts = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("Recovered Conflict") }
        #expect(conflicts.count == 2)
        #expect(conflicts.contains {
            (try? Data(contentsOf: $0.appendingPathComponent("clip.mov")))
                == Data("foreign-temp-media".utf8)
        })
        #expect(try FileManager.default.contentsOfDirectory(atPath: recovery.path).isEmpty)

        try Data("second-document".utf8).write(to: temporaryDocument)
        try FileManager.default.createDirectory(at: temporaryMedia, withIntermediateDirectories: true)
        try Data("second-media".utf8).write(to: temporaryMedia.appendingPathComponent("clip.mov"))
        let repeatedIDPublications = try [
            ExportPublishRecoveryStore.Publication(
                targetURL: document,
                temporaryURL: temporaryDocument,
                initialState: ExportQueue.PathState.capture(document),
                initialIdentity: try ExportFileIdentity.capture(document),
                publishedState: ExportQueue.PathState.capture(temporaryDocument),
                publishedIdentity: try ExportFileIdentity.capture(temporaryDocument),
                jobID: jobID,
                expectsDirectory: false
            ),
            ExportPublishRecoveryStore.Publication(
                targetURL: media,
                temporaryURL: temporaryMedia,
                initialState: ExportQueue.PathState.capture(media),
                initialIdentity: try ExportFileIdentity.capture(media),
                publishedState: ExportQueue.PathState.capture(temporaryMedia),
                publishedIdentity: try ExportFileIdentity.capture(temporaryMedia),
                jobID: jobID,
                expectsDirectory: true
            ),
        ]
        _ = try ExportPublishRecoveryStore.publish(repeatedIDPublications, root: recovery)
        #expect(try Data(contentsOf: document) == Data("second-document".utf8))
        #expect(try Data(contentsOf: media.appendingPathComponent("clip.mov")) == Data("second-media".utf8))

        try Data("third-document".utf8).write(to: temporaryDocument)
        try FileManager.default.createDirectory(at: temporaryMedia, withIntermediateDirectories: true)
        try Data("third-media".utf8).write(to: temporaryMedia.appendingPathComponent("clip.mov"))
        let firstMoveCrash = try [
            ExportPublishRecoveryStore.Publication(
                targetURL: document,
                temporaryURL: temporaryDocument,
                initialState: ExportQueue.PathState.capture(document),
                initialIdentity: try ExportFileIdentity.capture(document),
                publishedState: ExportQueue.PathState.capture(temporaryDocument),
                publishedIdentity: try ExportFileIdentity.capture(temporaryDocument),
                jobID: jobID,
                expectsDirectory: false
            ),
            ExportPublishRecoveryStore.Publication(
                targetURL: media,
                temporaryURL: temporaryMedia,
                initialState: ExportQueue.PathState.capture(media),
                initialIdentity: try ExportFileIdentity.capture(media),
                publishedState: ExportQueue.PathState.capture(temporaryMedia),
                publishedIdentity: try ExportFileIdentity.capture(temporaryMedia),
                jobID: jobID,
                expectsDirectory: true
            ),
        ]
        #expect(throws: (any Error).self) {
            _ = try ExportPublishRecoveryStore.publish(
                firstMoveCrash,
                root: recovery,
                crashAfterMutationForTesting: 1
            )
        }
        try ExportPublishRecoveryStore.recoverAll(root: recovery)
        #expect(try Data(contentsOf: document) == Data("second-document".utf8))
        #expect(try Data(contentsOf: media.appendingPathComponent("clip.mov")) == Data("second-media".utf8))

        let symlink = root.appendingPathComponent("linked.xml")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: document)
        #expect(throws: (any Error).self) {
            _ = try ExportQueue.DestinationBinding(
                url: symlink,
                jobID: UUID().uuidString.lowercased(),
                expectsDirectory: false
            )
        }
    }

    @Test("committed publish cleanup failures preserve the new FCPXML generation")
    func committedPublishCleanupFailuresPreservePublishedGroup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "export-committed-cleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        for failureIndex in [1, 2] {
            let fixture = try makePublishRecoveryFixture(
                root: root.appendingPathComponent("backup-\(failureIndex)", isDirectory: true)
            )
            #expect(throws: (any Error).self) {
                _ = try ExportPublishRecoveryStore.publish(
                    fixture.publications,
                    root: fixture.recovery,
                    failCommittedCleanupAfterBackupRemovalForTesting: failureIndex
                )
            }
            try expectPublishedRecoveryFixture(fixture)

            try ExportPublishRecoveryStore.recoverAll(root: fixture.recovery)
            try ExportPublishRecoveryStore.recoverAll(root: fixture.recovery)
            try expectPublishedRecoveryFixture(fixture, journalExists: false)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.recovery.path).isEmpty)
        }

        let journalFixture = try makePublishRecoveryFixture(
            root: root.appendingPathComponent("journal", isDirectory: true)
        )
        #expect(throws: (any Error).self) {
            _ = try ExportPublishRecoveryStore.publish(
                journalFixture.publications,
                root: journalFixture.recovery,
                failCommittedJournalRemovalForTesting: true
            )
        }
        try expectPublishedRecoveryFixture(journalFixture)

        for _ in 0..<2 {
            #expect(throws: (any Error).self) {
                try ExportPublishRecoveryStore.recoverAll(
                    root: journalFixture.recovery,
                    failCommittedJournalRemovalForTesting: true
                )
            }
            try expectPublishedRecoveryFixture(journalFixture)
        }
        try ExportPublishRecoveryStore.recoverAll(root: journalFixture.recovery)
        try ExportPublishRecoveryStore.recoverAll(root: journalFixture.recovery)
        try expectPublishedRecoveryFixture(journalFixture, journalExists: false)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: journalFixture.recovery.path).isEmpty
        )
    }

    private struct PublishRecoveryFixture {
        let recovery: URL
        let document: URL
        let media: URL
        let publications: [ExportPublishRecoveryStore.Publication]
    }

    private func makePublishRecoveryFixture(root: URL) throws -> PublishRecoveryFixture {
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        let document = root.appendingPathComponent("timeline.fcpxml")
        let media = root.appendingPathComponent("timeline Media", isDirectory: true)
        let jobID = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("old-document".utf8).write(to: document)
        try Data("old-media".utf8).write(to: media.appendingPathComponent("clip.mov"))

        let temporaryDocument = ExportQueue.DestinationBinding.makeTemporaryURL(
            url: document,
            jobID: jobID
        )
        let temporaryMedia = ExportQueue.DestinationBinding.makeTemporaryURL(
            url: media,
            jobID: jobID
        )
        try Data("new-document".utf8).write(to: temporaryDocument)
        try FileManager.default.createDirectory(at: temporaryMedia, withIntermediateDirectories: true)
        try Data("new-media".utf8).write(to: temporaryMedia.appendingPathComponent("clip.mov"))

        return try PublishRecoveryFixture(
            recovery: recovery,
            document: document,
            media: media,
            publications: [
                ExportPublishRecoveryStore.Publication(
                    targetURL: document,
                    temporaryURL: temporaryDocument,
                    initialState: ExportQueue.PathState.capture(document),
                    initialIdentity: ExportFileIdentity.capture(document),
                    publishedState: ExportQueue.PathState.capture(temporaryDocument),
                    publishedIdentity: ExportFileIdentity.capture(temporaryDocument),
                    jobID: jobID,
                    expectsDirectory: false
                ),
                ExportPublishRecoveryStore.Publication(
                    targetURL: media,
                    temporaryURL: temporaryMedia,
                    initialState: ExportQueue.PathState.capture(media),
                    initialIdentity: ExportFileIdentity.capture(media),
                    publishedState: ExportQueue.PathState.capture(temporaryMedia),
                    publishedIdentity: ExportFileIdentity.capture(temporaryMedia),
                    jobID: jobID,
                    expectsDirectory: true
                ),
            ]
        )
    }

    private func expectPublishedRecoveryFixture(
        _ fixture: PublishRecoveryFixture,
        journalExists: Bool = true
    ) throws {
        #expect(try Data(contentsOf: fixture.document) == Data("new-document".utf8))
        #expect(
            try Data(contentsOf: fixture.media.appendingPathComponent("clip.mov"))
                == Data("new-media".utf8)
        )
        let records = try FileManager.default.contentsOfDirectory(
            at: fixture.recovery,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        #expect(records.count == (journalExists ? 1 : 0))
    }

    private func currentAttempt(id: String, dataRoot: URL) throws -> DeliveryAttemptV1 {
        let url = dataRoot.appendingPathComponent("delivery/jobs/\(id)/current.v1.json")
        return try JSONDecoder().decode(DeliveryAttemptV1.self, from: Data(contentsOf: url))
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

        _ = try await PipelineDeliveryStore.adoptCurrentTimeline(
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
