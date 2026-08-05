import AppKit

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
    enum RelaunchFailure: LocalizedError {
        case requestAlreadyPending
        case appBundleMissing
        case reopenerUnavailable

        var errorDescription: String? {
            switch self {
            case .requestAlreadyPending:
                return "A restart is already waiting for confirmation."
            case .appBundleMissing:
                return "The installed NexGenVideo app could not be found."
            case .reopenerUnavailable:
                return "macOS could not prepare the app to reopen."
            }
        }
    }

    private static var pendingAction: (() -> Void)?
    private static var pendingOpenArguments: [String] = []
    private static var requestState = AppRelaunchRequestState()

    nonisolated static func reopenerArguments(
        parentPID: Int32,
        bundlePath: String,
        openArguments: [String] = []
    ) -> [String] {
        [
            "-c",
            "parent=\"$1\"; bundle=\"$2\"; shift 2; "
                + "while kill -0 \"$parent\" 2>/dev/null; do /bin/sleep 0.1; done; "
                + "exec /usr/bin/open \"$bundle\" \"$@\"",
            "nexgenvideo-relaunch",
            String(parentPID),
            bundlePath,
        ] + openArguments
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
        pendingOpenArguments = reopenArguments
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

        let bundlePath = Bundle.main.bundlePath
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            clearRequest()
            presentFailure(RelaunchFailure.appBundleMissing)
            return
        }
        guard FileManager.default.isExecutableFile(atPath: "/bin/sh"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/open") else {
            clearRequest()
            presentFailure(RelaunchFailure.reopenerUnavailable)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = reopenerArguments(
            parentPID: ProcessInfo.processInfo.processIdentifier,
            bundlePath: bundlePath,
            openArguments: pendingOpenArguments
        )
        do {
            try task.run()
            pendingAction?()
            clearRequest()
            NSApp.terminate(nil)
        } catch {
            clearRequest()
            Log.app.error("relaunch preparation failed: \(error.localizedDescription)")
            presentFailure(error)
        }
    }

    private static func clearRequest() {
        pendingAction = nil
        pendingOpenArguments = []
    }

    private static func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "NexGenVideo couldn't restart"
        alert.informativeText = error.localizedDescription
        alert.runModal()
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
