import AppKit
import CoreFoundation
import Dispatch
import Foundation
import Testing

@Test("AppKit host continues after a default-mode CFRunLoop stop")
@MainActor
func appKitHostContinuesAfterDefaultModeStop() async throws {
    try #require(NSApplication.shared.isRunning)
    let resumedOnMain = await withCheckedContinuation {
        (continuation: CheckedContinuation<Bool, Never>) in
        CFRunLoopPerformBlock(CFRunLoopGetMain(), RunLoop.Mode.default.rawValue as CFString) {
            CFRunLoopStop(CFRunLoopGetMain())
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
                continuation.resume(returning: Thread.isMainThread)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    #expect(resumedOnMain)
    #expect(NSApplication.shared.isRunning)
}
