import AppKit

enum HangDiagnosticSelfTest {
    static var requested: Bool {
        ProcessInfo.processInfo.environment["NGV_HANG_SELFTEST"] == "wait"
            || ProcessInfo.processInfo.environment["NGV_HANG_SELFTEST"] == "spin"
    }

    @MainActor
    static func start() {
        HangDiagnosticRecorder.shared.start(includeContent: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let spin = ProcessInfo.processInfo.environment["NGV_HANG_SELFTEST"] == "spin"
            let id = HangDiagnosticRecorder.shared.record(spin ? .testSpin : .testWait)
            if spin { knownMainThreadSpin() } else { knownMainThreadWait() }
            HangDiagnosticRecorder.shared.record(spin ? .testSpin : .testWait, correlation: id, end: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.terminate(nil) }
        }
    }

    @inline(never) private static func knownMainThreadWait() {
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 20)
    }

    @inline(never) private static func knownMainThreadSpin() {
        let end = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < end { _ = mach_absolute_time() }
    }
}
