import AppKit
import Foundation

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let output = ProcessInfo.processInfo.environment["NGV_CAPTURE_PROBE_OUTPUT"]!
        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--sample-parent", String(getpid()), output]
        do { try helper.run() } catch { exit(10) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.knownMainThreadWait()
        }
    }

    @inline(never) func knownMainThreadWait() {
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 15)
        NSApp.terminate(nil)
    }
}

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--sample-parent" {
    Thread.sleep(forTimeInterval: 5)
    guard Int32(CommandLine.arguments[2]) == getppid() else { exit(11) }
    let sample = Process()
    sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    sample.arguments = [CommandLine.arguments[2], "3", "-mayDie", "-file", CommandLine.arguments[3]]
    do {
        try sample.run()
        sample.waitUntilExit()
        exit(sample.terminationStatus)
    } catch { exit(12) }
} else {
    let app = NSApplication.shared
    let delegate = ProbeDelegate()
    app.delegate = delegate
    app.run()
}
