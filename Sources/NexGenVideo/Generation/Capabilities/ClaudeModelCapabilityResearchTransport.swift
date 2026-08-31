import Foundation
import NexGenEngine

struct ClaudeCapabilityResearchProbeV1: Sendable, Equatable {
    let executableURL: URL
    let version: String
    let verifiedFlags: Set<String>
}

struct ClaudeCapabilityResearchRuntimeProofV1: Sendable, Equatable {
    let cliVersion: String
    let availableTools: Set<String>
    let usedTools: Set<String>
}

struct ClaudeModelCapabilityResearchResultV1: Sendable, Equatable {
    let candidate: ModelCapabilityResearchCandidateV1
    let proof: ClaudeCapabilityResearchRuntimeProofV1
}

struct ClaudeCapabilityResearchToolUseProofV1: Sendable, Equatable {
    let tools: Set<String>
    let fetchesByToolUseID: [String: String]
}

struct ClaudeCapabilityResearchToolResultProofV1: Sendable, Equatable {
    let completedFetchIDs: Set<String>
    let failedFetchIDs: Set<String>
}

private extension CapabilityFieldsV1 {
    var allEvidenceSourceURLs: Set<String> {
        let evidence = integers.values.flatMap(\.evidence)
            + decimals.values.flatMap(\.evidence)
            + booleans.values.flatMap(\.evidence)
            + strings.values.flatMap(\.evidence)
            + integerLists.values.flatMap(\.evidence)
        return Set(evidence.compactMap(\.sourceURL))
    }
}

enum ClaudeModelCapabilityResearchError: Error, Sendable, Equatable {
    case executableUnavailable
    case probeTimedOut
    case probeFailed(String)
    case unsupportedCLI(String)
    case unsafeWorkingDirectory
    case processFailed(String)
    case timeout
    case outputLimitExceeded
    case missingRuntimeHandshake
    case unexpectedRuntimeTools([String])
    case unexpectedMCPServer
    case unexpectedPermissionMode
    case wrongRuntimeDirectory
    case disallowedTool(String)
    case invalidToolResult
    case unscopedWebSearch
    case disallowedWebFetchURL
    case unfetchedEvidenceURL(String)
    case noFetchedEvidence
    case malformedResult
}

enum ClaudeCapabilityResearchProbe {
    static let requiredFlags: Set<String> = [
        "--allowedTools", "--disable-slash-commands", "--disallowedTools", "--effort",
        "--input-format", "--json-schema", "--max-budget-usd", "--mcp-config", "--model",
        "--no-chrome", "--no-session-persistence", "--output-format", "--permission-mode",
        "--print", "--restricted", "--safe-mode", "--setting-sources", "--strict-mcp-config",
        "--system-prompt", "--tools", "--verbose",
    ]

