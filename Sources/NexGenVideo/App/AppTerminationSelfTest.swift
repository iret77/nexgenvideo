import AppKit
import Darwin

@MainActor
enum AppTerminationSelfTest {
    nonisolated static var isRequested: Bool {
        ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
            && ProcessInfo.processInfo.environment["NGV_TERMINATION_SELFTEST"] != nil
    }

    nonisolated static func record(_ event: String, childPID: Int32? = nil) {
        guard isRequested,
              let path = ProcessInfo.processInfo.environment["NGV_TERMINATION_EVIDENCE"] else { return }
        var value: [String: Any] = ["event": event, "pid": getpid(), "parentPID": getppid(),
            "uptime": ProcessInfo.processInfo.systemUptime,
            "sourceSHA": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? ""]
        if let childPID { value["childPID"] = childPID }
        guard var bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { _exit(70) }
        bytes.append(0x0A)
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { _exit(70) }
        let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        guard written == bytes.count else { _exit(70) }
    }

    static func cleanupStarted() async {
        record("cleanup-start")
        try? await Task.sleep(for: .milliseconds(100))
        record("cleanup-resumed")
    }

    static func runIfRequested() {
        guard isRequested else { return }
        let mode = ProcessInfo.processInfo.environment["NGV_TERMINATION_SELFTEST"] ?? ""
        guard ["task", "gcd", "modal", "duplicate", "cancel", "relaunch-cancel", "relaunch", "raw-control"].contains(mode) else { exit(64) }
        guard atexit({ AppTerminationSelfTest.record("process-exit") }) == 0 else { exit(70) }
        let application = NSApplication.shared
        guard application is NexGenVideoApplication else { exit(72) }
        application.setActivationPolicy(.prohibited)
        let delegate = Delegate(mode: mode)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
        exit(71)
    }

    @MainActor private final class Delegate: NSObject, NSApplicationDelegate {
        let mode: String
        let production = AppDelegate()
        var cancelled = false
        var duplicateIssued = false

        init(mode: String) { self.mode = mode }

        func applicationDidFinishLaunching(_ notification: Notification) {
            record("boot")
            if CommandLine.arguments.contains("--ngv-termination-reopened") {
                record("reopened")
                AppTermination.request()
            } else if mode == "gcd" {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
                    MainActor.assumeIsolated { self.request() }
                }
            } else {
                Task { @MainActor in
                    await Task.yield()
                    request()
                }
            }
        }

        private func request() {
            if mode == "raw-control" {
                NSApp.terminate(nil)
            } else if mode == "modal" {
                record("modal-start")
                record(AppTermination.request() ? "request-accepted" : "request-rejected")
                let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        record(NSApp.modalWindow != nil ? "modal-active" : "modal-missing")
                        NSApp.stopModal(withCode: .cancel)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                let alert = NSAlert()
                alert.messageText = "Termination modal control"
                alert.runModal()
                timer.invalidate()
                record("modal-returned")
            } else if mode == "relaunch" || mode == "relaunch-cancel" {
                AppRelaunch.now(reopenArguments: ["--ngv-termination-reopened"]) { record("relaunch-commit") }
            } else {
                record(AppTermination.request() ? "request-accepted" : "request-rejected")
                if mode == "duplicate" {
                    record(AppTermination.request() ? "duplicate-accepted" : "duplicate-rejected")
                    DispatchQueue.main.async {
                        record(AppTermination.request() ? "duplicate-accepted" : "duplicate-rejected")
                    }
                }
            }
        }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            record("should-terminate")
            if (mode == "cancel" || mode == "relaunch-cancel"), !cancelled {
                cancelled = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(20))
                    record("cancelled")
                    sender.reply(toApplicationShouldTerminate: false)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(3500))
                        record("alive-after-cancel")
                        AppTermination.request()
                    }
                }
                record("reply-later")
                return .terminateLater
            }
            let reply = production.applicationShouldTerminate(sender)
            switch reply {
            case .terminateNow: record("reply-now")
            case .terminateLater: record("reply-later")
            case .terminateCancel: record("reply-cancel")
            @unknown default: record("reply-unknown")
            }
            if mode == "duplicate", !duplicateIssued {
                duplicateIssued = true
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated {
                        record("native-duplicate")
                        sender.terminate(nil)
                        record("native-duplicate-returned")
                    }
                }
            }
            return reply
        }

        func applicationWillTerminate(_ notification: Notification) {
            production.applicationWillTerminate(notification)
        }
    }
}
