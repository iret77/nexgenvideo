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

    private func tool(_ name: String, properties: [String: Value] = [:]) -> MCPProviderClient.DiscoveredTool {
        MCPProviderClient.DiscoveredTool(
            name: name,
            description: nil,
            inputSchema: .object([
                "properties": .object(properties),
                "required": .array(properties.keys.map(Value.string)),
            ])
        )
    }

    @Test func asynchronousJobSubmitsGenerationExactlyOnce() async throws {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ])
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
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ])
        let client = StubClient(responses: [
            "generate_image": [[#"{"result":{"url":"https://output.invalid/anchor.png"}}"#]],
        ])

        let result = try await MCPGenerationExecutor.run(
            generationTool: generate,
            arguments: ["prompt": .string("compiled anchor")],
            tools: [generate, status],
            provider: .higgsfield,
            client: client
        )

        #expect(result.outputURLs == ["https://output.invalid/anchor.png"])
        #expect(await client.calledTools() == ["generate_image"])
    }

    @Test func missingStatusContractFailsBeforeGenerationSubmit() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let client = StubClient(responses: [
            "generate_image": [[#"{"job_id":"orphaned"}"#]],
        ])

        await #expect(throws: (any Error).self) {
            try await MCPGenerationExecutor.run(
                generationTool: generate,
                arguments: ["prompt": .string("compiled anchor")],
                tools: [generate],
                provider: .higgsfield,
                client: client
            )
        }
        #expect(await client.calledTools().isEmpty)
    }

    @Test func repeatedUnknownStatusFailsWithoutResubmitting() async {
        let generate = tool("generate_image", properties: [
            "prompt": .object(["type": .string("string")]),
        ])
        let status = tool("job_status", properties: [
            "job_id": .object(["type": .string("string")]),
        ])
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
}
