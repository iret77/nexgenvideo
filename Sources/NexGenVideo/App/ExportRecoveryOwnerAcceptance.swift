import AppKit
import Darwin
import NexGenEngine

@MainActor
enum ExportRecoveryOwnerAcceptance {
    private typealias Support = ExportOwnerAcceptanceSupport
    private struct Saved: Codable {
        let processID: Int32; let ownerKey: String; let interruptedID: String; let completedID: String
        let completedSHA256: String; let timelineSHA256: String; let output: String
        let partial: String; let snapshotRoot: String; let progress: Double
    }

    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let stage = ProcessInfo.processInfo.environment["NGV_EXPORT_RECOVERY_STAGE"] ?? ""
        guard ["prepare", "resume"].contains(stage) else { throw Support.failed("The real export restart stage is missing.") }
        let directory = output.appendingPathComponent("export-recovery-\(Int(scale * 100))", isDirectory: true)
        let context: Support.Context
        if stage == "prepare" {
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw Support.failed("Export restart needs fresh evidence.") }
            context = try await Support.make(directory: directory, scale: scale, seconds: 8, portrait: false, name: "export-recovery-prepare")
        } else {
            context = try await Support.open(package: directory.appendingPathComponent("Export source.ngv"), directory: directory,
                scale: scale, name: "export-recovery-resume")
        }
        defer { context.document.close() }
        do {
            try await Support.workspace(context)
            if stage == "prepare" { try await prepare(context); throw Support.failed("The stopped export process must be terminated by its native acceptance runner.") }
            try await resume(context)
            guard let bounds = context.window.contentView?.bounds else { throw Support.failed("The reopened export window disappeared.") }
            return ["directory": directory.lastPathComponent, "stage": stage, "processID": ProcessInfo.processInfo.processIdentifier,
                "viewport": [bounds.width, bounds.height], "effectiveScale": scale,
                "interactions": context.driver.interactions, "screenshots": context.driver.screenshots]
        } catch { context.driver.failure(error); throw error }
    }

    private static func prepare(_ context: Support.Context) async throws {
        let queue = ExportQueue.shared, driver = context.driver, window = context.window
        try await Support.select("export.resolution", title: "720p", in: window, driver: driver)
        await ExportCoordinator.acquireExport()
        var holdsSlot = true
        defer { if holdsSlot { ExportCoordinator.endExport() } }
        let firstOutput = context.directory.appendingPathComponent("Completed before restart.mp4")
        let cancelled = try await Support.start(firstOutput, context: context)
        guard cancelled.status == .pending else { throw Support.failed("The real shared export slot did not hold the prepared request.") }
        try await driver.click("export.history." + cancelled.id, in: window)
        try await driver.click("export.job.\(cancelled.id).cancel", in: window)
        try await driver.wait("native export cancellation persisted") { cancelled.status == .cancelled }
        guard !FileManager.default.fileExists(atPath: firstOutput.path), queue.canRetry(jobID: cancelled.id) else { throw Support.failed("Cancel published a file or lost its bound retry source.") }
        try Support.recordJob(cancelled, context: context, name: "cancelled")
        try driver.capture("cancelled-no-output", target: window)
        let before = Set(queue.jobs(ownerKey: context.editor.openWorkingCopyKey).map(\.id))
        try await driver.click("export.job.\(cancelled.id).retry", in: window)
        try await driver.wait("native retry creates a distinct bound request") { queue.jobs(ownerKey: context.editor.openWorkingCopyKey).contains { !before.contains($0.id) } }
        let added = queue.jobs(ownerKey: context.editor.openWorkingCopyKey).filter { !before.contains($0.id) }
        guard added.count == 1, let completed = added.first, completed.status == .pending, completed.destinationURL == firstOutput else { throw Support.failed("Native Retry did not preserve its actual destination.") }
        ExportCoordinator.endExport(); holdsSlot = false
        try await Support.complete(completed, context: context)
        try Support.recordJob(completed, context: context, name: "completed-before-restart")
        guard let completedSHA = completed.outputSHA256 else { throw Support.failed("The completed export has no output proof.") }
        try driver.capture("retry-completed", target: window)

        try await Support.select("export.resolution", title: "4K", in: window, driver: driver)
        await ExportCoordinator.acquireExport(); holdsSlot = true
        let destination = context.directory.appendingPathComponent("Interrupted film.mp4")
        let interrupted = try await Support.start(destination, context: context)
        guard interrupted.status == .pending else { throw Support.failed("The restart request is not actually queued.") }
        try await Support.save(context)
        for workspace in [EditorViewModel.WorkspaceFocus.media, .production, .postproduction, .edit, .export] {
            try await NativeEditingOwnerAcceptance.workspace(workspace, editor: context.editor, window: window, driver: driver)
            try await driver.click("production.export", in: window)
            try await driver.wait("actual export fly-out opens") {
                NSApp.windows.contains { $0.isVisible && driver.text("production.export.title", in: $0) == interrupted.title }
            }
            let flyouts = NSApp.windows.filter { $0.isVisible && driver.text("production.export.title", in: $0) == interrupted.title }
            guard flyouts.count == 1, let flyout = flyouts.first else { throw Support.failed("The actual export fly-out is not unique.") }
            flyout.makeKeyAndOrderFront(nil)
            try await driver.wait("actual export fly-out shows this job") {
                flyout.isKeyWindow && driver.text("production.export.state", in: flyout) == "pending"
            }
            try driver.visible(["production.export.title", "production.export.state", "production.export.open"], in: flyout)
            try driver.capture("pending-export-" + workspace.rawValue, target: flyout)
            try await driver.click("production.export.open", in: flyout)
            try await driver.wait("actual fly-out returns to export workspace") { context.editor.workspaceFocus == .export && window.isKeyWindow }

        }
        try await driver.click("production.export", in: window)
        try await driver.wait("encoding progress fly-out opens") {
            NSApp.windows.contains { $0.isVisible && driver.text("production.export.title", in: $0) == interrupted.title }
        }
        guard let flyout = NSApp.windows.first(where: { $0.isVisible && driver.text("production.export.title", in: $0) == interrupted.title }) else {
            throw Support.failed("The actual encoding progress fly-out disappeared.")
        }
        flyout.makeKeyAndOrderFront(nil)
        try await driver.wait("encoding fly-out receives focus") { flyout.isKeyWindow }
        ExportCoordinator.endExport(); holdsSlot = false
        try await driver.wait("real encoder progress before process interruption", seconds: 60) {
            interrupted.status == .exporting && interrupted.progress > 0 && interrupted.progress < 1
                && driver.text("production.export.state", in: flyout) == "exporting"
                && Double(driver.text("production.export.progress", in: flyout) ?? "") == interrupted.progress
        }
        try driver.visible(["production.export.title", "production.export.state", "production.export.progress"], in: flyout)
        try driver.capture("encoding-before-process-stop", target: flyout)
        guard let owner = context.editor.openWorkingCopyKey, let home = context.editor.workingRoot,
              interrupted.status == .exporting, interrupted.progress > 0, interrupted.progress < 1,
              !FileManager.default.fileExists(atPath: destination.path) else { throw Support.failed("The actual export passed its interruption boundary before capture.") }
        let root = try ExportDataRoot.resolve(in: home)
        let currentURL = try ProjectLocalFile.resolve("delivery/jobs/\(interrupted.id)/current.v1.json", dataRoot: root)
        let attempt = try JSONDecoder().decode(DeliveryAttemptV1.self, from: Data(contentsOf: currentURL))
        try DeliveryValidatorV1.validate(attempt: attempt)
        guard attempt.id == interrupted.id, attempt.status == .running, attempt.outputSHA256 == nil,
              attempt.spec.width == 3840, attempt.spec.height == 2160 else { throw Support.failed("The running delivery lacks its genuine persisted attempt.") }
        let partial = ExportQueue.DestinationBinding.makeTemporaryURL(url: destination, jobID: interrupted.id)
        let snapshot = ExportQueue.SourceBinding.snapshotRoot(jobID: interrupted.id)
        guard FileManager.default.fileExists(atPath: partial.path), FileManager.default.fileExists(atPath: snapshot.path) else {
            throw Support.failed("The real export has no partial output and frozen sources to recover.")
        }
        let state = Saved(processID: ProcessInfo.processInfo.processIdentifier, ownerKey: owner, interruptedID: interrupted.id,
            completedID: completed.id, completedSHA256: completedSHA, timelineSHA256: try ExportArtwork.timelineHash(context.editor.timeline),
            output: destination.lastPathComponent, partial: partial.lastPathComponent, snapshotRoot: snapshot.path, progress: interrupted.progress)
        try JSONEncoder().encode(attempt).write(to: context.directory.appendingPathComponent("running-attempt.json"), options: .atomic)
        try JSONEncoder().encode(state).write(to: context.directory.appendingPathComponent("restart-state.json"), options: .atomic)
        try driver.record("real encoder interrupted before publication", fields: ["jobID": interrupted.id, "processID": state.processID,
            "progress": state.progress, "partialExists": true, "snapshotExists": true, "published": false])
        try Data("ready\n".utf8).write(to: context.directory.appendingPathComponent("process-stop-ready"), options: .atomic)
        raise(SIGSTOP)
    }

    private static func resume(_ context: Support.Context) async throws {
        let state = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: context.directory.appendingPathComponent("restart-state.json")))
        let queue = ExportQueue.shared, driver = context.driver, window = context.window
        guard state.processID != ProcessInfo.processInfo.processIdentifier,
              state.ownerKey == context.editor.openWorkingCopyKey, let home = context.editor.workingRoot,
              try ExportArtwork.timelineHash(context.editor.timeline) == state.timelineSHA256 else { throw Support.failed("The restart did not reopen the same actual project in a new process.") }
        try await driver.wait("persisted interruption is visible") {
            driver.text("export.history." + state.interruptedID, in: window) == "interrupted"
        }
        guard let interrupted = queue.jobs(ownerKey: state.ownerKey).first(where: { $0.id == state.interruptedID }),
              let completed = queue.jobs(ownerKey: state.ownerKey).first(where: { $0.id == state.completedID }),
              completed.status == .completed, completed.outputSHA256 == state.completedSHA256,
              interrupted.status == .interrupted, !interrupted.canCancel, !interrupted.canReveal, !queue.canRetry(jobID: interrupted.id),
              queue.activeJob(ownerKey: state.ownerKey) == nil else { throw Support.failed("Restart lost completion history or automatically resumed an interrupted export.") }
        try await driver.click("export.history." + interrupted.id, in: window)
        let ids = ["cancel", "retry", "reveal"].map { "export.job.\(interrupted.id)." + $0 }
        for id in ids {
            try await driver.reveal(id, in: window)
            guard driver.state(id, in: window) == false else { throw Support.failed("An interrupted-history action falsely appears executable.") }
        }
        try await driver.reveal("export.job.failure", in: window)
        guard driver.text("export.job.failure", in: window) == "Export interrupted before completion." else { throw Support.failed("The unfinished output is not honestly explained.") }
        let destination = context.directory.appendingPathComponent(state.output)
        guard !FileManager.default.fileExists(atPath: destination.path),
              !FileManager.default.fileExists(atPath: context.directory.appendingPathComponent(state.partial).path),
              !FileManager.default.fileExists(atPath: state.snapshotRoot),
              try FileDigest.sha256(of: context.directory.appendingPathComponent("Completed before restart.mp4")) == state.completedSHA256 else {
            throw Support.failed("Restart retained a partial output or damaged the previously completed file.")
        }
        try Support.recordJob(interrupted, context: context, name: "interrupted-after-restart")
        try driver.capture("honest-interrupted-history", target: window)
        try driver.record("real process restart recovered interrupted export", fields: ["previousProcessID": state.processID,
            "processID": ProcessInfo.processInfo.processIdentifier, "jobID": interrupted.id, "completedID": completed.id,
            "completedSHA256": state.completedSHA256, "partialExists": false, "snapshotExists": false, "published": false])
        try await Support.select("export.resolution", title: "720p", in: window, driver: driver)
        let newJob = try await Support.start(destination, context: context)
        guard newJob.id != interrupted.id else { throw Support.failed("The explicit new export reused the interrupted job identity.") }
        try await Support.complete(newJob, context: context)
        try Support.recordJob(newJob, context: context, name: "explicit-new-export")
        let evidence = context.directory.appendingPathComponent("restarted-decoded")
        let probe = try await Task.detached { try await Support.decode(destination, evidence: evidence) }.value
        guard probe.frames.count == 192, probe.width == 1280, probe.height == 720, probe.fps == 24, abs(probe.duration - 8) < 0.05,
              queue.jobs(ownerKey: state.ownerKey).first(where: { $0.id == interrupted.id })?.status == .interrupted else {
            throw Support.failed("The explicit new export changed the film or relabelled its interrupted predecessor.")
        }
        try driver.capture("explicit-new-export-verified", target: window)
        try await Support.save(context)
    }
}