    static func run(
        executableURL: URL,
        timeout: TimeInterval = 5
    ) throws -> ClaudeCapabilityResearchProbeV1 {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ClaudeModelCapabilityResearchError.executableUnavailable
        }
        let versionOutput = try capture(executableURL, arguments: ["--version"], timeout: timeout)
        let helpOutput = try capture(executableURL, arguments: ["--help"], timeout: timeout)
        return try validate(
            executableURL: executableURL,
            versionOutput: versionOutput,
            helpOutput: helpOutput
        )
    }

    static func validate(
        executableURL: URL,
        versionOutput: String,
        helpOutput: String
    ) throws -> ClaudeCapabilityResearchProbeV1 {
        guard let version = ClaudeCodeLocator.parseVersion(
            versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw ClaudeModelCapabilityResearchError.unsupportedCLI("version")
        }
        let verified = Set(requiredFlags.filter { helpOutput.contains($0) })
        guard verified == requiredFlags else {
            let missing = requiredFlags.subtracting(verified).sorted().joined(separator: ",")
            throw ClaudeModelCapabilityResearchError.unsupportedCLI(missing)
        }
        return ClaudeCapabilityResearchProbeV1(
            executableURL: executableURL.standardizedFileURL,
            version: version,
            verifiedFlags: verified
        )
    }

    private static func capture(
        _ executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> String {
        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NexGenVideo-ClaudeProbe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: captureDirectory,
                withIntermediateDirectories: false
            )
        } catch {
            throw ClaudeModelCapabilityResearchError.probeFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let stdoutURL = captureDirectory.appendingPathComponent("stdout")
        let stderrURL = captureDirectory.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
            throw ClaudeModelCapabilityResearchError.probeFailed("capture_files")
        }
        let stdout: FileHandle
        let stderr: FileHandle
        do {
            stdout = try FileHandle(forWritingTo: stdoutURL)
            stderr = try FileHandle(forWritingTo: stderrURL)
        } catch {
            throw ClaudeModelCapabilityResearchError.probeFailed(error.localizedDescription)
        }
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = captureDirectory
        process.environment = ClaudeModelCapabilityResearchLaunch.childEnvironment()
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw ClaudeModelCapabilityResearchError.probeFailed(error.localizedDescription)
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            throw ClaudeModelCapabilityResearchError.probeTimedOut
        }
        try? stdout.synchronize()
        try? stderr.synchronize()
        let output = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let errorOutput = (try? Data(contentsOf: stderrURL)) ?? Data()
        guard process.terminationStatus == 0 else {
            throw ClaudeModelCapabilityResearchError.probeFailed(
                String(decoding: errorOutput, as: UTF8.self)
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}

enum ClaudeModelCapabilityResearchLaunch {
    static let tools: Set<String> = ["WebFetch", "WebSearch"]
    static let emptyMCPConfig = #"{"mcpServers":{}}"#
    static let deniedTools = [
        "Agent", "AskUserQuestion", "Bash", "Edit", "Glob", "Grep", "NotebookEdit", "Read",
        "Skill", "TaskCreate", "TaskGet", "TaskList", "TaskStop", "TaskUpdate", "TodoWrite",
        "ToolSearch", "Write", "mcp__*",
    ]

    static func arguments(
        request: ModelCapabilityResearchRequestV1,
        model: String? = nil,
        maximumBudgetUSD: Decimal = Decimal(string: "0.75")!
    ) throws -> [String] {
        let outputSchema = try ModelCapabilityResearchOutputSchema.json(for: request)
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--restricted",
            "--safe-mode",
            "--mcp-config", emptyMCPConfig,
            "--strict-mcp-config",
            "--setting-sources", "project,local",
            "--permission-mode", "dontAsk",
            "--tools", tools.sorted().joined(separator: ","),
            "--allowedTools", tools.sorted().joined(separator: ","),
            "--disallowedTools", deniedTools.joined(separator: ","),
            "--disable-slash-commands",
            "--no-chrome",
            "--no-session-persistence",
            "--effort", "low",
            "--max-budget-usd", NSDecimalNumber(decimal: maximumBudgetUSD).stringValue,
            "--system-prompt", ModelCapabilityResearchPrompt.system,
            "--json-schema", outputSchema,
        ]
        if let model {
            arguments.append(contentsOf: ["--model", model])
        }
        return arguments
    }

    static func childEnvironment(
        source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let exact = Set([
            "HOME", "PATH", "SHELL", "TMPDIR", "USER", "LOGNAME", "LANG", "TERM",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "HTTPS_PROXY", "HTTP_PROXY",
            "NO_PROXY",
        ])
        return source.filter { key, _ in
            exact.contains(key) || key.hasPrefix("LC_") || key.hasPrefix("XDG_")
        }
    }
}

enum ClaudeCapabilityResearchRuntimeHandshake {
    static func validate(
        line: String,
        workingDirectory: URL
    ) throws -> Set<String> {
        guard let object = jsonObject(line),
              object["type"] as? String == "system",
              object["subtype"] as? String == "init",
              let tools = object["tools"] as? [String] else {
            throw ClaudeModelCapabilityResearchError.missingRuntimeHandshake
        }
        let actual = Set(tools)
        guard actual == ClaudeModelCapabilityResearchLaunch.tools else {
            throw ClaudeModelCapabilityResearchError.unexpectedRuntimeTools(actual.sorted())
        }
        guard let servers = object["mcp_servers"] as? [Any] else {
            throw ClaudeModelCapabilityResearchError.unexpectedMCPServer
        }
        if !servers.isEmpty {
            throw ClaudeModelCapabilityResearchError.unexpectedMCPServer
        }
        guard object["permissionMode"] as? String == "dontAsk" else {
            throw ClaudeModelCapabilityResearchError.unexpectedPermissionMode
        }
        guard let cwd = object["cwd"] as? String,
              URL(fileURLWithPath: cwd).standardizedFileURL
                == workingDirectory.standardizedFileURL else {
            throw ClaudeModelCapabilityResearchError.wrongRuntimeDirectory
        }
        return actual
    }

