import AppKit
import CoreFoundation

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
