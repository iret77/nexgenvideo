import Foundation
import Darwin

enum CodexAppServerContract {
    static let cliVersion = "0.156.0"
    static let protocolRevision = "rust-v0.156.0"
    static let toolNamespace = "nexgen"
    static let requestTimeout: Duration = .seconds(15)
    static let turnTimeout: Duration = .seconds(900)
    static let maximumProtocolMessageBytes = 8 * 1_024 * 1_024

    static var isAcceptanceRun: Bool {
        ProcessInfo.processInfo.environment["NGV_CODEX_APP_SERVER_ACCEPTANCE"] == "1"
    }

    static let disabledFeatures = [
        "shell_tool", "view_image", "sleep_tool", "unified_exec", "unified_exec_tty",
        "shell_snapshot", "unbounded_connection_retries", "deferred_executor",
        "request_permissions_tool", "standalone_web_search", "hooks", "code_mode_host",
        "worktrees", "multi_agent", "multi_agent_v2", "apps", "enable_mcp_apps",
        "tool_suggest", "recommended_plugins", "plugins", "executor_capability_discovery",
        "in_app_browser", "in_app_chat", "in_app_dictation", "in_app_local_automation",
        "in_app_updates", "browser_use", "browser_use_full_cdp_access",
        "browser_use_external", "computer_use", "remote_plugin", "plugin_sharing",
        "image_generation", "send_message_to_user_async", "token_budget",
        "current_time_reminder", "realtime_conversation", "auth_elicitation",
        "tool_call_mcp_elicitation", "artifact", "memories", "skill_mcp_dependency_install",
        "skill_search", "guardian_approval", "goals",
    ]

    static var isolatedConfig: String {
        """
    cli_auth_credentials_store = "keyring"
    mcp_oauth_credentials_store = "keyring"
    model_provider = "openai"
    approval_policy = "never"
    sandbox_mode = "read-only"
    web_search = "disabled"
    check_for_update_on_startup = false

    [analytics]
    enabled = false

    [feedback]
    enabled = false

    [otel]
    log_user_prompt = false
    exporter = "none"
    trace_exporter = "none"
    metrics_exporter = "none"

    [tools.update_plan]
    enabled = false

    [tools.experimental_request_user_input]
    enabled = false

    [apps._default]
    enabled = false
    destructive_enabled = false
    open_world_enabled = false

    [features]
    """ + disabledFeatures.map { "\($0) = false" }.joined(separator: "\n") + "\n"
    }

    static var isolatedConfigurationLayer: [String: Any] {
        [
            "cli_auth_credentials_store": "keyring",
            "mcp_oauth_credentials_store": "keyring",
            "model_provider": "openai",
            "approval_policy": "never",
            "sandbox_mode": "read-only",
            "web_search": "disabled",
            "check_for_update_on_startup": false,
            "analytics": ["enabled": false],
            "feedback": ["enabled": false],
            "otel": [
                "log_user_prompt": false,
                "exporter": "none",
                "trace_exporter": "none",
                "metrics_exporter": "none",
            ],
            "tools": [
                "update_plan": ["enabled": false],
                "experimental_request_user_input": ["enabled": false],
            ],
            "apps": [
                "_default": [
                    "enabled": false,
                    "destructive_enabled": false,
                    "open_world_enabled": false,
                ],
            ],
            "features": Dictionary(uniqueKeysWithValues: disabledFeatures.map { ($0, false) }),
        ]
    }

    static func validateIsolation(
        configResponse: [String: Any],
        requirementsResponse: [String: Any],
        mcpResponse: [String: Any],
        skillsResponse: [String: Any],
        home: URL,
        scratch: URL
    ) throws {
        try validateConfiguration(
            configResponse: configResponse,
            requirementsResponse: requirementsResponse,
            home: home
        )
        try validateToolInventory(
            mcpResponse: mcpResponse,
            skillsResponse: skillsResponse,
            scratch: scratch
        )
    }