    static func validateToolUses(
        line: String,
        allowedSourceHosts: [String]
    ) throws -> ClaudeCapabilityResearchToolUseProofV1 {
        guard let object = jsonObject(line), object["type"] as? String == "assistant" else {
            return ClaudeCapabilityResearchToolUseProofV1(tools: [], fetchesByToolUseID: [:])
        }
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return ClaudeCapabilityResearchToolUseProofV1(tools: [], fetchesByToolUseID: [:])
        }
        var used = Set<String>()
        var fetchesByToolUseID: [String: String] = [:]
        for block in content where block["type"] as? String == "tool_use" {
            guard let name = block["name"] as? String,
                  ClaudeModelCapabilityResearchLaunch.tools.contains(name),
                  let toolUseID = block["id"] as? String,
                  !toolUseID.isEmpty,
                  let input = block["input"] as? [String: Any] else {
                throw ClaudeModelCapabilityResearchError.disallowedTool(
                    block["name"] as? String ?? "unknown"
                )
            }
            switch name {
            case "WebSearch":
                guard let domains = input["allowed_domains"] as? [String],
                      !domains.isEmpty,
                      input["blocked_domains"] == nil,
                      Set(domains).isSubset(of: Set(allowedSourceHosts)) else {
                    throw ClaudeModelCapabilityResearchError.unscopedWebSearch
                }
            case "WebFetch":
                guard let rawURL = input["url"] as? String else {
                    throw ClaudeModelCapabilityResearchError.disallowedWebFetchURL
                }
                do {
                    try ModelCapabilityResearchValidator.validateSourceURL(
                        rawURL,
                        allowedSourceHosts: allowedSourceHosts
                    )
                } catch {
                    throw ClaudeModelCapabilityResearchError.disallowedWebFetchURL
                }
                guard fetchesByToolUseID.updateValue(rawURL, forKey: toolUseID) == nil else {
                    throw ClaudeModelCapabilityResearchError.invalidToolResult
                }
            default:
                throw ClaudeModelCapabilityResearchError.disallowedTool(name)
            }
            used.insert(name)
        }
        return ClaudeCapabilityResearchToolUseProofV1(
            tools: used,
            fetchesByToolUseID: fetchesByToolUseID
        )
    }

    static func validateToolResults(
        line: String,
        pendingFetches: [String: String]
    ) throws -> ClaudeCapabilityResearchToolResultProofV1 {
        guard let object = jsonObject(line), object["type"] as? String == "user" else {
            return ClaudeCapabilityResearchToolResultProofV1(
                completedFetchIDs: [],
                failedFetchIDs: []
            )
        }
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            throw ClaudeModelCapabilityResearchError.invalidToolResult
        }
        var completed = Set<String>()
        var failed = Set<String>()
        for block in content where block["type"] as? String == "tool_result" {
            guard let toolUseID = block["tool_use_id"] as? String,
                  !toolUseID.isEmpty else {
                throw ClaudeModelCapabilityResearchError.invalidToolResult
            }
            guard pendingFetches[toolUseID] != nil else { continue }
            if block["is_error"] as? Bool == true {
                failed.insert(toolUseID)
            } else {
                let hasContent = (block["content"] as? String)?.isEmpty == false
                    || (block["content"] as? [Any])?.isEmpty == false
                guard hasContent else {
                    throw ClaudeModelCapabilityResearchError.invalidToolResult
                }
                completed.insert(toolUseID)
            }
        }
        guard completed.isDisjoint(with: failed) else {
            throw ClaudeModelCapabilityResearchError.invalidToolResult
        }
        return ClaudeCapabilityResearchToolResultProofV1(
            completedFetchIDs: completed,
            failedFetchIDs: failed
        )
    }

    static func resultData(line: String) throws -> Data? {
        guard let object = jsonObject(line), object["type"] as? String == "result" else {
            return nil
        }
        guard object["subtype"] as? String == "success",
              object["is_error"] as? Bool != true else {
            throw ClaudeModelCapabilityResearchError.processFailed(
                (object["result"] as? String) ?? "Claude research failed"
            )
        }
        if let structured = object["structured_output"], JSONSerialization.isValidJSONObject(structured) {
            return try JSONSerialization.data(
                withJSONObject: structured,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        }
        guard let result = object["result"] as? String,
              let data = result.data(using: .utf8) else {
            throw ClaudeModelCapabilityResearchError.malformedResult
        }
        return data
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return decoded as? [String: Any]
    }
}

struct ClaudeModelCapabilityResearchTransport: Sendable {
    let maximumOutputBytes: Int
    let timeout: Duration

    init(maximumOutputBytes: Int = 2_000_000, timeout: Duration = .seconds(240)) {
        self.maximumOutputBytes = maximumOutputBytes
        self.timeout = timeout
    }

