import AppKit
import Darwin
import SwiftUI

@MainActor
enum ExportActionsSelfTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["NGV_EXPORT_ACTIONS_SELFTEST"] == "1"
    }

    private(set) static var revealedURL: URL?

    static func recordReveal(_ url: URL) {
        guard isRequested else { return }
        revealedURL = url.standardizedFileURL
    }

    static func runIfRequested() async {
        guard isRequested else { return }
        do {
            try await run()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func run() async throws {
        guard let evidencePath = ProcessInfo.processInfo.environment[
            "NGV_EXPORT_ACTIONS_SELFTEST_OUTPUT"
        ], !evidencePath.isEmpty else {
            throw ToolError("NGV_EXPORT_ACTIONS_SELFTEST_OUTPUT is required.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "export-actions-selftest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Actions.ngv", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONEncoder().encode(Timeline()).write(
            to: package.appendingPathComponent(Project.timelineFilename)
        )
        try JSONEncoder().encode(MediaManifest()).write(
            to: package.appendingPathComponent(Project.manifestFilename)
        )
        try JSONEncoder().encode(GenerationLog()).write(
            to: package.appendingPathComponent(Project.generationLogFilename)
        )
        _ = try ProjectIdentity.uuid(for: package)

        let editor = EditorViewModel()
        editor.projectURL = package
        guard let ownerKey = editor.openWorkingCopyKey else {
            throw ToolError("The native export self-test project did not open.")
        }
        let queue = ExportQueue.shared
        let completedURL = root.appendingPathComponent("completed.xml")
        let completed = try await queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: completedURL,
            projectName: "Actions"
        )
        let completedResult = await queue.waitForCompletion(jobID: completed.id)
        guard completedResult?.status == .completed else {
            throw ToolError("The native export self-test could not prepare a completed job.")
        }

        await ExportCoordinator.acquireExport()
        var gateHeld = true
        defer {
            if gateHeld { ExportCoordinator.endExport() }
            queue.cancelAll(ownerKey: ownerKey)
            editor.releaseWorkingCopy()
        }
        let cancellable = try await queue.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: root.appendingPathComponent("cancel.xml"),
            projectName: "Actions"
        )

        let host = NSHostingController(rootView: ExportView().environment(editor))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(AppTheme.ComponentSize.exportWindow)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        _ = try await verifyActions(for: [completed, cancellable], window: window)

        let initialCount = queue.jobs(ownerKey: ownerKey).count
        var disabledActionChecks = 0
        if try await click(job: completed, action: "cancel", window: window) == false {
            disabledActionChecks += 1
        }
        if try await click(job: completed, action: "retry", window: window) == false {
            disabledActionChecks += 1
        }
        await settleActions()
        guard completed.status == .completed,
              queue.jobs(ownerKey: ownerKey).count == initialCount else {
            throw ToolError("Completed-job disabled actions changed queue state.")
        }

        if try await click(job: cancellable, action: "retry", window: window) == false {
            disabledActionChecks += 1
        }
        if try await click(job: cancellable, action: "reveal", window: window) == false {
            disabledActionChecks += 1
        }
        guard cancellable.status == .pending,
              queue.jobs(ownerKey: ownerKey).count == initialCount,
              revealedURL == nil else {
            throw ToolError("Pending-job disabled actions changed queue state.")
        }
        _ = try await click(job: cancellable, action: "cancel", window: window)
        guard await waitUntil(timeout: .seconds(2), { cancellable.status == .cancelled }) else {
            throw ToolError("The visible Cancel action did not cancel its bound job.")
        }

        if try await click(job: cancellable, action: "cancel", window: window) == false {
            disabledActionChecks += 1
        }
        if try await click(job: cancellable, action: "reveal", window: window) == false {
            disabledActionChecks += 1
        }
        await settleActions()
        guard cancellable.status == .cancelled,
              queue.jobs(ownerKey: ownerKey).count == initialCount,
              revealedURL == nil else {
            throw ToolError("Cancelled-job disabled actions changed queue state.")
        }

        _ = try await click(job: completed, action: "reveal", window: window)
        guard await waitUntil(timeout: .seconds(2), {
            revealedURL == completedURL.standardizedFileURL
        }) else {
            throw ToolError("The visible Reveal action did not reveal its bound destination.")
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard await waitUntil(timeout: .seconds(5), {
            window.isVisible && window.isKeyWindow && NSApp.keyWindow === window
        }) else {
            throw ToolError("The export window did not reacquire key status after Finder Reveal.")
        }

        _ = try await click(job: cancellable, action: "retry", window: window)
        guard await waitUntil(timeout: .seconds(2), {
            queue.jobs(ownerKey: ownerKey).count == initialCount + 1
        }), let retried = queue.jobs(ownerKey: ownerKey).first(where: {
            $0.id != cancellable.id && $0.destinationURL == cancellable.destinationURL
        }), retried.status == .pending else {
            throw ToolError("The visible Retry action did not enqueue its bound source.")
        }
        let finalActionChecks = try await verifyActions(
            for: [completed, cancellable, retried],
            window: window
        )

        queue.cancel(jobID: retried.id)
        ExportCoordinator.endExport()
        gateHeld = false
        await queue.waitUntilIdle(ownerKey: ownerKey)
        window.orderOut(nil)

        let evidence: [String: Any] = [
            "ownerKey": ownerKey,
            "completedJobID": completed.id,
            "cancelledJobID": cancellable.id,
            "retriedFromJobID": cancellable.id,
            "retryJobID": retried.id,
            "revealedPath": completedURL.path,
            "cancelStatus": cancellable.status.rawValue,
            "retryStatus": retried.status.rawValue,
            "finalActionChecks": finalActionChecks,
            "disabledActionChecks": disabledActionChecks,
            "finderWindowReacquired": true,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: evidence,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: evidencePath), options: .atomic)
        FileHandle.standardOutput.write(Data("SELFTEST_EXPORT_ACTIONS_OK\n".utf8))
        editor.releaseWorkingCopy()
        exit(0)
    }

    private static func verifyActions(for jobs: [ExportJob], window: NSWindow) async throws -> Int {
        var count = 0
        for job in jobs {
            for action in ["cancel", "retry", "reveal"] {
                try await prepareAction(job: job, action: action, window: window)
                count += 1
            }
        }
        return count
    }

    private static func prepareAction(
        job: ExportJob,
        action: String,
        window: NSWindow
    ) async throws {
        let identifier = "export.job.\(job.id).\(action)"
        var failure = "the native action remained clipped or had no hit target"
        guard await waitUntil(timeout: .seconds(5), {
            if let scrollFailure = AppRelaunchSelfTest.scrollClickProbeToVisible(
                identifier: identifier,
                in: window
            ) {
                failure = scrollFailure
                return false
            }
            failure = "the native action remained clipped or had no hit target"
            return AppRelaunchSelfTest.isClickProbeReady(
                identifier: identifier,
                in: window,
                expectedEnabled: expectedEnabled(job: job, action: action)
            )
        }) else {
            throw ToolError("\(identifier): \(failure)")
        }
    }

    private static func click(
        job: ExportJob,
        action: String,
        window: NSWindow
    ) async throws -> Bool {
        let identifier = "export.job.\(job.id).\(action)"
        try await prepareAction(job: job, action: action, window: window)
        let enabled = expectedEnabled(job: job, action: action)
        if let failure = AppRelaunchSelfTest.postMouseClick(
            identifier: identifier,
            in: window,
            expectedEnabled: enabled
        ) {
            throw ToolError("\(identifier): \(failure)")
        }
        return enabled
    }

    private static func expectedEnabled(job: ExportJob, action: String) -> Bool {
        switch action {
        case "cancel": job.canCancel
        case "retry": ExportQueue.shared.canRetry(jobID: job.id)
        case "reveal": job.canReveal
        default: false
        }
    }

    private static func settleActions() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    private static func waitUntil(
        timeout: Duration,
        _ predicate: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return predicate()
            }
        }
        return predicate()
    }

    private static func fail(_ reason: String) -> Never {
        FileHandle.standardError.write(Data("SELFTEST_EXPORT_ACTIONS_FAIL \(reason)\n".utf8))
        exit(1)
    }
}
