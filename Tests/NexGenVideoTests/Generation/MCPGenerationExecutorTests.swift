import MCP
import Testing

@testable import NexGenVideo

@Suite("MCP generation execution")
struct MCPGenerationExecutorTests {
    actor StubClient: MCPToolCalling {
        private var responses: [String: [[String]]]
        private var calls: [String] = []

        init(responses: [String: [[String]]]) {
            self.responses = responses
        }

        func callTool(name: String, arguments: [String: Value]) async throws -> [String] {
            calls.append(name)
            guard var queue = responses[name], !queue.isEmpty else {
                throw MCPProviderClient.ClientError.toolFailed("Unexpected call to \(name)")
            }
            let result = queue.removeFirst()
            responses[name] = queue
            return result
        }

        func calledTools() -> [String] { calls }
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

    @Test func undeclaredDirectToolThatReturnsAJobRequestsCancellation() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
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
        let client = StubClient(responses: [
            "generate_image": [[#"{"id":"job-1","status":"queued"}"#]],
            "job_status": [
                [#"{"status":"provider-starting"}"#],
                [#"{"status":"provider-starting"}"#],
                [#"{"status":"provider-starting"}"#],
            ],
        ])

        await #expect(throws: (any Error).self) {
            try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate, status],
                provider: .higgsfield,
                client: client,
                maxPollAttempts: 4,
                pollIntervalNanoseconds: 0
            )
        }
        let calls = await client.calledTools()

        #expect(calls.filter { $0 == "generate_image" }.count == 1)
        #expect(calls.filter { $0 == "job_status" }.count == 3)
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

    @Test func schemaFreeSynchronousToolReturnsRichImageContent() async throws {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let payloads = MCPProviderClient.payloadContents(CallTool.Result(content: [
            .image(
                data: bytes.base64EncodedString(),
                mimeType: "image/png",
                annotations: nil,
                _meta: nil
            ),
        ]))
        let client = StubClient(responses: ["generate_image": [payloads]])

        let result = try await MCPGenerationExecutor.run(
            generationTool: generate,
            arguments: ["prompt": .string("compiled anchor")],
            tools: [generate],
            provider: .higgsfield,
            client: client
        )

        #expect(result.output.inlineMedia == [
            MCPGenerationLifecycle.InlineMedia(data: bytes, mimeType: "image/png"),
        ])
        #expect(await client.calledTools() == ["generate_image"])
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
        let client = StubClient(responses: [
            "generate_image": [[#"{"job_set_id":"paid-job"}"#]],
        ])

        do {
            try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate, status, malformedResult],
                provider: .higgsfield,
                client: client
            )
            Issue.record("Expected lifecycle preflight failure")
        } catch {
            #expect(error.localizedDescription.contains("No job was submitted"))
        }
        #expect(await client.calledTools().isEmpty)
    }
}
