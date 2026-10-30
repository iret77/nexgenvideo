import Foundation

func onBpyTestThread<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: operation()) }.start()
    }
}

func waitForBpyTestSignal(_ semaphore: DispatchSemaphore, until deadline: DispatchTime) async -> DispatchTimeoutResult {
    await onBpyTestThread { semaphore.wait(timeout: deadline) }
}
