import AppKit
import CoreFoundation

@MainActor
final class NexGenVideoApplication: NSApplication {
    private var terminating = false
    var terminationReplyPending = false

    override func terminate(_ sender: Any?) {
        // A second AppKit terminate bypasses the delegate while terminateLater is pending.
        guard !terminating, !terminationReplyPending else { return }
        terminating = true
        defer { terminating = false }
        super.terminate(sender)
    }
}

@MainActor
enum AppTermination {
    private static var scheduled = false

    @discardableResult
    // AppKit can return during document review; cancellation callbacks require review to finish first.
    static func request(onCancelled: @escaping @MainActor @Sendable () -> Void = {}) -> Bool {
        guard !scheduled else { return false }
        scheduled = true
        // AppKit's terminateLater loop must run outside a main-queue callout.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
                scheduled = false
                onCancelled()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        return true
    }
}
