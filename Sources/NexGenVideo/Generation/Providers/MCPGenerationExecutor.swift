import Foundation
import MCP

protocol MCPToolCalling: Sendable {
    func callTool(name: String, arguments: [String: Value]) async throws -> [String]
}

extension MCPProviderClient: MCPToolCalling {}

enum MCPGenerationExecutor {
    struct JobFailure: LocalizedError {
        let jobID: String
        let message: String

        var errorDescription: String? { "Provider job '\(jobID)' failed: \(message)" }
    }

    struct Result: Equatable {
        let jobID: String?
        let outputURLs: [String]
    }

    static func run(
        generationTool: MCPProviderClient.DiscoveredTool,
        arguments: [String: Value],
        tools: [MCPProviderClient.DiscoveredTool],
        provider: GenerationProvider,
        client: any MCPToolCalling,
        maxPollAttempts: Int = 600,
        pollIntervalNanoseconds: UInt64 = 3_000_000_000,
        timeoutSeconds: TimeInterval = 30 * 60
    ) async throws -> Result {
        try preflightLifecycle(tools: tools, provider: provider)
        let payloads = try await client.callTool(
            name: generationTool.name,
            arguments: arguments
        )
        let submission = MCPGenerationLifecycle.submission(from: payloads)
        guard let jobID = submission.jobID else {
            if !submission.outputURLs.isEmpty {
                return Result(jobID: nil, outputURLs: submission.outputURLs)
            }
            throw GenerationBackendError.transport(
                "\(provider.displayName)'s MCP returned neither a job identifier nor output media."
            )
        }
        do {
            let urls = try await poll(
                jobID: jobID,
                provider: provider,
                tools: tools,
                client: client,
                maxAttempts: maxPollAttempts,
                intervalNanoseconds: pollIntervalNanoseconds,
                timeoutSeconds: timeoutSeconds
            )
            return Result(jobID: jobID, outputURLs: urls)
        } catch {
            throw JobFailure(jobID: jobID, message: error.localizedDescription)
        }
    }

    static func preflightLifecycle(
        tools: [MCPProviderClient.DiscoveredTool],
        provider: GenerationProvider
    ) throws {
        guard let statusTool = MCPGenerationLifecycle.statusTool(in: tools) else {
            throw GenerationBackendError.transport(
                "\(provider.displayName)'s MCP exposes no usable job-status tool. The generation request was not sent."
            )
        }
        _ = try MCPGenerationArguments.makeJob(
            jobID: "preflight-job",
            schema: statusTool.inputSchema,
            sync: false
        )
        if let resultTool = MCPGenerationLifecycle.resultTool(in: tools) {
            _ = try MCPGenerationArguments.makeJob(
                jobID: "preflight-job",
                schema: resultTool.inputSchema
            )
        }
    }

    private static func poll(
        jobID: String,
        provider: GenerationProvider,
        tools: [MCPProviderClient.DiscoveredTool],
        client: any MCPToolCalling,
        maxAttempts: Int,
        intervalNanoseconds: UInt64,
        timeoutSeconds: TimeInterval
    ) async throws -> [String] {
        guard let statusTool = MCPGenerationLifecycle.statusTool(in: tools) else {
            throw GenerationBackendError.transport(
                "\(provider.displayName)'s MCP accepted job '\(jobID)' but exposes no job-status tool."
            )
        }
        var unknownStatuses = 0
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        for attempt in 0..<max(1, maxAttempts) {
            try Task.checkCancellation()
            guard Date() < deadline else { break }
            let arguments = try MCPGenerationArguments.makeJob(
                jobID: jobID,
                schema: statusTool.inputSchema,
                sync: false
            )
            let payloads = try await client.callTool(name: statusTool.name, arguments: arguments)
            switch MCPGenerationLifecycle.status(from: payloads) {
            case .pending:
                unknownStatuses = 0
                if attempt + 1 < maxAttempts, intervalNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                }
            case .unknown(let value):
                unknownStatuses += 1
                guard unknownStatuses < 3 else {
                    throw GenerationBackendError.transport(
                        "\(provider.displayName)'s MCP returned an unsupported job status: \(value ?? "<missing>")."
                    )
                }
                if attempt + 1 < maxAttempts, intervalNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                }
            case .failed(let message):
                throw GenerationBackendError.transport(message)
            case .succeeded(let urls) where !urls.isEmpty:
                return urls
            case .succeeded:
                return try await fetchResult(
                    jobID: jobID,
                    provider: provider,
                    tools: tools,
                    client: client
                )
            }
        }
        let minutes = max(1, Int(timeoutSeconds / 60))
        throw GenerationBackendError.transport(
            "\(provider.displayName)'s MCP job '\(jobID)' did not finish within \(minutes) minutes."
        )
    }

    private static func fetchResult(
        jobID: String,
        provider: GenerationProvider,
        tools: [MCPProviderClient.DiscoveredTool],
        client: any MCPToolCalling
    ) async throws -> [String] {
        guard let resultTool = MCPGenerationLifecycle.resultTool(in: tools) else {
            throw GenerationBackendError.transport(
                "\(provider.displayName)'s MCP completed job '\(jobID)' without output media."
            )
        }
        let arguments = try MCPGenerationArguments.makeJob(
            jobID: jobID,
            schema: resultTool.inputSchema
        )
        let payloads = try await client.callTool(name: resultTool.name, arguments: arguments)
        if case .failed(let message) = MCPGenerationLifecycle.status(from: payloads) {
            throw GenerationBackendError.transport(message)
        }
        let urls = MCPGenerationLifecycle.submission(from: payloads).outputURLs
        guard !urls.isEmpty else {
            throw GenerationBackendError.transport(
                "\(provider.displayName)'s MCP completed job '\(jobID)' without output media."
            )
        }
        return urls
    }
}
