import AppKit

/// Relaunch NexGenVideo cleanly. Needed after a pack update: a loaded `.dylib` can't be unloaded, so
/// the new pack code only goes live in a fresh process. Non-sandboxed Developer-ID app → Process is
/// allowed.
///
/// Save-aware: `NSApp.terminate` runs NSDocument's standard unsaved-changes review (Save / Don't Save
/// / Cancel), so the user never loses work. The reopener is registered on `willTerminate` and only
/// fires once the app ACTUALLY quits — so cancelling the save review leaves no second instance behind.
@MainActor
enum AppRelaunch {
    /// Arm the reopener exactly once: if the user Cancels the save review, `willTerminate` never
    /// fires and the observer lingers — a second Restart tap would otherwise stack observers and
    /// spawn multiple `open`s on the eventual quit.
    private static var armed = false

    static func now() {
        if !armed {
            armed = true
            let bundlePath = Bundle.main.bundlePath
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/sh")
                task.arguments = ["-c", "sleep 0.4; open \"\(bundlePath)\""]
                try? task.run()
            }
        }
        NSApp.terminate(nil)
    }
}
