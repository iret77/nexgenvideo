import Testing
@testable import NexGenVideo

@MainActor
@Suite("Agent generation cancellation")
struct AgentGenerationCancellationTests {
    @Test("approved upscale cancellation reaches its placeholder exactly once and waits for terminal callback")
    func approvedUpscaleCancellationWaitsForProviderTerminal() async throws {
        let (submissionStarted, submissionStartedContinuation) = AsyncStream<Void>.makeStream()
        let (providerCancellation, providerCancellationContinuation) = AsyncStream<String>.makeStream()
        var submissionContinuation: CheckedContinuation<String, Never>?
        var awaiter: AgentGenerationAwaiter?
        var cancellationCount = 0

        let task = Task { @MainActor in
            try await AgentGenerationAwaiter.waitForSubmission(
                start: { submittedAwaiter in
                    awaiter = submittedAwaiter
                    submissionStartedContinuation.yield()
                    return await withCheckedContinuation { continuation in
                        submissionContinuation = continuation
                    }
                },
                cancel: { placeholderId in
                    cancellationCount += 1
                    providerCancellationContinuation.yield(placeholderId)
                    return true
                }
            )
        }

        var submissionStartedIterator = submissionStarted.makeAsyncIterator()
        _ = await submissionStartedIterator.next()
        task.cancel()
        let submissionContinuation = try #require(submissionContinuation)
        submissionContinuation.resume(returning: "upscale-placeholder")

        var providerCancellationIterator = providerCancellation.makeAsyncIterator()
        let cancelledPlaceholder = await providerCancellationIterator.next()
        #expect(cancelledPlaceholder == "upscale-placeholder")
        #expect(cancellationCount == 1)

        let awaiter = try #require(awaiter)
        #expect(!awaiter.isResolved)
        awaiter.resolve(.succeeded(nil))

        let result = try await task.value
        #expect(result.placeholderId == "upscale-placeholder")
        switch result.completion {
        case .failed(let message):
            #expect(message == "Generation cancelled.")
        case .succeeded:
            Issue.record("cancelled upscale reported success")
        }
        #expect(cancellationCount == 1)
    }
}
