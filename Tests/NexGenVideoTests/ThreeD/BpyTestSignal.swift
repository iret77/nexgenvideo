import Foundation

func waitForBpyTestSignal(_ semaphore: DispatchSemaphore, until deadline: DispatchTime) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        Thread {
            continuation.resume(returning: semaphore.wait(timeout: deadline))
        }.start()
    }
}
