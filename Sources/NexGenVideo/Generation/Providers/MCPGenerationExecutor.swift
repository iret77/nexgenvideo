import Foundation
import MCP

protocol MCPToolCalling: Sendable {
    func callTool(name: String, arguments: [String: Value]) async throws -> [String]
    func callGenerationTool(
        name: String,
        arguments: [String: Value],
        onDispatched: @escaping @MainActor @Sendable () -> Void
    ) async throws -> [String]
}

extension MCPToolCalling {
    func callGenerationTool(
        name: String,
        arguments: [String: Value],
        onDispatched: @escaping @MainActor @Sendable () -> Void
    ) async throws -> [String] {
        let payloads = try await callTool(name: name, arguments: arguments)
        await onDispatched()
        return payloads
    }
}

extension MCPProviderClient: MCPToolCalling {}

enum MCPGenerationExecutor {
    private struct TerminalProviderState: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

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
        timeoutSeconds: TimeInterval = 30 * 60,
        onSubmissionDispatched: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws -> Result {
        let hasLifecycle = hasUsableLifecycle(tools: tools)
        let hasDirectOutput = hasDirectOutputContract(generationTool)
        let hasSynchronousOutput = MCPGenerationArguments.supportsSynchronousCompletion(
            schema: generationTool.inputSchema
        ) && MCPGenerationArguments.requestsSynchronousCompletion(arguments: arguments)
        guard hasLifecycle || hasDirectOutput || hasSynchronousOutput else {
            throw GenerationBackendError.transport(
                "\(provider.displayName)'s generation tool exposes no proven direct, synchronous, or asynchronous media result path. No job was submitted."
            )
        }
        let payloads = try await client.callGenerationTool(
            name: generationTool.name,
            arguments: arguments,
            onDispatched: onSubmissionDispatched
        )
        let allowRootURL = MCPGenerationLifecycle.outputSchemaAllowsRootURL(
            generationTool.outputSchema
        )
        let submission = MCPGenerationLifecycle.submission(
            from: payloads,
            allowRootURL: allowRootURL
        )
        switch MCPGenerationLifecycle.status(
            from: payloads,
            allowRootURL: allowRootURL
        ) {
        case .succeeded where !submission.output.isEmpty:
            return Result(jobID: submission.jobID, output: submission.output)
        case .succeeded:
            if let jobID = submission.jobID {
                do {
                    return Result(
                        jobID: jobID,
                        output: try await fetchResult(
                            jobID: jobID,
                            provider: provider,
                            tools: tools,
                            client: client
                        )
                    )
                } catch {
                    throw JobFailure(jobID: jobID, message: error.localizedDescription)
                }
            }
        case .failed(let message):
            if let jobID = submission.jobID {
                throw JobFailure(jobID: jobID, message: message)
            }
            throw GenerationBackendError.transport(message)
        case .pending, .unknown:
            break
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
                message: "\(provider.displayName)'s MCP accepted the job but exposes no usable asynchronous media result path. \(cancellation)"
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
        } catch let terminal as TerminalProviderState {
            throw JobFailure(jobID: jobID, message: terminal.message)
        } catch {
            let cancellation = await cancelAcceptedJobIndependently(
                jobID: jobID,
                tools: tools,
                client: client
            )
            let reason = error is CancellationError || Task.isCancelled
                ? "Generation cancelled."
                : error.localizedDescription
            throw JobFailure(
                jobID: jobID,
                message: "\(reason) \(cancellation)"
            )
        }
    }

    static func hasProvenResultPath(
        generationTool: MCPProviderClient.DiscoveredTool,
        tools: [MCPProviderClient.DiscoveredTool]
    ) -> Bool {
        hasDirectOutputContract(generationTool)
            || MCPGenerationArguments.supportsSynchronousCompletion(
                schema: generationTool.inputSchema
            )
            || hasUsableLifecycle(tools: tools)
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
            return MCPGenerationLifecycle.outputSchemaSupportsMedia(
                statusTool.outputSchema
            ) || usableResultTool(in: tools) != nil
        } catch {
            return false
        }
    }

    static func hasDirectOutputContract(
        _ tool: MCPProviderClient.DiscoveredTool
    ) -> Bool {
        MCPGenerationLifecycle.outputSchemaSupportsMedia(tool.outputSchema)
    }

    private static func usableResultTool(
        in tools: [MCPProviderClient.DiscoveredTool]
    ) -> MCPProviderClient.DiscoveredTool? {
        guard let tool = MCPGenerationLifecycle.resultTool(in: tools),
              tool.outputSchema == nil
                || MCPGenerationLifecycle.outputSchemaSupportsMedia(tool.outputSchema),
              (try? MCPGenerationArguments.makeJob(
                jobID: "preflight-job",
                schema: tool.inputSchema
              )) != nil else {
            return nil
        }
        return tool
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
            switch MCPGenerationLifecycle.status(
                from: payloads,
                allowRootURL: MCPGenerationLifecycle.outputSchemaAllowsRootURL(
                    statusTool.outputSchema
                )
            ) {
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
                throw TerminalProviderState(message: message)
            case .succeeded(let output) where !output.isEmpty:
                return output
            case .succeeded:
                do {
                    return try await fetchResult(
                        jobID: jobID,
                        provider: provider,
                        tools: tools,
                        client: client
                    )
                } catch {
                    throw TerminalProviderState(message: error.localizedDescription)
                }
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
        guard let resultTool = usableResultTool(in: tools) else {
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
