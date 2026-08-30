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
        let output: MCPGenerationLifecycle.Output

        var outputURLs: [String] { output.urls }
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
        let hasLifecycle = hasUsableLifecycle(tools: tools)
        let hasDirectOutput = hasDirectOutputContract(generationTool)
        guard hasLifecycle
                || hasDirectOutput
                || MCPGenerationArguments.requestsSynchronousCompletion(
                    arguments: arguments
                )
                || MCPGenerationLifecycle.statusTool(in: tools) == nil else {
            throw GenerationBackendError.transport(
                "\(provider.displayName)'s generation tool exposes neither synchronous completion nor a usable job-status contract. No job was submitted."
            )
        }
        let payloads = try await client.callTool(
            name: generationTool.name,
            arguments: arguments
        )
        let submission = MCPGenerationLifecycle.submission(from: payloads)
        if !submission.output.isEmpty {
            switch MCPGenerationLifecycle.status(from: payloads) {
            case .succeeded:
                return Result(jobID: submission.jobID, output: submission.output)
            case .failed(let message):
                if let jobID = submission.jobID {
                    throw JobFailure(jobID: jobID, message: message)
                }
                throw GenerationBackendError.transport(message)
            case .pending, .unknown:
                break
            }
        }
        guard let jobID = submission.jobID else {
            throw GenerationBackendError.transport(
                "\(provider.displayName)'s MCP returned neither a job identifier nor output media."
            )
        }
        guard hasLifecycle else {
            let cancellation = await cancelAcceptedJobIndependently(
                jobID: jobID,
                tools: tools,
                client: client
            )
            throw JobFailure(
                jobID: jobID,
                message: "\(provider.displayName)'s MCP accepted the job but exposes no usable job-status tool. \(cancellation)"
            )
        }
        do {
            let output = try await poll(
                jobID: jobID,
                provider: provider,
                tools: tools,
                client: client,
                maxAttempts: maxPollAttempts,
                intervalNanoseconds: pollIntervalNanoseconds,
                timeoutSeconds: timeoutSeconds
            )
            return Result(jobID: jobID, output: output)
        } catch {
            if error is CancellationError || Task.isCancelled {
                let cancellation = await cancelAcceptedJobIndependently(
                    jobID: jobID,
                    tools: tools,
                    client: client
                )
                throw JobFailure(
                    jobID: jobID,
                    message: "Generation cancelled. \(cancellation)"
                )
            }
            throw JobFailure(jobID: jobID, message: error.localizedDescription)
        }
    }

    static func hasUsableLifecycle(
        tools: [MCPProviderClient.DiscoveredTool]
    ) -> Bool {
        guard let statusTool = MCPGenerationLifecycle.statusTool(in: tools) else { return false }
        do {
            _ = try MCPGenerationArguments.makeJob(
                jobID: "preflight-job",
                schema: statusTool.inputSchema,
                sync: false
            )
            return true
        } catch {
            return false
        }
    }

    static func hasDirectOutputContract(
        _ tool: MCPProviderClient.DiscoveredTool
    ) -> Bool {
        MCPGenerationLifecycle.outputSchemaSupportsMedia(tool.outputSchema)
    }

    private static func cancelAcceptedJob(
        jobID: String,
        tools: [MCPProviderClient.DiscoveredTool],
        client: any MCPToolCalling
    ) async -> String {
        guard let cancelTool = MCPGenerationLifecycle.cancelTool(in: tools) else {
            return "No compatible cancellation tool is available; the provider may still charge for the accepted job."
        }
        do {
            let arguments = try MCPGenerationArguments.makeJob(
                jobID: jobID,
                schema: cancelTool.inputSchema
            )
            _ = try await client.callTool(name: cancelTool.name, arguments: arguments)
            return "NexGenVideo sent a cancellation request for the accepted job."
        } catch {
            return "Cancellation failed (\(error.localizedDescription)); the provider may still charge for the accepted job."
        }
    }

    private static func cancelAcceptedJobIndependently(
        jobID: String,
        tools: [MCPProviderClient.DiscoveredTool],
        client: any MCPToolCalling
    ) async -> String {
        let cancellation = Task.detached {
            await cancelAcceptedJob(jobID: jobID, tools: tools, client: client)
        }
        return await cancellation.value
    }

    private static func poll(
        jobID: String,
        provider: GenerationProvider,
        tools: [MCPProviderClient.DiscoveredTool],
        client: any MCPToolCalling,
        maxAttempts: Int,
        intervalNanoseconds: UInt64,
        timeoutSeconds: TimeInterval
    ) async throws -> MCPGenerationLifecycle.Output {
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
            case .succeeded(let output) where !output.isEmpty:
                return output
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
    ) async throws -> MCPGenerationLifecycle.Output {
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
        let output = MCPGenerationLifecycle.resultOutput(from: payloads)
        guard !output.isEmpty else {
            throw GenerationBackendError.transport(
                "\(provider.displayName)'s MCP completed job '\(jobID)' without output media."
            )
        }
        return output
    }
}
