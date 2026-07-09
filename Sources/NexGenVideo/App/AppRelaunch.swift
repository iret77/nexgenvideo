import AppKit

/// Relaunch NexGenVideo cleanly. Needed after a pack update: a loaded `.dylib` can't be unloaded, so
/// the new pack code only goes live in a fresh process. A detached shell waits for this instance to
/// quit, then reopens the app; then we terminate. Non-sandboxed Developer-ID app → Process is allowed.
enum AppRelaunch {
    static func now() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.4; open \"\(bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
