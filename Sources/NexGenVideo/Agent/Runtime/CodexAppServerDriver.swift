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

    static let isolatedConfig = """
    cli_auth_credentials_store = "keyring"
    mcp_oauth_credentials_store = "keyring"
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
    shell_tool = false
    view_image = false
    sleep_tool = false
    unified_exec = false
    unified_exec_tty = false
    shell_snapshot = false
    unbounded_connection_retries = false
    deferred_executor = false
    request_permissions_tool = false
    standalone_web_search = false
    hooks = false
    code_mode_host = false
    worktrees = false
    multi_agent = false
    multi_agent_v2 = false
    apps = false
    enable_mcp_apps = false
    tool_suggest = false
    recommended_plugins = false
    plugins = false
    executor_capability_discovery = false
    in_app_browser = false
    in_app_chat = false
    in_app_dictation = false
    in_app_local_automation = false
    in_app_updates = false
    browser_use = false
    browser_use_full_cdp_access = false
    browser_use_external = false
    computer_use = false
    remote_plugin = false
    plugin_sharing = false
    image_generation = false
    send_message_to_user_async = false
    token_budget = false
    current_time_reminder = false
    realtime_conversation = false
    auth_elicitation = false
    tool_call_mcp_elicitation = false
    artifact = false
    memories = false
    skill_mcp_dependency_install = false
    skill_search = false
    guardian_approval = false
    goals = false
    """

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
    case authenticationRequired
    case resumeIsolationUnavailable
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
        case .authenticationRequired:
            "Sign in to the isolated NexGenVideo Codex account before starting a turn."
        case .resumeIsolationUnavailable:
            "Codex CLI \(CodexAppServerContract.cliVersion) cannot safely restore the isolated tool surface."
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
        case amazonBedrock(managedCredentials: Bool)
    }

    let billing: Billing
}

@MainActor
protocol CodexAppServerDriving: AnyObject {
    var events: AsyncStream<CodexAppServerInbound> { get }
    var accountStatus: CodexAppServerAccountStatus? { get }

    func start(home: URL, scratch: URL) async throws
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
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.transportClosed() }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
        self.process = process
        stdin = input.fileHandleForWriting
        stdout = output.fileHandleForReading
        stderr = errors.fileHandleForReading

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
        case "amazonBedrock":
            accountStatus = .init(billing: .amazonBedrock(
                managedCredentials: details["usesCodexManagedCredentials"] as? Bool ?? false
            ))
        default:
            throw CodexAppServerError.malformedMessage
        }
    }

    func request(method: String, params: [String: Any]) async throws -> [String: Any] {
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
        process = nil
        stdin = nil
        stdout = nil
        stderr = nil
    }

    private func prepare(home: URL, scratch: URL) throws {
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let config = home.appendingPathComponent("config.toml")
        try Data(CodexAppServerContract.isolatedConfig.utf8).write(to: config, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
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
        process = nil
        stdin = nil
        stdout = nil
        stderr = nil
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
        Task { @MainActor [weak process] in
            try? await Task.sleep(for: .seconds(2))
            guard let process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
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