    static func validateConfiguration(
        configResponse: [String: Any],
        requirementsResponse: [String: Any],
        home: URL
    ) throws {
        guard let layers = configResponse["layers"] as? [[String: Any]],
              let effective = configResponse["config"] as? [String: Any],
              let origins = configResponse["origins"] as? [String: Any] else {
            throw CodexAppServerError.isolationViolation("Codex did not expose complete configuration layers")
        }

        let expectedConfig = home.appendingPathComponent("config.toml").standardizedFileURL
        var userLayers = 0
        for layer in layers {
            guard let source = layer["name"] as? [String: Any],
                  let type = source["type"] as? String,
                  let raw = layer["config"] as? [String: Any] else {
                throw CodexAppServerError.isolationViolation("Codex returned an unreadable configuration layer")
            }
            switch type {
            case "packagedDefaults":
                break
            case "system":
                guard raw.isEmpty else {
                    throw CodexAppServerError.isolationViolation("System Codex configuration is active")
                }
            case "user":
                userLayers += 1
                guard source["profile"] == nil || source["profile"] is NSNull,
                      let file = source["file"] as? String,
                      URL(fileURLWithPath: file).standardizedFileURL == expectedConfig,
                      equalJSON(raw, isolatedConfigurationLayer) else {
                    throw CodexAppServerError.isolationViolation("The isolated Codex configuration was not preserved")
                }
            default:
                guard raw.isEmpty else {
                    throw CodexAppServerError.isolationViolation("Forbidden Codex configuration layer: \(type)")
                }
            }
        }
        guard userLayers == 1 else {
            throw CodexAppServerError.isolationViolation("The isolated Codex user layer is missing")
        }
        for value in origins.values {
            guard let metadata = value as? [String: Any],
                  let source = metadata["name"] as? [String: Any],
                  let type = source["type"] as? String else {
                throw CodexAppServerError.isolationViolation("Codex returned unreadable configuration origins")
            }
            guard ["packagedDefaults", "system", "user"].contains(type) else {
                throw CodexAppServerError.isolationViolation("Forbidden Codex configuration origin: \(type)")
            }
        }
        guard effective["approval_policy"] as? String == "never",
              effective["sandbox_mode"] as? String == "read-only",
              effective["web_search"] as? String == "disabled",
              effective["model_provider"] as? String == "openai",
              isAbsentOrNull(effective["model"]),
              isAbsentOrNull(effective["instructions"]),
              isAbsentOrNull(effective["developer_instructions"]),
              isAbsentOrNull(effective["browser_use"]),
              isAbsentOrNull(effective["computer_use"]) else {
            throw CodexAppServerError.isolationViolation(
                "The effective Codex configuration changed the provider or capability boundary"
            )
        }
        guard requirementsResponse["requirements"] == nil
                || requirementsResponse["requirements"] is NSNull else {
            throw CodexAppServerError.isolationViolation("Managed Codex requirements are active")
        }
    }

    static func validateToolInventory(
        mcpResponse: [String: Any],
        skillsResponse: [String: Any],
        scratch: URL
    ) throws {
        guard let mcpServers = mcpResponse["data"] as? [Any], mcpServers.isEmpty,
              mcpResponse["nextCursor"] == nil || mcpResponse["nextCursor"] is NSNull else {
            throw CodexAppServerError.isolationViolation("A foreign Codex MCP server is configured")
        }
        guard let skillEntries = skillsResponse["data"] as? [[String: Any]],
              skillEntries.count == 1,
              skillEntries.allSatisfy({ entry in
                  entry["cwd"] as? String == scratch.path
                      && (entry["skills"] as? [Any])?.isEmpty == true
                      && (entry["errors"] as? [Any])?.isEmpty == true
              }) else {
            throw CodexAppServerError.isolationViolation("Codex skills are present or could not be enumerated")
        }
    }

