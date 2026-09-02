import Foundation
import MCP
import Network

actor MCPHTTPServer {
    static let agentSessionHeader = "X-NexGen-Agent-Session"
    static let agentTurnHeader = "X-NexGen-Agent-Turn"

    final class SessionOrigin: @unchecked Sendable {
        private let lock = NSLock()
        private let mcpSessionID: UUID
        private var chatSessionID: UUID?

        init(mcpSessionID: UUID) {
            self.mcpSessionID = mcpSessionID
        }

        var value: ToolCallOrigin {
            lock.withLock {
                chatSessionID.map {
                    .embeddedRuntime(
                        chatSessionID: $0,
                        mcpSessionID: mcpSessionID
                    )
                } ?? .externalMCP(sessionID: mcpSessionID)
            }
        }

        func bind(chatSessionID: UUID?) {
            lock.withLock {
                self.chatSessionID = chatSessionID
            }
        }

        func accepts(chatSessionID: UUID?) -> Bool {
            lock.withLock {
                self.chatSessionID == chatSessionID
            }
        }
    }

    private struct SDKSession {
        let id: UUID
        let server: Server
        let transport: StatelessHTTPServerTransport
        let origin: SessionOrigin
        var inFlight = 0
        var didInitialize = false
        var retired = false
    }

    private enum ConnectionEvent: Sendable {
        case failed(String)
        case cancelled
        case unchanged
    }

    private enum ListenerEvent: Sendable {
        case ready
        case failed(String)
        case cancelled
        case unchanged
    }

    private static let maxHeaderBytes = 65_536
    private static let maxRequestBytes = 20 * 1_024 * 1_024

    private let port: UInt16
    private let makeServer: @Sendable (SessionOrigin) async -> Server
    private let modernHandler: @Sendable (
        MCP20260728.Request,
        ToolCallOrigin
    ) async -> MCP20260728.HandlerResult
    private let onFailure: @Sendable (String) async -> Void
    private var listener: NWListener?
    private var sessions: [UUID: SDKSession] = [:]
    private var currentSessionID: UUID?
    private var sessionRotationOwner: UUID?
    private var sessionRotationWaiters: [CheckedContinuation<Void, Never>] = []
    private var connections: [UUID: NWConnection] = [:]
    private var startupContinuation: CheckedContinuation<Void, Error>?
    private var lifecycleGeneration = 0
    private var isStarting = false

    init(
        port: UInt16,
        makeServer: @escaping @Sendable (SessionOrigin) async -> Server,
        modernHandler: @escaping @Sendable (
            MCP20260728.Request,
            ToolCallOrigin
        ) async -> MCP20260728.HandlerResult = { request, _ in
            .error(
                status: 404,
                code: -32601,
                message: "Method not found: \(request.method)"
            )
        },
        onFailure: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.port = port
        self.makeServer = makeServer
        self.modernHandler = modernHandler
        self.onFailure = onFailure
    }

    func start() async throws {
        Log.mcp.info("listener start port=\(self.port)")
        guard listener == nil, !isStarting else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        isStarting = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            isStarting = false
            Log.mcp.fault("invalid port \(self.port)")
            throw NSError(
                domain: "MCPHTTPServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"]
            )
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: endpointPort
        )
        let initialSession: SDKSession
        do {
            initialSession = try await makeSession()
        } catch {
            if lifecycleGeneration == generation {
                isStarting = false
            }
            throw error
        }
        guard isStarting, lifecycleGeneration == generation else {
            await initialSession.transport.disconnect()
            throw CancellationError()
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            isStarting = false
            await initialSession.transport.disconnect()
            throw error
        }
        sessions[initialSession.id] = initialSession
        currentSessionID = initialSession.id
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let event: ListenerEvent = switch state {
            case .ready: .ready
            case .failed(let error): .failed(error.localizedDescription)
            case .cancelled: .cancelled
            default: .unchanged
            }
            Task {
                await self.listenerStateChanged(
                    event,
                    generation: generation
                )
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.accept(connection) }
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            startupContinuation = continuation
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func stop() async {
        lifecycleGeneration &+= 1
        isStarting = false
        startupContinuation?.resume(
            throwing: CancellationError()
        )
        startupContinuation = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        await disconnectAllSessions()
    }

    private func listenerStateChanged(
        _ event: ListenerEvent,
        generation: Int
    ) async {
        guard lifecycleGeneration == generation else { return }
        switch event {
        case .ready:
            isStarting = false
            startupContinuation?.resume()
            startupContinuation = nil
        case .failed(let message):
            let failedAfterStartup = startupContinuation == nil
            lifecycleGeneration &+= 1
            isStarting = false
            let error = NSError(
                domain: "MCPHTTPServer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            startupContinuation?.resume(throwing: error)
            startupContinuation = nil
            Log.mcp.error("listener failed error=\(message)")
            listener?.cancel()
            listener = nil
            for connection in connections.values {
                connection.cancel()
            }
            connections.removeAll()
            await disconnectAllSessions()
            if failedAfterStartup {
                await onFailure(message)
            }
        case .cancelled:
            isStarting = false
            startupContinuation?.resume(throwing: CancellationError())
            startupContinuation = nil
        case .unchanged:
            break
        }
    }

    private func makeSession() async throws -> SDKSession {
        let id = UUID()
        let origin = SessionOrigin(mcpSessionID: id)
        let pipeline = StandardValidationPipeline(validators: [
            OriginValidator.localhost(port: Int(port)),
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
        let transport = StatelessHTTPServerTransport(
            validationPipeline: pipeline
        )
        let server = await makeServer(origin)
        do {
            try await server.start(transport: transport)
        } catch {
            await transport.disconnect()
            throw error
        }
        return SDKSession(
            id: id,
            server: server,
            transport: transport,
            origin: origin
        )
    }

    private func acquireSession(isInitialize: Bool) async throws -> SDKSession {
        while sessionRotationOwner != nil {
            await withCheckedContinuation {
                sessionRotationWaiters.append($0)
            }
        }
        guard var session = currentSessionID.flatMap({ sessions[$0] }) else {
            throw NSError(
                domain: "MCPHTTPServer",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "MCP session unavailable"]
            )
        }

        var retiredTransport: StatelessHTTPServerTransport?
        var rotationOwner: UUID?
        if isInitialize, session.didInitialize {
            let owner = UUID()
            sessionRotationOwner = owner
            rotationOwner = owner
            let generation = lifecycleGeneration
            let fresh: SDKSession
            do {
                fresh = try await makeSession()
            } catch {
                finishSessionRotation(owner: owner)
                throw error
            }
            guard listener != nil, lifecycleGeneration == generation else {
                await fresh.transport.disconnect()
                finishSessionRotation(owner: owner)
                throw CancellationError()
            }
            if var previous = currentSessionID.flatMap({ sessions[$0] }) {
                previous.retired = true
                if previous.inFlight == 0 {
                    sessions.removeValue(forKey: previous.id)
                    retiredTransport = previous.transport
                } else {
                    sessions[previous.id] = previous
                }
            }
            sessions[fresh.id] = fresh
            currentSessionID = fresh.id
            session = fresh
        }

        session.didInitialize = session.didInitialize || isInitialize
        session.inFlight += 1
        sessions[session.id] = session
        if let rotationOwner {
            finishSessionRotation(owner: rotationOwner)
        }
        if let retiredTransport {
            await retiredTransport.disconnect()
        }
        return session
    }

    private func releaseSession(_ id: UUID) async {
        guard var session = sessions[id] else { return }
        session.inFlight = max(0, session.inFlight - 1)
        if session.retired, session.inFlight == 0 {
            sessions.removeValue(forKey: id)
            await session.transport.disconnect()
        } else {
            sessions[id] = session
        }
    }

    private func finishSessionRotation(owner: UUID) {
        guard sessionRotationOwner == owner else { return }
        sessionRotationOwner = nil
        resumeSessionRotationWaiters()
    }

    private func invalidateSessionRotation() {
        sessionRotationOwner = nil
        resumeSessionRotationWaiters()
    }

    private func resumeSessionRotationWaiters() {
        let waiters = sessionRotationWaiters
        sessionRotationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func disconnectAllSessions() async {
        let transports = sessions.values.map(\.transport)
        sessions.removeAll()
        currentSessionID = nil
        invalidateSessionRotation()
        for transport in transports {
            await transport.disconnect()
        }
    }

    private nonisolated static func isInitializeRequest(
        method: String,
        body: Data?
    ) -> Bool {
        guard method.uppercased() == "POST",
              let body,
              let raw = try? JSONSerialization.jsonObject(with: body)
        else { return false }
        if let object = raw as? [String: Any] {
            return object["method"] as? String == Initialize.name
        }
        guard let batch = raw as? [[String: Any]] else { return false }
        return batch.contains {
            $0["method"] as? String == Initialize.name
        }
    }

    private func accept(_ connection: NWConnection) {
        guard currentSessionID != nil else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let event: ConnectionEvent = switch state {
            case .failed(let error): .failed(error.localizedDescription)
            case .cancelled: .cancelled
            default: .unchanged
            }
            Task { await self.connectionStateChanged(id: id, event: event) }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receive(
            id: id,
            connection: connection,
            buffered: Data()
        )
    }

    private func connectionStateChanged(id: UUID, event: ConnectionEvent) {
        switch event {
        case .failed(let message):
            Log.mcp.warning("connection failed error=\(message)")
            finishConnection(id: id)
        case .cancelled:
            connections.removeValue(forKey: id)
        case .unchanged:
            break
        }
    }

    private func receive(
        id: UUID,
        connection: NWConnection,
        buffered: Data
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let errorMessage = error?.localizedDescription
            Task {
                await self.received(
                    id: id,
                    connection: connection,
                    buffered: buffered,
                    data: data,
                    isComplete: isComplete,
                    errorMessage: errorMessage
                )
            }
        }
    }

    private func received(
        id: UUID,
        connection: NWConnection,
        buffered: Data,
        data: Data?,
        isComplete: Bool,
        errorMessage: String?
    ) async {
        if let errorMessage {
            Log.mcp.warning("receive failed error=\(errorMessage)")
            finishConnection(id: id)
            return
        }
        var nextBuffer = buffered
        if let data {
            nextBuffer.append(data)
        }
        guard nextBuffer.count <= Self.maxRequestBytes else {
            await sendError(
                status: 413,
                on: connection
            )
            finishConnection(id: id)
            return
        }
        if isComplete, nextBuffer.isEmpty {
            finishConnection(id: id)
            return
        }
        await process(
            id: id,
            connection: connection,
            buffered: nextBuffer,
            isComplete: isComplete
        )
    }

    private func process(
        id: UUID,
        connection: NWConnection,
        buffered: Data,
        isComplete: Bool
    ) async {
        switch Self.decodeRequest(buffered) {
        case .incomplete:
            if isComplete {
                await sendError(status: 400, on: connection)
                finishConnection(id: id)
            } else {
                receive(
                    id: id,
                    connection: connection,
                    buffered: buffered
                )
            }
        case .invalid(let status):
            await sendError(status: status, on: connection)
            finishConnection(id: id)
        case .complete(let request, let remaining):
            await handle(
                request: request,
                id: id,
                connection: connection,
                remaining: remaining
            )
        }
    }

    private func handle(
        request: HTTPRequest,
        id: UUID,
        connection: NWConnection,
        remaining: Data
    ) async {
        let method = request.method.uppercased()
        let path = request.path ?? "/"
        Log.mcp.info("request method=\(method) path=\(path)")

        let response: HTTPResponse
        if path == "/.well-known/oauth-protected-resource" {
            let body = Data("{\"resource\":\"http://127.0.0.1:\(port)\"}".utf8)
            response = .data(body, headers: ["Content-Type": "application/json"])
        } else if path == "/mcp" || path == "/" {
            if MCP20260728.isModernRequest(
                body: request.body,
                headers: request.headers
            ) {
                let result = await handleModern(request)
                await writeDataResponse(
                    status: result.status,
                    headers: result.headers,
                    body: result.body,
                    id: id,
                    connection: connection,
                    remaining: remaining
                )
                return
            }
            do {
                let requestMethod = request.method
                let requestBody = request.body
                let isInitialize = await Task.detached(priority: .userInitiated) {
                    Self.isInitializeRequest(
                        method: requestMethod,
                        body: requestBody
                    )
                }.value
                let session = try await acquireSession(
                    isInitialize: isInitialize
                )
                if isInitialize {
                    session.origin.bind(
                        chatSessionID: Self.agentChatSessionID(request: request)
                    )
                }
                if isInitialize || session.origin.accepts(
                    chatSessionID: Self.agentChatSessionID(request: request)
                ) {
                    response = await session.transport.handleRequest(request)
                } else {
                    response = .error(
                        statusCode: 409,
                        .invalidRequest(
                            "MCP client identity changed; initialize a fresh session."
                        )
                    )
                }
                await releaseSession(session.id)
            } catch {
                Log.mcp.error(
                    "session acquisition failed error=\(error.localizedDescription)"
                )
                response = .error(
                    statusCode: 500,
                    .internalError(error.localizedDescription)
                )
            }
        } else {
            response = .error(
                statusCode: 404,
                .invalidRequest("Not Found")
            )
        }

        guard case .stream = response else {
            await writeDataResponse(
                response,
                id: id,
                connection: connection,
                remaining: remaining
            )
            return
        }
        Log.mcp.fault("stateless transport returned an unexpected stream response")
        await sendError(status: 500, on: connection)
        finishConnection(id: id)
    }

    private func handleModern(
        _ request: HTTPRequest
    ) async -> MCP20260728.HTTPResult {
        guard request.method.uppercased() == "POST" else {
            return MCP20260728.error(
                status: 405,
                id: .null,
                code: -32600,
                message: "The MCP endpoint accepts POST requests only."
            )
        }
        guard let contentType = MCP20260728.header(
            request.headers,
            named: "Content-Type"
        )?.lowercased(), contentType.contains("application/json") else {
            return MCP20260728.error(
                status: 415,
                id: .null,
                code: -32600,
                message: "Content-Type must be application/json."
            )
        }
        let accepted = MCP20260728.header(
            request.headers,
            named: "Accept"
        )?.lowercased() ?? ""
        guard accepted.contains("application/json"),
              accepted.contains("text/event-stream") else {
            return MCP20260728.error(
                status: 406,
                id: .null,
                code: -32600,
                message: "Accept must include application/json and text/event-stream."
            )
        }
        if let origin = MCP20260728.header(request.headers, named: "Origin"),
           !Self.isAllowedOrigin(origin, port: port) {
            return MCP20260728.error(
                status: 403,
                id: .null,
                code: -32600,
                message: "Origin is not allowed."
            )
        }

        let logicalTurnID = Self.agentTurnID(request: request) ?? UUID()
        let origin = Self.toolCallOrigin(
            request: request,
            mcpSessionID: logicalTurnID
        )
        return await MCP20260728.handle(
            body: request.body,
            headers: request.headers
        ) { [modernHandler] request in
            await modernHandler(request, origin)
        }
    }

    private func writeDataResponse(
        _ response: HTTPResponse,
        id: UUID,
        connection: NWConnection,
        remaining: Data
    ) async {
        await writeDataResponse(
            status: response.statusCode,
            headers: response.headers,
            body: response.bodyData ?? Data(),
            id: id,
            connection: connection,
            remaining: remaining
        )
    }

    private func writeDataResponse(
        status: Int,
        headers: [String: String],
        body: Data,
        id: UUID,
        connection: NWConnection,
        remaining: Data
    ) async {
        var headers = headers
        headers["Content-Length"] = "\(body.count)"
        headers["Connection"] = "keep-alive"
        var data = Self.responseHead(
            status: status,
            headers: headers
        )
        data.append(body)

        do {
            try await Self.send(data, on: connection)
            Log.mcp.info("response status=\(status)")
        } catch {
            Log.mcp.warning("response send failed error=\(error.localizedDescription)")
            finishConnection(id: id)
            return
        }

        if remaining.isEmpty {
            receive(
                id: id,
                connection: connection,
                buffered: Data()
            )
        } else {
            await process(
                id: id,
                connection: connection,
                buffered: remaining,
                isComplete: false
            )
        }
    }

    private func sendError(status: Int, on connection: NWConnection) async {
        let data = Self.responseHead(
            status: status,
            headers: [
                "Content-Length": "0",
                "Connection": "close",
            ]
        )
        try? await Self.send(data, on: connection)
    }

    private func finishConnection(id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }

    private nonisolated static func send(
        _ data: Data,
        on connection: NWConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    enum RequestDecode {
        case incomplete
        case invalid(status: Int)
        case complete(HTTPRequest, remaining: Data)
    }

    nonisolated static func decodeRequest(_ data: Data) -> RequestDecode {
        let delimiter = Data([13, 10, 13, 10])
        guard let delimiterRange = data.range(of: delimiter) else {
            return data.count > maxHeaderBytes
                ? .invalid(status: 431)
                : .incomplete
        }
        guard delimiterRange.lowerBound <= maxHeaderBytes,
              let headerText = String(
                data: data[..<delimiterRange.lowerBound],
                encoding: .utf8
              )
        else {
            return .invalid(status: 400)
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .invalid(status: 400)
        }
        let tokens = requestLine.split(separator: " ", maxSplits: 2)
        guard tokens.count == 3 else {
            return .invalid(status: 400)
        }

        var headers: [String: String] = [:]
        var normalizedHeaderNames: Set<String> = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(status: 400)
            }
            let rawName = String(line[..<colon])
            let name = rawName.trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard rawName == name,
                  !name.isEmpty,
                  normalizedHeaderNames.insert(name.lowercased()).inserted
            else {
                return .invalid(status: 400)
            }
            headers[name] = value
        }
        if let transferEncoding = header(headers, named: "Transfer-Encoding"),
           transferEncoding.lowercased() != "identity" {
            return .invalid(status: 501)
        }
        let contentLength: Int
        if let value = header(headers, named: "Content-Length") {
            guard let parsed = Int(value), parsed >= 0 else {
                return .invalid(status: 400)
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        let bodyStart = delimiterRange.upperBound
        guard bodyStart <= maxRequestBytes,
              contentLength <= maxRequestBytes - bodyStart
        else {
            return .invalid(status: 413)
        }
        let requestEnd = bodyStart + contentLength
        guard data.count >= requestEnd else {
            return .incomplete
        }

        let rawPath = String(tokens[1])
        let path = rawPath.split(separator: "?", maxSplits: 1)
            .first
            .map(String.init) ?? rawPath
        let body = contentLength == 0
            ? nil
            : data.subdata(in: bodyStart..<requestEnd)
        let request = HTTPRequest(
            method: String(tokens[0]),
            headers: headers,
            body: body,
            path: path
        )
        let remaining = requestEnd == data.count
            ? Data()
            : data.subdata(in: requestEnd..<data.count)
        return .complete(request, remaining: remaining)
    }

    private nonisolated static func header(
        _ headers: [String: String],
        named name: String
    ) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    nonisolated static func toolCallOrigin(
        request: HTTPRequest,
        mcpSessionID: UUID
    ) -> ToolCallOrigin {
        if let chatSessionID = agentChatSessionID(request: request) {
            return .embeddedRuntime(
                chatSessionID: chatSessionID,
                mcpSessionID: mcpSessionID
            )
        }
        return .externalMCP(sessionID: mcpSessionID)
    }

    private nonisolated static func agentTurnID(
        request: HTTPRequest
    ) -> UUID? {
        header(request.headers, named: agentTurnHeader)
            .flatMap(UUID.init(uuidString:))
    }

    private nonisolated static func agentChatSessionID(
        request: HTTPRequest
    ) -> UUID? {
        header(request.headers, named: agentSessionHeader)
            .flatMap(UUID.init(uuidString:))
    }

    private nonisolated static func isAllowedOrigin(
        _ value: String,
        port: UInt16
    ) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost",
              components.port == Int(port),
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil
        else { return false }
        return true
    }

    private nonisolated static func responseHead(
        status: Int,
        headers: [String: String]
    ) -> Data {
        var text = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    private nonisolated static func statusText(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        default: "Unknown"
        }
    }
}
