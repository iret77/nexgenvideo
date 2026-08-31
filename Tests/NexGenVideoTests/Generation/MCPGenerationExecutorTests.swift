import Foundation
import MCP
import Testing

@testable import NexGenVideo

@Suite("MCP generation execution")
struct MCPGenerationExecutorTests {
    @MainActor
    private final class DispatchRecorder {
        private(set) var count = 0

        func record() {
            count += 1
        }
    }

    actor StubClient: MCPToolCalling {
        private var responses: [String: [[String]]]
        private var calls: [String] = []
        private let suspendedTools: Set<String>
        private let failures: [String: String]

        init(
            responses: [String: [[String]]],
            suspendedTools: Set<String> = [],
            failures: [String: String] = [:]
        ) {
            self.responses = responses
            self.suspendedTools = suspendedTools
            self.failures = failures
        }

        func callTool(name: String, arguments: [String: Value]) async throws -> [String] {
            calls.append(name)
            if suspendedTools.contains(name) {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            if let failure = failures[name] {
                throw MCPProviderClient.ClientError.toolFailed(failure)
            }
            guard var queue = responses[name], !queue.isEmpty else {
                throw MCPProviderClient.ClientError.toolFailed("Unexpected call to \(name)")
            }
            let result = queue.removeFirst()
            responses[name] = queue
            return result
        }

        func calledTools() -> [String] { calls }
    }

    private func waitForCall(_ name: String, client: StubClient) async -> Bool {
        for _ in 0..<400 {
            let calls = await client.calledTools()
            if calls.contains(name) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private var mediaOutputSchema: Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "result": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "url": .object(["type": .string("string")]),
                    ]),
                ]),
            ]),
        ])
    }

    private func tool(
        _ name: String,
        properties: [String: Value] = [:],
        outputSchema: Value? = nil
    ) -> MCPProviderClient.DiscoveredTool {
        MCPProviderClient.DiscoveredTool(
            name: name,
            description: nil,
            inputSchema: .object([
                "properties": .object(properties),
                "required": .array(properties.keys.map(Value.string)),
            ]),
            outputSchema: outputSchema
        )
    }

    @Test @MainActor func submissionCallbackRequiresSuccessfulGenerationDispatch() async throws {
        let generate = tool(
            "generate_image",
            properties: ["prompt": .object(["type": .string("string")])],
            outputSchema: mediaOutputSchema
        )
        let failedDispatch = DispatchRecorder()
        let failingClient = StubClient(
            responses: [:],
            failures: ["generate_image": "connection failed before dispatch"]
        )

        do {
            _ = try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate],
                provider: .higgsfield,
                client: failingClient,
                onSubmissionDispatched: { failedDispatch.record() }
            )
            Issue.record("Expected the pre-dispatch failure")
        } catch {
            #expect(error.localizedDescription.contains("connection failed before dispatch"))
        }
        #expect(failedDispatch.count == 0)

        let successfulDispatch = DispatchRecorder()
        let successfulClient = StubClient(responses: [
            "generate_image": [[#"{"result":{"url":"https://output.invalid/direct.png"}}"#]],
        ])
        let result = try await MCPGenerationExecutor.run(
            generationTool: generate,
            arguments: ["prompt": .string("compiled anchor")],
            tools: [generate],
            provider: .higgsfield,
            client: successfulClient,
            onSubmissionDispatched: { successfulDispatch.record() }
        )

        #expect(result.outputURLs == ["https://output.invalid/direct.png"])
        #expect(successfulDispatch.count == 1)
    }

    @Test func asynchronousJobSubmitsGenerationExactlyOnce() async throws {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ], outputSchema: mediaOutputSchema)
        let client = StubClient(responses: [
            "generate_image": [[#"{"job_id":"job-1","status":"queued"}"#]],
            "job_status": [
                [#"{"job_id":"job-1","status":"running"}"#],
                [#"{"job_id":"job-1","status":"completed","result":{"url":"https://output.invalid/anchor.png"}}"#],
            ],
        ])

        let result = try await MCPGenerationExecutor.run(
            generationTool: generate,
            arguments: ["prompt": .string("compiled anchor")],
            tools: [generate, status],
            provider: .higgsfield,
            client: client,
            maxPollAttempts: 3,
            pollIntervalNanoseconds: 0
        )
        let calls = await client.calledTools()

        #expect(result.jobID == "job-1")
        #expect(result.outputURLs == ["https://output.invalid/anchor.png"])
        #expect(calls == ["generate_image", "job_status", "job_status"])
        #expect(calls.filter { $0 == "generate_image" }.count == 1)
    }

    @Test func declaredStatusOutputReturnsMediaFromCompletedStatus() async throws {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ], outputSchema: mediaOutputSchema)
        let client = StubClient(responses: [
            "generate_image": [[#"{"job_id":"status-only","status":"queued"}"#]],
            "job_status": [[#"{"job_id":"status-only","status":"completed","result":{"url":"https://output.invalid/status.png"}}"#]],
        ])

        let result = try await MCPGenerationExecutor.run(
            generationTool: generate,
            arguments: ["prompt": .string("compiled anchor")],
            tools: [generate, status],
            provider: .higgsfield,
            client: client,
            maxPollAttempts: 1,
            pollIntervalNanoseconds: 0
        )

        #expect(result.outputURLs == ["https://output.invalid/status.png"])
        #expect(await client.calledTools() == ["generate_image", "job_status"])
    }

    @Test func statusOnlyLifecycleFailsExplicitlyWhenCompletionHasNoMedia() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ], outputSchema: mediaOutputSchema)
        let client = StubClient(responses: [
            "generate_image": [[#"{"job_id":"empty-status","status":"queued"}"#]],
            "job_status": [[#"{"job_id":"empty-status","status":"completed"}"#]],
        ])

        do {
            try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate, status],
                provider: .higgsfield,
                client: client,
                maxPollAttempts: 1,
                pollIntervalNanoseconds: 0
            )
            Issue.record("Expected completed status without media to fail")
        } catch {
            #expect(error.localizedDescription.contains("completed job 'empty-status' without output media"))
        }
        #expect(await client.calledTools() == ["generate_image", "job_status"])
    }

    @Test func completedStatusWithoutMediaFallsBackToCompatibleResultTool() async throws {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ])
        let resultTool = tool("job_result", properties: [
            "job_id": .object(["type": .string("string")]),
        ])
        let client = StubClient(responses: [
            "generate_image": [[#"{"job_id":"fallback-result","status":"queued"}"#]],
            "job_status": [[#"{"job_id":"fallback-result","status":"completed"}"#]],
            "job_result": [[#"{"result":{"url":"https://output.invalid/result.png"}}"#]],
        ])

        let result = try await MCPGenerationExecutor.run(
            generationTool: generate,
            arguments: ["prompt": .string("compiled anchor")],
            tools: [generate, status, resultTool],
            provider: .higgsfield,
            client: client,
            maxPollAttempts: 1,
            pollIntervalNanoseconds: 0
        )

        #expect(result.outputURLs == ["https://output.invalid/result.png"])
        #expect(await client.calledTools() == [
            "generate_image", "job_status", "job_result",
        ])
    }

    @Test func synchronousOutputDoesNotPollOrResubmit() async throws {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
            "wait": .object(["type": .string("boolean")]),
        ])
        let client = StubClient(responses: [
            "generate_image": [[#"{"job_id":"completed-1","result":{"url":"https://output.invalid/anchor.png"}}"#]],
        ])

        let result = try await MCPGenerationExecutor.run(
            generationTool: generate,
            arguments: ["prompt": .string("compiled anchor"), "wait": .bool(true)],
            tools: [generate],
            provider: .higgsfield,
            client: client
        )

        #expect(result.jobID == "completed-1")
        #expect(result.outputURLs == ["https://output.invalid/anchor.png"])
        #expect(await client.calledTools() == ["generate_image"])
    }

    @Test func rootURLDeclaredByOutputSchemaCompletesSynchronously() async throws {
        let rootURLSchema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object(["type": .string("string")]),
            ]),
        ])
        let generate = tool(
            "generate_image",
            properties: ["prompt": .object(["type": .string("string")])],
            outputSchema: rootURLSchema
        )
        let client = StubClient(responses: [
            "generate_image": [[#"{"url":"https://output.invalid/root.png"}"#]],
        ])

        let result = try await MCPGenerationExecutor.run(
            generationTool: generate,
            arguments: ["prompt": .string("compiled anchor")],
            tools: [generate],
            provider: .higgsfield,
            client: client
        )

        #expect(result.outputURLs == ["https://output.invalid/root.png"])
        #expect(await client.calledTools() == ["generate_image"])
    }

    @Test func metadataURLSchemaIsRejectedBeforePaidSubmission() async {
        let metadataSchema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "metadata": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "url": .object(["type": .string("string")]),
                    ]),
                ]),
            ]),
        ])
        let generate = tool(
            "generate_image",
            properties: ["prompt": .object(["type": .string("string")])],
            outputSchema: metadataSchema
        )
        let client = StubClient(responses: [
            "generate_image": [[#"{"metadata":{"url":"https://provider.invalid/jobs/1"}}"#]],
        ])

        do {
            _ = try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate],
                provider: .higgsfield,
                client: client
            )
            Issue.record("Expected metadata-only output schema to fail preflight")
        } catch {
            #expect(error.localizedDescription.contains("No job was submitted"))
        }
        #expect(await client.calledTools().isEmpty)
    }

    @Test func declaredDirectToolThatReturnsAJobRequestsCancellation() async {
        let generate = tool(
            "generate_image",
            properties: ["prompt": .object(["type": .string("string")])],
            outputSchema: mediaOutputSchema
        )
        let client = StubClient(responses: [
            "generate_image": [[#"{"job_id":"orphaned"}"#]],
        ])

        do {
            try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate],
                provider: .higgsfield,
                client: client
            )
            Issue.record("Expected an unpollable accepted-job failure")
        } catch let error as MCPGenerationExecutor.JobFailure {
            #expect(error.jobID == "orphaned")
            #expect(error.message.contains("may still charge"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await client.calledTools() == ["generate_image"])
    }

    @Test func synchronousContractReturningAsyncJobRequestsCancellation() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
            "wait": .object(["type": .string("boolean")]),
        ])
        let cancel = tool("job_cancel", properties: [
            "job_id": .object(["type": .string("string")]),
        ])
        let client = StubClient(responses: [
            "generate_image": [[#"{"job_id":"cancel-me"}"#]],
            "job_cancel": [[#"{"status":"cancelled"}"#]],
        ])

        do {
            try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor"), "wait": .bool(true)],
                tools: [generate, cancel],
                provider: .higgsfield,
                client: client
            )
            Issue.record("Expected a synchronous-contract failure")
        } catch let error as MCPGenerationExecutor.JobFailure {
            #expect(error.jobID == "cancel-me")
            #expect(error.message.contains("sent a cancellation request"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await client.calledTools() == ["generate_image", "job_cancel"])
    }

    @Test func queuedSubmissionURLDoesNotBypassLifecyclePolling() async throws {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ], outputSchema: mediaOutputSchema)
        let client = StubClient(responses: [
            "generate_image": [[#"{"job_id":"job-queued","status":"queued","result":{"url":"https://output.invalid/placeholder.png"}}"#]],
            "job_status": [[#"{"job_id":"job-queued","status":"completed","result":{"url":"https://output.invalid/final.png"}}"#]],
        ])

        let result = try await MCPGenerationExecutor.run(
            generationTool: generate,
            arguments: ["prompt": .string("compiled anchor")],
            tools: [generate, status],
            provider: .higgsfield,
            client: client,
            maxPollAttempts: 1,
            pollIntervalNanoseconds: 0
        )

        #expect(result.outputURLs == ["https://output.invalid/final.png"])
        #expect(await client.calledTools() == ["generate_image", "job_status"])
    }

    @Test func malformedAdvertisedStatusDoesNotBlockSynchronousOutput() async throws {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
            "wait": .object(["type": .string("boolean")]),
        ])
        let malformedStatus = tool("job_status", properties: [
            "tenant_id": .object(["type": .string("string")]),
        ])
        let client = StubClient(responses: [
            "generate_image": [[#"{"result":{"url":"https://output.invalid/direct.png"}}"#]],
        ])

        let result = try await MCPGenerationExecutor.run(
            generationTool: generate,
            arguments: ["prompt": .string("compiled anchor"), "wait": .bool(true)],
            tools: [generate, malformedStatus],
            provider: .higgsfield,
            client: client
        )

        #expect(result.outputURLs == ["https://output.invalid/direct.png"])
        #expect(await client.calledTools() == ["generate_image"])
    }

    @Test func malformedAdvertisedStatusFailsBeforeAsynchronousSubmit() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let malformedStatus = tool("job_status", properties: [
            "tenant_id": .object(["type": .string("string")]),
        ])
        let client = StubClient(responses: [
            "generate_image": [[#"{"job_id":"cancel-malformed"}"#]],
        ])

        do {
            try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate, malformedStatus],
                provider: .higgsfield,
                client: client
            )
            Issue.record("Expected an unpollable job failure")
        } catch {
            #expect(error.localizedDescription.contains("No job was submitted"))
        }
        #expect(await client.calledTools().isEmpty)
    }

    @Test func repeatedUnknownStatusFailsWithoutResubmitting() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ], outputSchema: mediaOutputSchema)
        let cancel = tool("job_cancel", properties: [
            "job_id": .object(["type": .string("string")]),
        ])
        let client = StubClient(responses: [
            "generate_image": [[#"{"id":"job-1","status":"queued"}"#]],
            "job_status": [
                [#"{"status":"provider-starting"}"#],
                [#"{"status":"provider-starting"}"#],
                [#"{"status":"provider-starting"}"#],
            ],
            "job_cancel": [[#"{"status":"cancelled"}"#]],
        ])

        await #expect(throws: (any Error).self) {
            try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate, status, cancel],
                provider: .higgsfield,
                client: client,
                maxPollAttempts: 4,
                pollIntervalNanoseconds: 0
            )
        }
        let calls = await client.calledTools()

        #expect(calls.filter { $0 == "generate_image" }.count == 1)
        #expect(calls.filter { $0 == "job_status" }.count == 3)
        #expect(calls.filter { $0 == "job_cancel" }.count == 1)
    }

    @Test func pollingTimeoutCancelsAcceptedJobExactlyOnce() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ], outputSchema: mediaOutputSchema)
        let cancel = tool("job_cancel", properties: [
            "job_id": .object(["type": .string("string")]),
        ])
        let client = StubClient(responses: [
            "generate_image": [[#"{"job_id":"timed-out","status":"queued"}"#]],
            "job_cancel": [[#"{"status":"cancelled"}"#]],
        ])

        do {
            _ = try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate, status, cancel],
                provider: .higgsfield,
                client: client,
                maxPollAttempts: 1,
                pollIntervalNanoseconds: 0,
                timeoutSeconds: 0
            )
            Issue.record("Expected polling timeout")
        } catch let error as MCPGenerationExecutor.JobFailure {
            #expect(error.jobID == "timed-out")
            #expect(error.message.contains("did not finish"))
            #expect(error.message.contains("sent a cancellation request"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.calledTools() == ["generate_image", "job_cancel"])
    }

    @Test func statusTransportFailureCancelsAcceptedJobExactlyOnce() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ], outputSchema: mediaOutputSchema)
        let cancel = tool("job_cancel", properties: [
            "job_id": .object(["type": .string("string")]),
        ])
        let client = StubClient(
            responses: [
                "generate_image": [[#"{"job_id":"status-error","status":"queued"}"#]],
                "job_cancel": [[#"{"status":"cancelled"}"#]],
            ],
            failures: ["job_status": "status transport unavailable"]
        )

        do {
            _ = try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate, status, cancel],
                provider: .higgsfield,
                client: client,
                maxPollAttempts: 1,
                pollIntervalNanoseconds: 0
            )
            Issue.record("Expected status transport failure")
        } catch let error as MCPGenerationExecutor.JobFailure {
            #expect(error.jobID == "status-error")
            #expect(error.message.contains("status transport unavailable"))
            #expect(error.message.contains("sent a cancellation request"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.calledTools() == [
            "generate_image", "job_status", "job_cancel",
        ])
    }

    @Test func terminalProviderFailureOrCancellationDoesNotInvokeCancellation() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ], outputSchema: mediaOutputSchema)
        let cancel = tool("job_cancel", properties: [
            "job_id": .object(["type": .string("string")]),
        ])
        for terminalStatus in ["failed", "cancelled"] {
            let jobID = "provider-\(terminalStatus)"
            let client = StubClient(responses: [
                "generate_image": [["{\"job_id\":\"\(jobID)\",\"status\":\"queued\"}"]],
                "job_status": [["{\"status\":\"\(terminalStatus)\",\"message\":\"provider settled the render\"}"]],
                "job_cancel": [[#"{"status":"cancelled"}"#]],
            ])

            do {
                _ = try await MCPGenerationExecutor.run(
                    generationTool: generate,
                    arguments: ["prompt": .string("compiled anchor")],
                    tools: [generate, status, cancel],
                    provider: .higgsfield,
                    client: client,
                    maxPollAttempts: 1,
                    pollIntervalNanoseconds: 0
                )
                Issue.record("Expected terminal provider state \(terminalStatus)")
            } catch let error as MCPGenerationExecutor.JobFailure {
                #expect(error.jobID == jobID)
                #expect(error.message.contains("provider settled the render"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(await client.calledTools() == ["generate_image", "job_status"])
        }
    }

    @Test func taskCancellationCancelsAcceptedJobExactlyOnce() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ], outputSchema: mediaOutputSchema)
        let cancel = tool("job_cancel", properties: [
            "job_id": .object(["type": .string("string")]),
        ])
        let client = StubClient(
            responses: [
                "generate_image": [[#"{"job_id":"cancelled-job","status":"queued"}"#]],
                "job_cancel": [[#"{"status":"cancelled"}"#]],
            ],
            suspendedTools: ["job_status"]
        )
        let task = Task {
            try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate, status, cancel],
                provider: .higgsfield,
                client: client,
                pollIntervalNanoseconds: 0
            )
        }

        #expect(await waitForCall("job_status", client: client))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation to stop the accepted job")
        } catch let error as MCPGenerationExecutor.JobFailure {
            #expect(error.jobID == "cancelled-job")
            #expect(error.message.contains("Generation cancelled"))
            #expect(error.message.contains("sent a cancellation request"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let calls = await client.calledTools()
        #expect(calls == ["generate_image", "job_status", "job_cancel"])
        #expect(calls.filter { $0 == "generate_image" }.count == 1)
        #expect(calls.filter { $0 == "job_cancel" }.count == 1)
    }

    @Test func taskCancellationWithoutCancelToolNeverResubmits() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ], outputSchema: mediaOutputSchema)
        let client = StubClient(
            responses: [
                "generate_image": [[#"{"job_id":"unsupported-cancel","status":"queued"}"#]],
            ],
            suspendedTools: ["job_status"]
        )
        let task = Task {
            try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate, status],
                provider: .higgsfield,
                client: client,
                pollIntervalNanoseconds: 0
            )
        }

        #expect(await waitForCall("job_status", client: client))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation to stop the accepted job")
        } catch let error as MCPGenerationExecutor.JobFailure {
            #expect(error.message.contains("No compatible cancellation tool"))
            #expect(error.message.contains("may still charge"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.calledTools() == ["generate_image", "job_status"])
    }

    @Test func rejectedCancellationDoesNotRetryOrResubmit() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ], outputSchema: mediaOutputSchema)
        let cancel = tool("job_cancel", properties: [
            "job_id": .object(["type": .string("string")]),
        ])
        let client = StubClient(
            responses: [
                "generate_image": [[#"{"job_id":"terminal-job","status":"queued"}"#]],
            ],
            suspendedTools: ["job_status"],
            failures: ["job_cancel": "job is already terminal"]
        )
        let task = Task {
            try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate, status, cancel],
                provider: .higgsfield,
                client: client,
                pollIntervalNanoseconds: 0
            )
        }

        #expect(await waitForCall("job_status", client: client))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation to settle the accepted job")
        } catch let error as MCPGenerationExecutor.JobFailure {
            #expect(error.message.contains("job is already terminal"))
            #expect(error.message.contains("may still charge"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let calls = await client.calledTools()
        #expect(calls == ["generate_image", "job_status", "job_cancel"])
        #expect(calls.filter { $0 == "generate_image" }.count == 1)
        #expect(calls.filter { $0 == "job_cancel" }.count == 1)
    }

    @Test func outputSchemaAllowsSynchronousByDefaultTool() async throws {
        let generate = tool(
            "generate_image",
            properties: ["prompt": .object(["type": .string("string")])],
            outputSchema: mediaOutputSchema
        )
        let client = StubClient(responses: [
            "generate_image": [[#"{"result":{"url":"https://output.invalid/direct.png"}}"#]],
        ])

        let result = try await MCPGenerationExecutor.run(
            generationTool: generate,
            arguments: ["prompt": .string("compiled anchor")],
            tools: [generate],
            provider: .higgsfield,
            client: client
        )

        #expect(result.output.urls == ["https://output.invalid/direct.png"])
        #expect(await client.calledTools() == ["generate_image"])
    }

    @Test func schemaFreeNoStatusToolIsRejectedBeforeSubmission() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let client = StubClient(responses: [:])

        do {
            _ = try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate],
                provider: .higgsfield,
                client: client
            )
            Issue.record("Expected an unproven result path to fail")
        } catch {
            #expect(error.localizedDescription.contains("No job was submitted"))
        }
        #expect(await client.calledTools().isEmpty)
    }

    @Test func unmappableResultToolFailsBeforeSubmission() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_set_id": .object(["type": .string("string")]),
        ])
        let malformedResult = tool("job_display", properties: [
            "tenant_id": .object(["type": .string("string")]),
        ])
        let client = StubClient(responses: [:])

        do {
            try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate, status, malformedResult],
                provider: .higgsfield,
                client: client
            )
            Issue.record("Expected result mapping failure")
        } catch {
            #expect(error.localizedDescription.contains("No job was submitted"))
        }
        #expect(await client.calledTools().isEmpty)
    }
}
