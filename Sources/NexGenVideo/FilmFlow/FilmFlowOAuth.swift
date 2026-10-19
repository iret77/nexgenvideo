import Foundation

actor FilmFlowOAuth {
    static let shared = FilmFlowOAuth()
    static let scope = "openid email filmflow:read"
    static let issuer = URL(string: "https://near-waterfall-0833.customers.stytch.com")!
    private static let account = "connector.filmflow.https-app-filmflow-pro-api-mcp.oauth.v1"

    struct Connection: Codable, Equatable, Sendable {
        let id: UUID
        let resource: URL
        let issuer: URL
        var tokens: OAuthCore.StoredTokens
    }

    struct Authorization: Sendable {
        let id: UUID
        let url: URL
        let issuer: URL
        let tokenEndpoint: URL
        let clientID: String
        let state: String
        let verifier: String
    }

    private struct Resource: Decodable {
        let resource: URL
        let authorization_servers: [URL]
        let scopes_supported: [String]
    }

    private struct Server: Decodable {
        let issuer: URL
        let authorization_endpoint: URL
        let token_endpoint: URL
        let registration_endpoint: URL?
        let scopes_supported: [String]
        let code_challenge_methods_supported: [String]?
    }

    private var generation = UUID()
    private var refresh: Task<Void, Never>?

    init(dependencies: Dependencies? = nil) { self.dependencies = dependencies }

    var pendingRefreshRequests: Int { refreshWaiters.count }

    func disconnect() throws {
        generation = UUID()
        cancelRefresh()
        guard dependencies?.delete() ?? KeychainStore.delete(account: Self.account) else {
            throw FilmFlowFailure.message("Keychain could not remove the FilmFlow connection.")
        }
    }

    func begin() async throws -> Authorization {
        generation = UUID()
        let id = generation
        cancelRefresh()
        let resourceURL = FilmFlowHTTP.endpoint.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".well-known/oauth-protected-resource/api/mcp")
        let resource: Resource = try await get(resourceURL)
        guard resource.resource == FilmFlowHTTP.endpoint, resource.authorization_servers == [Self.issuer],
              Set(Self.scope.split(separator: " ").map(String.init)).isSubset(of: Set(resource.scopes_supported)),
              let issuer = resource.authorization_servers.first else {
            throw FilmFlowFailure.message("FilmFlow's authorization metadata does not match this resource.")
        }
        try FilmFlowHTTP.requireHTTPS(issuer)
        guard let metadataURL = OAuthCore.wellKnown("oauth-authorization-server", for: issuer) else {
            throw FilmFlowFailure.message("FilmFlow's authorization server address is invalid.")
        }
        let server: Server = try await get(metadataURL)
        guard server.issuer == issuer, let registration = server.registration_endpoint,
              Set(Self.scope.split(separator: " ").map(String.init)).isSubset(of: Set(server.scopes_supported)),
              server.code_challenge_methods_supported?.contains("S256") == true else {
            throw FilmFlowFailure.message("FilmFlow's authorization server does not support this sign-in.")
        }
        try FilmFlowHTTP.requireHTTPS(server.authorization_endpoint)
        guard [issuer.host, FilmFlowHTTP.endpoint.host].contains(server.authorization_endpoint.host) else {
            throw FilmFlowFailure.message("FilmFlow changed its sign-in origin.")
        }
        for url in [server.token_endpoint, registration] {
            try FilmFlowHTTP.requireHTTPS(url)
            guard url.host == issuer.host, url.port == issuer.port else {
                throw FilmFlowFailure.message("FilmFlow sign-in metadata changed its authorization origin.")
            }
        }
        var request = URLRequest(url: registration)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: OAuthCore.registrationBody(scope: Self.scope))
        let (bytes, response) = try await requestData(request)
        guard (200..<300).contains(response.statusCode),
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let client = object["client_id"] as? String, !client.isEmpty,
              object["client_secret"] == nil,
              (object["redirect_uris"] as? [String]) == [OAuthCore.redirectURI],
              object["token_endpoint_auth_method"] as? String == "none" else {
            throw FilmFlowFailure.message("FilmFlow could not register the native public client.")
        }
        try requireGeneration(id)
        let verifier = UUID().uuidString + UUID().uuidString
        let state = UUID().uuidString
        guard let url = OAuthCore.authorizationURL(authorizationEndpoint: server.authorization_endpoint,
            clientID: client, scope: Self.scope, state: state, pkce: .init(verifier: verifier), resource: FilmFlowHTTP.endpoint) else {
            throw FilmFlowFailure.message("FilmFlow could not create a sign-in request.")
        }
        return Authorization(id: id, url: url, issuer: issuer, tokenEndpoint: server.token_endpoint,
                             clientID: client, state: state, verifier: verifier)
    }

    func finish(_ authorization: Authorization, callback: URL) async throws -> Connection {
        try requireGeneration(authorization.id)
        guard callback.scheme == "nexgenvideo", callback.host == "oauth-callback",
              callback.user == nil, callback.password == nil,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.queryItems?.filter({ $0.name == "state" }).count == 1,
              components.queryItems?.filter({ $0.name == "code" }).count == 1,
              let code = OAuthCore.authorizationCode(from: callback, expectedState: authorization.state) else {
            throw FilmFlowFailure.message("FilmFlow sign-in was cancelled or returned an invalid callback.")
        }
        let token = try await tokenRequest(authorization.tokenEndpoint,
            body: OAuthCore.tokenExchangeBody(code: code, clientID: authorization.clientID, verifier: authorization.verifier))
        try requireGeneration(authorization.id)
        let connection = Connection(id: authorization.id, resource: FilmFlowHTTP.endpoint, issuer: authorization.issuer,
            tokens: .init(accessToken: token.accessToken, refreshToken: token.refreshToken,
                          expiresAt: token.expiresIn.map { Date().addingTimeInterval(Double($0)) },
                          clientID: authorization.clientID, tokenEndpoint: authorization.tokenEndpoint))
        try save(connection)
        return connection
    }

    func connection() async throws -> Connection {
        try Task.checkCancellation()
        let requestID = UUID()
        let connection = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Connection, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if refresh != nil { refreshWaiters[requestID] = continuation; return }
                guard let original = load(), original.resource == FilmFlowHTTP.endpoint, original.issuer == Self.issuer,
                      original.tokens.tokenEndpoint.host == Self.issuer.host, original.tokens.tokenEndpoint.scheme == "https",
                      original.tokens.tokenEndpoint.port == Self.issuer.port else {
                    continuation.resume(throwing: FilmFlowFailure.message("Connect to FilmFlow to read projects.")); return
                }
                if original.tokens.isFresh(now: Date()) { continuation.resume(returning: original); return }
                guard original.tokens.refreshToken?.isEmpty == false else {
                    continuation.resume(throwing: FilmFlowFailure.message("Sign in to FilmFlow again.")); return
                }
                refreshWaiters[requestID] = continuation
                startRefresh(original)
            }
        } onCancel: {
            Task { await self.cancelRefreshRequest(requestID) }
        }
        try Task.checkCancellation()
        return connection
    }

    private func startRefresh(_ original: Connection) {
        let id = generation
        refresh = Task {
            defer { dependencies?.didFinishRefresh?() }
            let result: Result<Connection, Error>
            do {
                guard let refreshToken = original.tokens.refreshToken else { throw CancellationError() }
                let token = try await tokenRequest(original.tokens.tokenEndpoint,
                    body: OAuthCore.refreshBody(refreshToken: refreshToken, clientID: original.tokens.clientID))
                try requireGeneration(id)
                guard load() == original else { throw FilmFlowFailure.message("The FilmFlow connection changed during refresh.") }
                var replacement = original
                replacement.tokens.accessToken = token.accessToken
                replacement.tokens.refreshToken = token.refreshToken ?? refreshToken
                replacement.tokens.expiresAt = token.expiresIn.map { Date().addingTimeInterval(Double($0)) }
                try save(replacement)
                result = .success(replacement)
            } catch { result = .failure(error) }
            guard generation == id else { return }
            refresh = nil
            let waiting = Array(refreshWaiters.values)
            refreshWaiters.removeAll()
            for continuation in waiting { continuation.resume(with: result) }
        }
    }

    private func cancelRefreshRequest(_ id: UUID) {
        refreshWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func cancelRefresh() {
        refresh?.cancel(); refresh = nil
        let waiting = Array(refreshWaiters.values)
        refreshWaiters.removeAll()
        for continuation in waiting { continuation.resume(throwing: CancellationError()) }
    }

    func requireCurrent(_ expected: Connection) throws {
        try Task.checkCancellation()
        guard load() == expected else { throw FilmFlowFailure.message("The FilmFlow connection changed. Read the project again.") }
    }

    private func requireGeneration(_ id: UUID) throws {
        try Task.checkCancellation()
        guard generation == id else { throw FilmFlowFailure.message("The FilmFlow sign-in was replaced or disconnected.") }
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (bytes, response) = try await requestData(URLRequest(url: url))
        guard response.statusCode == 200 else { throw FilmFlowFailure.message("FilmFlow sign-in metadata is unavailable.") }
        return try JSONDecoder().decode(T.self, from: bytes)
    }

    private func tokenRequest(_ url: URL, body: String) async throws -> OAuthCore.TokenResponse {
        try FilmFlowHTTP.requireHTTPS(url)
        guard url.host == Self.issuer.host, url.port == Self.issuer.port else {
            throw FilmFlowFailure.message("FilmFlow changed its token origin. Sign-in was stopped.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((body + "&" + OAuthCore.form(["resource": FilmFlowHTTP.endpoint.absoluteString])).utf8)
        let (bytes, response) = try await requestData(request)
        guard (200..<300).contains(response.statusCode),
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              (object["token_type"] as? String)?.lowercased() == "bearer" else {
            throw FilmFlowFailure.message("FilmFlow rejected sign-in. Connect again.")
        }
        let token = try JSONDecoder().decode(OAuthCore.TokenResponse.self, from: bytes)
        guard !token.accessToken.isEmpty, token.expiresIn.map({ $0 > 0 }) ?? true else {
            throw FilmFlowFailure.message("FilmFlow returned an unusable access token.")
        }
        return token
    }

    private func load() -> Connection? {
        if let dependencies { return dependencies.load() }
        guard let value = KeychainStore.load(account: Self.account) else { return nil }
        return try? JSONDecoder().decode(Connection.self, from: Data(value.utf8))
    }

    private func save(_ connection: Connection) throws {
        if let dependencies { try dependencies.save(connection); return }
        let bytes = try JSONEncoder().encode(connection)
        guard let text = String(data: bytes, encoding: .utf8), KeychainStore.save(text, account: Self.account) else {
            throw FilmFlowFailure.message("Keychain could not save the FilmFlow connection.")
        }
    }

    struct Response: Sendable {
        let bytes: Data
        let statusCode: Int
    }

    struct Dependencies: Sendable {
        let load: @Sendable () -> Connection?
        let save: @Sendable (Connection) throws -> Void
        let delete: @Sendable () -> Bool
        let request: @Sendable (URLRequest) async throws -> Response
        var didFinishRefresh: (@Sendable () -> Void)? = nil
    }

    private func requestData(_ request: URLRequest) async throws -> (Data, Response) {
        if let dependencies {
            let response = try await dependencies.request(request)
            return (response.bytes, response)
        }
        let (bytes, response) = try await FilmFlowHTTP.data(request, limit: 1_024 * 1_024)
        return (bytes, Response(bytes: bytes, statusCode: response.statusCode))
    }

    private let dependencies: Dependencies?
    private var refreshWaiters: [UUID: CheckedContinuation<Connection, Error>] = [:]
}