    private static func isAbsentOrNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    private static func equalJSON(_ lhs: Any, _ rhs: Any) -> Bool {
        guard JSONSerialization.isValidJSONObject(lhs),
              JSONSerialization.isValidJSONObject(rhs),
              let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else {
            return false
        }
        return left == right
    }

    static func accepts(userAgent: String) -> Bool {
        userAgent.split(whereSeparator: { !$0.isNumber && $0 != "." })
            .contains(Substring(cliVersion))
    }

    static func childEnvironment(
        ambient: [String: String],
        home: URL,
        scratch: URL
    ) -> [String: String] {
        var result = [
            "CODEX_HOME": home.path,
            "HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent("config", isDirectory: true).path,
            "XDG_CACHE_HOME": scratch.appendingPathComponent("cache", isDirectory: true).path,
            "XDG_DATA_HOME": home.appendingPathComponent("data", isDirectory: true).path,
            "TMPDIR": scratch.path,
            "RUST_LOG": "error",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        for key in ["LANG", "LC_ALL", "USER", "LOGNAME"] {
            if let value = ambient[key] { result[key] = value }
        }
        return result
    }
}

enum CodexAppServerError: LocalizedError, Equatable {
    case executableUnavailable
    case incompatibleVersion(String)
    case isolatedHomeMismatch
    case isolationViolation(String)
    case authenticationRequired
    case resumeIsolationUnavailable
    case transcriptReplayUnavailable(String)
    case malformedMessage
    case remote(code: Int, message: String)
    case requestTimedOut(String)
    case transportClosed
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            "Install Codex CLI \(CodexAppServerContract.cliVersion) to use this runtime."
        case .incompatibleVersion(let value):
            "Codex CLI \(value) is incompatible; version \(CodexAppServerContract.cliVersion) is required."
        case .isolatedHomeMismatch:
            "Codex did not honor the isolated runtime home."
        case .isolationViolation(let detail):
            "Codex isolation is incompatible: \(detail)."
        case .authenticationRequired:
            "Sign in to the isolated NexGenVideo Codex account before starting a turn."
        case .resumeIsolationUnavailable:
            "Codex CLI \(CodexAppServerContract.cliVersion) cannot safely restore the isolated tool surface."
        case .transcriptReplayUnavailable(let detail):
            "Codex cannot safely replay this chat: \(detail)."
        case .malformedMessage:
            "Codex App Server returned an invalid protocol message."
        case .remote(_, let message):
            "Codex App Server rejected the request: \(message)"
        case .requestTimedOut(let method):
            "Codex App Server timed out while handling \(method)."
        case .transportClosed:
            "Codex App Server closed its transport."
        case .launchFailed(let message):
            "Codex App Server could not start: \(message)"
        }
    }
}

enum CodexAppServerInbound {
    case notification(method: String, params: [String: Any])
    case request(id: Any, method: String, params: [String: Any])
    case closed(CodexAppServerError)
}

struct CodexAppServerAccountStatus: Equatable, Sendable {
    enum Billing: Equatable, Sendable {
        case apiKey
        case chatGPT(plan: String)
    }

    let billing: Billing
}

@MainActor
protocol CodexAppServerDriving: AnyObject {
    var events: AsyncStream<CodexAppServerInbound> { get }
    var accountStatus: CodexAppServerAccountStatus? { get }

    func start(home: URL, scratch: URL) async throws
    func verifyIsolation(home: URL, scratch: URL) async throws
    func request(method: String, params: [String: Any]) async throws -> [String: Any]
    func respond(id: Any, result: [String: Any]) throws
    func respond(id: Any, errorCode: Int, message: String) throws
    func stop()
}