    func research(
        _ request: ModelCapabilityResearchRequestV1,
        proof: ClaudeCapabilityResearchProbeV1,
        model: String? = nil
    ) async throws -> ClaudeModelCapabilityResearchResultV1 {
        try ModelCapabilityResearchValidator.validate(request)
        guard proof.verifiedFlags == ClaudeCapabilityResearchProbe.requiredFlags else {
            throw ClaudeModelCapabilityResearchError.unsupportedCLI("incomplete_probe")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NexGenVideo-ModelCapabilityResearch-\(UUID().uuidString)",
                isDirectory: true
            )
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw ClaudeModelCapabilityResearchError.unsafeWorkingDirectory
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let process = ClaudeCodeProcess()
        let stream: AsyncThrowingStream<String, Error>
        do {
            stream = try process.start(
                executableURL: proof.executableURL,
                arguments: try ClaudeModelCapabilityResearchLaunch.arguments(
                    request: request,
                    model: model
                ),
                workingDirectory: directory,
                environment: ClaudeModelCapabilityResearchLaunch.childEnvironment()
            )
        } catch {
            throw ClaudeModelCapabilityResearchError.processFailed(error.localizedDescription)
        }
        let userMessage = try ModelCapabilityResearchPrompt.user(request)
        guard process.send(line: ClaudeCodeLaunch.userMessageLine(userMessage)) else {
            process.terminate()
            throw ClaudeModelCapabilityResearchError.processFailed("stdin")
        }
        process.closeStdin()
        defer { process.terminate() }

        return try await withThrowingTaskGroup(
            of: ClaudeModelCapabilityResearchResultV1.self
        ) { group in
            group.addTask {
                try await consume(
                    stream,
                    process: process,
                    request: request,
                    proof: proof,
                    workingDirectory: directory,
                    maximumOutputBytes: maximumOutputBytes
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ClaudeModelCapabilityResearchError.timeout
            }
            guard let result = try await group.next() else {
                throw ClaudeModelCapabilityResearchError.malformedResult
            }
            group.cancelAll()
            return result
        }
    }

    private func consume(
        _ stream: AsyncThrowingStream<String, Error>,
        process: ClaudeCodeProcess,
        request: ModelCapabilityResearchRequestV1,
        proof: ClaudeCapabilityResearchProbeV1,
        workingDirectory: URL,
        maximumOutputBytes: Int
    ) async throws -> ClaudeModelCapabilityResearchResultV1 {
        var byteCount = 0
        var availableTools: Set<String>?
        var usedTools = Set<String>()
        var pendingFetches: [String: String] = [:]
        var fetchedURLs = Set<String>()
        do {
            for try await line in stream {
                try Task.checkCancellation()
                byteCount += line.utf8.count
                guard byteCount <= maximumOutputBytes else {
                    throw ClaudeModelCapabilityResearchError.outputLimitExceeded
                }
                if availableTools == nil {
                    availableTools = try ClaudeCapabilityResearchRuntimeHandshake.validate(
                        line: line,
                        workingDirectory: workingDirectory
                    )
                    continue
                }
                let toolUse = try ClaudeCapabilityResearchRuntimeHandshake.validateToolUses(
                    line: line,
                    allowedSourceHosts: request.allowedSourceHosts
                )
                usedTools.formUnion(toolUse.tools)
                for (toolUseID, sourceURL) in toolUse.fetchesByToolUseID {
                    guard pendingFetches.updateValue(sourceURL, forKey: toolUseID) == nil else {
                        throw ClaudeModelCapabilityResearchError.invalidToolResult
                    }
                }
                let toolResult = try ClaudeCapabilityResearchRuntimeHandshake.validateToolResults(
                    line: line,
                    pendingFetches: pendingFetches
                )
                for toolUseID in toolResult.completedFetchIDs {
                    guard let sourceURL = pendingFetches.removeValue(forKey: toolUseID) else {
                        throw ClaudeModelCapabilityResearchError.invalidToolResult
                    }
                    fetchedURLs.insert(sourceURL)
                }
                for toolUseID in toolResult.failedFetchIDs {
                    pendingFetches.removeValue(forKey: toolUseID)
                }
                if let data = try ClaudeCapabilityResearchRuntimeHandshake.resultData(line: line) {
                    guard !fetchedURLs.isEmpty else {
                        throw ClaudeModelCapabilityResearchError.noFetchedEvidence
                    }
                    let candidate = try ModelCapabilityResearchValidator.decodeCandidate(
                        data,
                        for: request
                    )
                    for sourceURL in candidate.fields.allEvidenceSourceURLs
                    where !fetchedURLs.contains(sourceURL) {
                        throw ClaudeModelCapabilityResearchError.unfetchedEvidenceURL(sourceURL)
                    }
                    return ClaudeModelCapabilityResearchResultV1(
                        candidate: candidate,
                        proof: ClaudeCapabilityResearchRuntimeProofV1(
                            cliVersion: proof.version,
                            availableTools: availableTools!,
                            usedTools: usedTools
                        )
                    )
                }
            }
        } catch let error as ClaudeModelCapabilityResearchError {
            throw error
        } catch {
            let stderr = process.drainStderr().trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClaudeModelCapabilityResearchError.processFailed(
                stderr.isEmpty ? error.localizedDescription : stderr
            )
        }
        guard availableTools != nil else {
            throw ClaudeModelCapabilityResearchError.missingRuntimeHandshake
        }
        throw ClaudeModelCapabilityResearchError.malformedResult
    }
}
