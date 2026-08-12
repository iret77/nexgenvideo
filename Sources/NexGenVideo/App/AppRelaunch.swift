import AppKit
import Darwin
import Dispatch

struct AppRelaunchRequestState {
    enum Completion: Equatable {
        case ignored
        case cancelled
        case proceed
    }

    private(set) var isPending = false

    mutating func begin() -> Bool {
        guard !isPending else { return false }
        isPending = true
        return true
    }

    mutating func complete(approved: Bool) -> Completion {
        guard isPending else { return .ignored }
        isPending = false
        return approved ? .proceed : .cancelled
    }
}

enum AppRelaunchDocumentPolicy {
    static func requiresReview(editStates: [Bool]) -> Bool {
        editStates.contains(true)
    }
}

@MainActor
enum AppRelaunch {
    enum LaunchMode: Equatable {
        case launchServices
        case executable
    }

    enum RelaunchFailure: LocalizedError {
        case requestAlreadyPending
        case appBundleMissing
        case documentsStillEdited
        case reopenerUnavailable

        var errorDescription: String? {
            switch self {
            case .requestAlreadyPending:
                return "A restart is already waiting for confirmation."
            case .appBundleMissing:
                return "The installed NexGenVideo app could not be found."
            case .documentsStillEdited:
                return "NexGenVideo couldn't finish reviewing unsaved documents."
            case .reopenerUnavailable:
                return "macOS could not prepare the app to reopen."
            }
        }
    }

    private static var pendingAction: (() -> Void)?
    private static var pendingOpenArguments: [String] = []
    private static var requestState = AppRelaunchRequestState()
    private static var reopenerTask: Process?

    nonisolated static let gracefulExitTimeout: Duration = .seconds(3)

    nonisolated static func reopenerArguments(
        parentPID: Int32,
        executablePath: String,
        bundlePath: String,
        openArguments: [String] = [],
        launchMode: LaunchMode = .launchServices
    ) -> [String] {
        let applicationArguments = openArguments.first == "--args"
            ? Array(openArguments.dropFirst())
            : openArguments
        let launchCommand: String
        let launchArguments: [String]
        switch launchMode {
        case .launchServices:
            launchCommand = "exec /usr/bin/open -n -a \"$bundle\" \"$@\""
            launchArguments = applicationArguments.isEmpty
                ? []
                : ["--args"] + applicationArguments
        case .executable:
            launchCommand = "exec \"$expected\" \"$@\""
            launchArguments = applicationArguments
        }
        return [
            "-c",
            "parent=\"$1\"; expected=\"$2\"; bundle=\"$3\"; shift 3; "
                + "is_parent() { actual_parent=\"$(/bin/ps -ww -p \"$$\" -o ppid= 2>/dev/null)\"; "
                + "[ \"$actual_parent\" -eq \"$parent\" ] 2>/dev/null || return 1; "
                + "actual=\"$(/bin/ps -ww -p \"$parent\" -o command= 2>/dev/null)\"; "
                + "[ \"$actual\" = \"$expected\" ] && return 0; "
                + "case \"$actual\" in \"$expected \"*) return 0;; *) return 1;; esac; }; "
                + "attempts=0; while is_parent && [ \"$attempts\" -lt 50 ]; do "
                + "attempts=$((attempts + 1)); /bin/sleep 0.1; done; "
                + "if is_parent; then /bin/kill -TERM \"$parent\"; attempts=0; "
                + "while is_parent && [ \"$attempts\" -lt 20 ]; do "
                + "attempts=$((attempts + 1)); /bin/sleep 0.1; done; fi; "
                + "if is_parent; then /bin/kill -KILL \"$parent\"; attempts=0; "
                + "while is_parent && [ \"$attempts\" -lt 20 ]; do "
                + "attempts=$((attempts + 1)); /bin/sleep 0.1; done; fi; "
                + "is_parent && exit 1; " + launchCommand,
            "nexgenvideo-relaunch",
            String(parentPID),
            executablePath,
            bundlePath,
        ] + launchArguments
    }

    static func now(
        reopenArguments: [String] = [],
        beforeRelaunch action: (() -> Void)? = nil
    ) {
        guard requestState.begin() else {
            presentFailure(RelaunchFailure.requestAlreadyPending)
            return
        }
        pendingAction = action
        pendingOpenArguments = AppRelaunchSelfTest.reopenArguments(reopenArguments)
        let editStates = NSDocumentController.shared.documents.map(\.isDocumentEdited)
        guard AppRelaunchDocumentPolicy.requiresReview(editStates: editStates) else {
            documentReviewCompleted(true)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        NSDocumentController.shared.reviewUnsavedDocuments(
            withAlertTitle: nil,
            cancellable: true,
            delegate: AppRelaunchDocumentReview.shared,
            didReviewAllSelector: #selector(
                AppRelaunchDocumentReview.documentController(
                    _:didReviewAll:contextInfo:
                )
            ),
            contextInfo: nil
        )
    }

    fileprivate static func documentReviewCompleted(_ approved: Bool) {
        switch requestState.complete(approved: approved) {
        case .ignored:
            return
        case .cancelled:
            clearRequest()
            return
        case .proceed:
            break
        }

        for document in NSDocumentController.shared.documents where document.isDocumentEdited {
            document.close()
        }
        guard !NSDocumentController.shared.hasEditedDocuments else {
            clearRequest()
            presentFailure(RelaunchFailure.documentsStillEdited)
            return
        }

        let bundlePath = Bundle.main.bundlePath
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            clearRequest()
            presentFailure(RelaunchFailure.appBundleMissing)
            return
        }
        let launchMode = AppRelaunchSelfTest.reopenLaunchMode
        let launchCommandAvailable = launchMode == .executable
            || FileManager.default.isExecutableFile(atPath: "/usr/bin/open")
        guard FileManager.default.isExecutableFile(atPath: "/bin/sh"),
              launchCommandAvailable else {
            clearRequest()
            presentFailure(RelaunchFailure.reopenerUnavailable)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = reopenerArguments(
            parentPID: ProcessInfo.processInfo.processIdentifier,
            executablePath: Bundle.main.executableURL?.path
                ?? ProcessInfo.processInfo.arguments[0],
            bundlePath: bundlePath,
            openArguments: pendingOpenArguments,
            launchMode: launchMode
        )
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            reopenerTask = task
            pendingAction?()
            guard UserDefaults.standard.synchronize() else {
                throw RelaunchFailure.reopenerUnavailable
            }
            clearRequest()
            forceExitIfTerminationStalls()
            NSApp.terminate(nil)
        } catch {
            if task.isRunning {
                task.terminate()
            }
            reopenerTask = nil
            clearRequest()
            Log.app.error("relaunch preparation failed: \(error.localizedDescription)")
            presentFailure(error)
        }
    }

    private static func clearRequest() {
        pendingAction = nil
        pendingOpenArguments = []
    }

    private static func forceExitIfTerminationStalls() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + gracefulExitTimeout.timeInterval
        ) {
            Darwin._exit(EXIT_SUCCESS)
        }
    }

    private static func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "NexGenVideo couldn't restart"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds)
            + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}

@MainActor
private final class AppRelaunchDocumentReview: NSObject {
    static let shared = AppRelaunchDocumentReview()

    @objc func documentController(
        _ documentController: NSDocumentController,
        didReviewAll: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        AppRelaunch.documentReviewCompleted(didReviewAll)
    }
}