@MainActor
final class CodexAppServerJSONRPCDriver: CodexAppServerDriving {
    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeout: Task<Void, Never>
    }

    let events: AsyncStream<CodexAppServerInbound>
    private(set) var accountStatus: CodexAppServerAccountStatus?

    private let eventContinuation: AsyncStream<CodexAppServerInbound>.Continuation
    private let fileManager: FileManager
    private let environment: [String: String]
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var readBuffer = Data()
    private var pending: [Int: Pending] = [:]
    private var nextRequestID = 1
    private var didClose = false
    private var ownedScratch: URL?
    private var terminationOwner: CodexAppServerJSONRPCDriver?
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedMethods: [String] = []
    private(set) var observedTurnStartedIDs: Set<String> = []
    private(set) var observedInterruptedTurnIDs: Set<String> = []
    private(set) var sentTypedImageToolResult = false
    private(set) var terminationConfirmed = false

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
        var continuation: AsyncStream<CodexAppServerInbound>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func start(home: URL, scratch: URL) async throws {
        guard process == nil else { return }
        guard let executable = CodexAppServerLocator.executable(
            environment: environment,
            fileManager: fileManager
        ) else {
            throw CodexAppServerError.executableUnavailable
        }
        try prepare(home: home, scratch: scratch)

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--strict-config"]
        process.currentDirectoryURL = scratch
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = CodexAppServerContract.childEnvironment(
            ambient: environment,
            home: home,
            scratch: scratch
        )
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in self?.processDidTerminate(process) }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        terminationOwner = self
        do {
            try process.run()
        } catch {
            terminationOwner = nil
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            cleanupScratch()
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
        self.process = process
        stdin = input.fileHandleForWriting
        stdout = output.fileHandleForReading
        stderr = errors.fileHandleForReading

        do {
            let initialize = try await request(method: "initialize", params: [
                "clientInfo": ["name": "NexGenVideo", "version": "1"],
                "capabilities": ["experimentalApi": true],
            ])
            guard let userAgent = initialize["userAgent"] as? String else {
                throw CodexAppServerError.malformedMessage
            }
            guard CodexAppServerContract.accepts(userAgent: userAgent) else {
                throw CodexAppServerError.incompatibleVersion(userAgent)
            }
            guard let reportedHome = initialize["codexHome"] as? String,
                  URL(fileURLWithPath: reportedHome).standardizedFileURL == home.standardizedFileURL else {
                throw CodexAppServerError.isolatedHomeMismatch
            }
            try send(["method": "initialized", "params": [:]])
            try await verifyIsolation(home: home, scratch: scratch)

            let account = try await request(method: "account/read", params: ["refreshToken": false])
            if account["requiresOpenaiAuth"] as? Bool == true, account["account"] is NSNull {
                throw CodexAppServerError.authenticationRequired
            }
            guard let details = account["account"] as? [String: Any],
                  let type = details["type"] as? String else {
                throw CodexAppServerError.authenticationRequired
            }
            switch type {
            case "apiKey":
                accountStatus = .init(billing: .apiKey)
            case "chatgpt":
                guard let plan = details["planType"] as? String else {
                    throw CodexAppServerError.malformedMessage
                }
                accountStatus = .init(billing: .chatGPT(plan: plan))
            default:
                throw CodexAppServerError.isolationViolation("The account selected a non-OpenAI provider")
            }
        } catch {
            stop()
            throw error
        }
    }

    func verifyIsolation(home: URL, scratch: URL) async throws {
        let config = try await request(method: "config/read", params: [
            "cwd": scratch.path,
            "includeLayers": true,
        ])
        let requirements = try await request(method: "configRequirements/read", params: [:])
        try CodexAppServerContract.validateConfiguration(
            configResponse: config,
            requirementsResponse: requirements,
            home: home
        )
        let mcp = try await request(method: "mcpServerStatus/list", params: [
            "detail": "toolsAndAuthOnly",
            "limit": 100,
        ])
        let skills = try await request(method: "skills/list", params: [
            "cwds": [scratch.path],
            "forceReload": true,
        ])
        try CodexAppServerContract.validateToolInventory(
            mcpResponse: mcp,
            skillsResponse: skills,
            scratch: scratch
        )
    }

    func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        requestedMethods.append(method)
        let id = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: CodexAppServerContract.requestTimeout)
                guard !Task.isCancelled else { return }
                self?.timeout(id: id)
            }
            pending[id] = Pending(method: method, continuation: continuation, timeout: timeout)
            do {
                try send(["id": id, "method": method, "params": params])
            } catch {
                pending.removeValue(forKey: id)?.timeout.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    func respond(id: Any, result: [String: Any]) throws {
        if let content = result["contentItems"] as? [[String: Any]],
           content.contains(where: { $0["type"] as? String == "inputImage" }) {
            sentTypedImageToolResult = true
        }
        try send(["id": id, "result": result])
    }

    func respond(id: Any, errorCode: Int, message: String) throws {
        try send(["id": id, "error": ["code": errorCode, "message": message]])
    }

    func stop() {
        let shouldFinish = !didClose
        didClose = true
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
        try? stdin?.close()
        if let process, process.isRunning {
            Self.terminate(process)
        }
        if shouldFinish {
            finishPending(with: CodexAppServerError.transportClosed)
            eventContinuation.finish()
        }
        stdin = nil
        stdout = nil
        stderr = nil
        if process?.isRunning != true {
            finalizeTermination()
        }
    }

    func waitForTermination() async {
        if terminationConfirmed || process == nil { return }
        await withCheckedContinuation { continuation in
            terminationWaiters.append(continuation)
        }
    }

    private func prepare(home: URL, scratch: URL) throws {
        guard !fileManager.fileExists(atPath: scratch.path) else {
            throw CodexAppServerError.launchFailed("The runtime scratch directory already exists")
        }
        do {
            try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            ownedScratch = scratch
            let config = home.appendingPathComponent("config.toml")
            try Data(CodexAppServerContract.isolatedConfig.utf8).write(to: config, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        } catch {
            cleanupScratch()
            throw error
        }
    }

    private func receive(_ data: Data) {
        guard !didClose else { return }
        guard !data.isEmpty else {
            transportClosed()
            return
        }
        readBuffer.append(data)
        guard readBuffer.count <= CodexAppServerContract.maximumProtocolMessageBytes else {
            eventContinuation.yield(.closed(.malformedMessage))
            stop()
            return
        }
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer[..<newline]
            readBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let value = try JSONSerialization.jsonObject(with: Data(line))
                guard let object = value as? [String: Any] else {
                    throw CodexAppServerError.malformedMessage
                }
                try route(object)
            } catch {
                eventContinuation.yield(.closed(.malformedMessage))
                stop()
                return
            }
        }
    }

    private func route(_ object: [String: Any]) throws {
        if let id = object["id"], object["method"] == nil {
            guard let numericID = (id as? NSNumber)?.intValue,
                  let pending = pending.removeValue(forKey: numericID) else { return }
            pending.timeout.cancel()
            if let error = object["error"] as? [String: Any] {
                let code = (error["code"] as? NSNumber)?.intValue ?? -32_000
                let message = error["message"] as? String ?? "Unknown protocol error"
                pending.continuation.resume(throwing: CodexAppServerError.remote(code: code, message: message))
            } else if let result = object["result"] as? [String: Any] {
                pending.continuation.resume(returning: result)
            } else if object["result"] is NSNull {
                pending.continuation.resume(returning: [:])
            } else {
                pending.continuation.resume(throwing: CodexAppServerError.malformedMessage)
            }
            return
        }
        guard let method = object["method"] as? String else {
            throw CodexAppServerError.malformedMessage
        }
        let params = object["params"] as? [String: Any] ?? [:]
        if method == "turn/started",
           let turn = params["turn"] as? [String: Any],
           let turnID = turn["id"] as? String {
            observedTurnStartedIDs.insert(turnID)
        } else if method == "turn/completed",
                  let turn = params["turn"] as? [String: Any],
                  turn["status"] as? String == "interrupted",
                  let turnID = turn["id"] as? String {
            observedInterruptedTurnIDs.insert(turnID)
        }
        if let id = object["id"] {
            eventContinuation.yield(.request(id: id, method: method, params: params))
        } else {
            eventContinuation.yield(.notification(method: method, params: params))
        }
    }

    private func send(_ object: [String: Any]) throws {
        guard let stdin, process?.isRunning == true, !didClose else {
            throw CodexAppServerError.transportClosed
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= CodexAppServerContract.maximumProtocolMessageBytes else {
            throw CodexAppServerError.malformedMessage
        }
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    private func timeout(id: Int) {
        guard let pending = pending.removeValue(forKey: id) else { return }
        pending.continuation.resume(throwing: CodexAppServerError.requestTimedOut(pending.method))
    }

    private func transportClosed() {
        guard !didClose else { return }
        didClose = true
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
        try? stdin?.close()
        if let process, process.isRunning {
            Self.terminate(process)
        }
        finishPending(with: CodexAppServerError.transportClosed)
        eventContinuation.yield(.closed(.transportClosed))
        eventContinuation.finish()
        stdin = nil
        stdout = nil
        stderr = nil
        if process?.isRunning != true {
            finalizeTermination()
        }
    }

    private func processDidTerminate(_ terminatedProcess: Process) {
        if process === terminatedProcess {
            process = nil
        }
        if !didClose {
            transportClosed()
        }
        finalizeTermination()
    }

    private func finalizeTermination() {
        guard !terminationConfirmed else { return }
        terminationConfirmed = true
        cleanupScratch()
        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        waiters.forEach { $0.resume() }
        terminationOwner = nil
    }

    private func cleanupScratch() {
        guard let scratch = ownedScratch else { return }
        ownedScratch = nil
        try? fileManager.removeItem(at: scratch)
    }

    private func finishPending(with error: Error) {
        let values = Array(pending.values)
        pending.removeAll()
        for value in values {
            value.timeout.cancel()
            value.continuation.resume(throwing: error)
        }
    }

    private static func terminate(_ process: Process) {
        process.terminate()
        Task { @MainActor [process] in
            try? await Task.sleep(for: .seconds(2))
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            guard pid > 1 else { return }
            kill(pid, SIGKILL)
        }
    }
}

enum CodexAppServerLocator {
    static func executable(
        environment: [String: String],
        fileManager: FileManager
    ) -> URL? {
        let candidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
            + [
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                URL(fileURLWithPath: "/usr/local/bin/codex"),
            ]
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            if let native = nativeExecutable(for: candidate, fileManager: fileManager) {
                return native
            }
            let resolved = candidate.resolvingSymlinksInPath()
            if isMachO(resolved) { return resolved }
        }
        return nil
    }

    private static func nativeExecutable(for wrapper: URL, fileManager: FileManager) -> URL? {
        let resolved = wrapper.resolvingSymlinksInPath()
        guard resolved.lastPathComponent == "codex.js" else { return nil }
        let packageRoot = resolved.deletingLastPathComponent().deletingLastPathComponent()
        let binary = packageRoot
            .appendingPathComponent("node_modules/@openai/codex-darwin-arm64")
            .appendingPathComponent("vendor/aarch64-apple-darwin/bin/codex")
        return fileManager.isExecutableFile(atPath: binary.path) ? binary : nil
    }

    private static func isMachO(_ executable: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 4), bytes.count == 4 else { return false }
        return [
            Data([0xCF, 0xFA, 0xED, 0xFE]),
            Data([0xFE, 0xED, 0xFA, 0xCF]),
            Data([0xCA, 0xFE, 0xBA, 0xBE]),
            Data([0xBE, 0xBA, 0xFE, 0xCA]),
        ].contains(bytes)
    }
}
