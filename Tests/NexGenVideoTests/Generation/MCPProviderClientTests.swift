import Foundation
import MCP
import Testing

@testable import NexGenVideo

@Suite("MCP provider request cancellation")
struct MCPProviderClientTests {
    private actor CancellationRecorder {
        private(set) var requestIDs: [ID] = []

        func record(_ requestID: ID) {
            requestIDs.append(requestID)
        }
    }

    private struct CancellationFailure: LocalizedError {
        var errorDescription: String? { "protocol transport unavailable" }
    }

    @Test func cancelledAwaitForwardsOriginalRequestExactlyOnce() async {
        let requestID: ID = "provider-request-373"
        let requestTask = Task<String, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return "late result"
        }
        let context = RequestContext(requestID: requestID, requestTask: requestTask)
        let recorder = CancellationRecorder()
        let awaitingTask = Task {
            try await MCPProviderClient.awaitRequest(context) { forwardedID in
                await recorder.record(forwardedID)
                requestTask.cancel()
            }
        }

        awaitingTask.cancel()
        awaitingTask.cancel()

        do {
            _ = try await awaitingTask.value
            Issue.record("Expected the cancelled request await to stop")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await recorder.requestIDs == [requestID])
    }

    @Test func completedAwaitDoesNotSendCancellation() async throws {
        let requestID: ID = "provider-request-complete"
        let context = RequestContext(
            requestID: requestID,
            requestTask: Task<String, Error> { "result" }
        )
        let recorder = CancellationRecorder()

        let result = try await MCPProviderClient.awaitRequest(context) { forwardedID in
            await recorder.record(forwardedID)
        }

        #expect(result == "result")
        #expect(await recorder.requestIDs.isEmpty)
    }

    @Test func successfulProtocolCancellationSettlesWithoutProviderResponse() async {
        let requestID: ID = "provider-request-no-response"
        let requestTask = Task<String, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return "late result"
        }
        defer { requestTask.cancel() }
        let context = RequestContext(requestID: requestID, requestTask: requestTask)
        let recorder = CancellationRecorder()
        let awaitingTask = Task {
            try await MCPProviderClient.awaitRequest(context) { forwardedID in
                await recorder.record(forwardedID)
            }
        }

        awaitingTask.cancel()

        do {
            _ = try await awaitingTask.value
            Issue.record("Expected protocol cancellation to settle the await")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await recorder.requestIDs == [requestID])
    }

    @Test func failedProtocolCancellationSurfacesPossibleCharge() async {
        let requestID: ID = "provider-request-cancel-fails"
        let requestTask = Task<String, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return "late result"
        }
        defer { requestTask.cancel() }
        let context = RequestContext(requestID: requestID, requestTask: requestTask)
        let recorder = CancellationRecorder()
        let awaitingTask = Task {
            try await MCPProviderClient.awaitRequest(context) { forwardedID in
                await recorder.record(forwardedID)
                throw CancellationFailure()
            }
        }

        awaitingTask.cancel()
        awaitingTask.cancel()

        do {
            _ = try await awaitingTask.value
            Issue.record("Expected failed protocol cancellation")
        } catch let error as MCPProviderClient.ClientError {
            #expect(error.localizedDescription.contains("could not be cancelled"))
            #expect(error.localizedDescription.contains("may still run and incur charges"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await recorder.requestIDs == [requestID])
    }
}
