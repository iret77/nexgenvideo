import AuthenticationServices
import Foundation
import Security

/// OAuth error surface shared by the store and the flow.
enum OAuthError: LocalizedError {
    case notOAuth
    case discoveryFailed(String)
    case registrationFailed(String)
    case userCancelled
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notOAuth: return "This provider doesn't use OAuth."
        case .discoveryFailed(let m): return "Couldn't reach the provider's sign-in service: \(m)"
        case .registrationFailed(let m): return "Sign-in setup failed: \(m)"
        case .userCancelled: return "Sign-in was cancelled."
        case .tokenExchangeFailed(let m): return "Sign-in didn't complete: \(m)"
        }
    }
}

/// Token persistence + refresh + the network steps of the MCP OAuth flow (RFC 9728 discovery, RFC
/// 7591 registration, RFC 6749 token exchange). Nonisolated so sync activation (`ProviderMCP`) and the
/// async MCP client can consult it off the main actor. The browser step lives in `ProviderOAuth`.
extension Notification.Name {
    static let providerOAuthStateChanged = Notification.Name("providerOAuthStateChanged")
}

enum ProviderOAuthStore {
    // Token and rejection state always holds the same lock.
    private final class Persistence: @unchecked Sendable {
        let lock = NSLock()
        var rejected: [GenerationProvider: OAuthCore.StoredTokens] = [:]
    }
    private static let persistence = Persistence()
    private static let refreshCoordinator = RefreshCoordinator()

    private actor RefreshCoordinator {
        private var active: [GenerationProvider: (UUID, Task<String?, Never>)] = [:]

        func token(_ provider: GenerationProvider, now: Date) async -> String? {
            if let current = active[provider] { return await current.1.value }
            let id = UUID()
            let task = Task { await ProviderOAuthStore.refreshAccessToken(provider, now: now) }
            active[provider] = (id, task)
            let result = await task.value
            if active[provider]?.0 == id { active[provider] = nil }
            return result
        }
    }
    static func account(_ p: GenerationProvider) -> String { "provider.\(p.rawValue).oauth" }

    static func isConnected(_ provider: GenerationProvider, now: Date = Date()) -> Bool {
        guard let tokens = loadUsable(provider) else { return false }
        return tokens.sessionState(now: now) != .reauthenticationRequired
    }

    @discardableResult
    static func disconnect(_ provider: GenerationProvider) -> Bool {
        guard persistence.lock.withLock({
            guard KeychainStore.delete(account: account(provider)) else { return false }
            persistence.rejected[provider] = nil
            return true
        }) else { return false }
        NotificationCenter.default.post(name: .providerKeysChanged, object: nil)
        return true
    }

    /// A currently-valid access token, refreshing transparently when expired. Nil when not signed in
    /// or a refresh failed (→ the UI prompts a fresh sign-in).
    static func validAccessToken(_ provider: GenerationProvider, now: Date = Date()) async -> String? {
        await refreshCoordinator.token(provider, now: now)
    }

    private static func refreshAccessToken(_ provider: GenerationProvider, now: Date) async -> String? {
        guard let original = loadUsable(provider) else { return nil }
        var tokens = original
        if tokens.isFresh(now: now) { return tokens.accessToken }
        guard let refresh = tokens.refreshToken, !refresh.isEmpty else { return nil }
        do {
            let resp = try await postToken(tokens.tokenEndpoint, body: OAuthCore.refreshBody(refreshToken: refresh, clientID: tokens.clientID))
            tokens.accessToken = resp.accessToken
            if let r = resp.refreshToken { tokens.refreshToken = r }
            tokens.expiresAt = resp.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
            guard replace(original, with: tokens, for: provider) else {
                return freshToken(provider, now: now)
            }
            return tokens.accessToken
        } catch let error as TokenRequestError where error.requiresReauthentication {
            if replace(original, with: nil, for: provider) {
                NotificationCenter.default.post(name: .providerKeysChanged, object: nil)
                Log.generation.notice("OAuth refresh rejected for \(provider.rawValue); a new sign-in is required")
            } else if load(provider) == original {
                NotificationCenter.default.post(name: .providerOAuthStateChanged, object: nil)
                Log.generation.error("Rejected OAuth sign-in for \(provider.rawValue) could not be removed from Keychain")
            }
            return freshToken(provider, now: now)
        } catch {
            Log.generation.notice(
                "OAuth refresh failed for \(provider.rawValue): \(error.localizedDescription)"
            )
            return nil
        }
    }

    static func load(_ provider: GenerationProvider) -> OAuthCore.StoredTokens? {
        persistence.lock.withLock { loadUnlocked(provider) }
    }

    private static func loadUsable(_ provider: GenerationProvider) -> OAuthCore.StoredTokens? {
        persistence.lock.withLock {
            guard let tokens = loadUnlocked(provider), persistence.rejected[provider] != tokens else { return nil }
            return tokens
        }
    }

    static func failureMessage(_ provider: GenerationProvider) -> String? {
        persistence.lock.withLock {
            guard let tokens = loadUnlocked(provider), persistence.rejected[provider] == tokens else { return nil }
            return "Sign in again. Keychain could not remove the rejected sign-in."
        }
    }

    private static func loadUnlocked(_ provider: GenerationProvider) -> OAuthCore.StoredTokens? {
        guard let raw = KeychainStore.load(account: account(provider)),
              let data = raw.data(using: .utf8),
              let tokens = try? JSONDecoder().decode(OAuthCore.StoredTokens.self, from: data) else { return nil }
        return tokens
    }

    @discardableResult
    static func store(_ tokens: OAuthCore.StoredTokens, for provider: GenerationProvider) -> Bool {
        persistence.lock.withLock { storeUnlocked(tokens, for: provider) }
    }

    private static func replace(_ expected: OAuthCore.StoredTokens, with replacement: OAuthCore.StoredTokens?, for provider: GenerationProvider) -> Bool {
        persistence.lock.withLock {
            guard loadUnlocked(provider) == expected else { return false }
            if let replacement { return storeUnlocked(replacement, for: provider) }
            persistence.rejected[provider] = expected
            return KeychainStore.delete(account: account(provider))
        }
    }

    private static func freshToken(_ provider: GenerationProvider, now: Date) -> String? {
        guard let tokens = loadUsable(provider), tokens.isFresh(now: now) else { return nil }
        return tokens.accessToken
    }

    private static func storeUnlocked(_ tokens: OAuthCore.StoredTokens, for provider: GenerationProvider) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens), let raw = String(data: data, encoding: .utf8) else { return false }
        guard KeychainStore.save(raw, account: account(provider)) else { return false }
        persistence.rejected[provider] = nil
        return true
    }

    // MARK: - Network steps

    static func discover(endpoint: URL) async throws -> OAuthCore.ServerMetadata {
        var authServer = endpoint
        if let prURL = OAuthCore.wellKnown("oauth-protected-resource", for: endpoint),
           let pr: OAuthCore.ProtectedResourceMetadata = try? await getJSON(prURL),
           let first = pr.authorizationServers.first {
            authServer = first
        }
        for suffix in ["oauth-authorization-server", "openid-configuration"] {
            if let url = OAuthCore.wellKnown(suffix, for: authServer),
               let meta: OAuthCore.ServerMetadata = try? await getJSON(url) {
                return meta
            }
        }
        throw OAuthError.discoveryFailed(authServer.host ?? endpoint.absoluteString)
    }

    static func register(_ server: OAuthCore.ServerMetadata) async throws -> String {
        guard let regURL = server.registrationEndpoint else {
            throw OAuthError.registrationFailed("the provider doesn't support dynamic client registration")
        }
        var req = URLRequest(url: regURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: OAuthCore.registrationBody(scope: server.scopesSupported?.joined(separator: " ")))
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = obj["client_id"] as? String else {
            throw OAuthError.registrationFailed("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return clientID
    }

    static func exchangeAndStore(
        server: OAuthCore.ServerMetadata, code: String, clientID: String, verifier: String,
        for provider: GenerationProvider, now: Date = Date()
    ) async throws {
        let resp = try await postToken(server.tokenEndpoint, body: OAuthCore.tokenExchangeBody(code: code, clientID: clientID, verifier: verifier))
        guard store(OAuthCore.StoredTokens(
            accessToken: resp.accessToken, refreshToken: resp.refreshToken,
            expiresAt: resp.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            clientID: clientID, tokenEndpoint: server.tokenEndpoint), for: provider) else {
            throw OAuthError.tokenExchangeFailed("Keychain could not save this sign-in. Try again.")
        }
    }

    private struct TokenRequestError: LocalizedError {
        let status: Int
        let oauthCode: String?
        let detail: String?

        var requiresReauthentication: Bool {
            status == 401
                || ["invalid_grant", "invalid_token", "unauthorized_client"]
                    .contains(oauthCode ?? "")
        }

        var errorDescription: String? {
            let suffix = detail.map { ": \($0)" } ?? ""
            return "Token request failed with HTTP \(status)\(suffix)"
        }
    }

    static func postToken(_ url: URL, body: String) async throws -> OAuthCore.TokenResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw TokenRequestError(
                status: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                oauthCode: payload?["error"] as? String,
                detail: payload?["error_description"] as? String
            )
        }
        let token = try JSONDecoder().decode(OAuthCore.TokenResponse.self, from: data)
        guard !token.accessToken.isEmpty else {
            throw OAuthError.tokenExchangeFailed("the provider returned an empty access token")
        }
        return token
    }

    static func getJSON<T: Decodable>(_ url: URL) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OAuthError.discoveryFailed("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Drives provider OAuth around a browser callback supplied by SwiftUI's `webAuthenticationSession`.
@MainActor
enum ProviderOAuth {
    static func signIn(
        _ provider: GenerationProvider,
        authenticate: (URL) async throws -> URL
    ) async throws {
        guard let cap = provider.mcpCapability, cap.auth == .oauth else { throw OAuthError.notOAuth }
        let endpoint = ProviderMCP.resolvedEndpoint(provider) ?? cap.defaultURL

        let server = try await ProviderOAuthStore.discover(endpoint: endpoint)
        let clientID = try await ProviderOAuthStore.register(server)
        let pkce = OAuthCore.PKCE(verifier: Self.randomToken(64))
        let state = Self.randomToken(32)
        guard let authURL = OAuthCore.authorizationURL(
            authorizationEndpoint: server.authorizationEndpoint, clientID: clientID,
            scope: server.scopesSupported?.joined(separator: " "), state: state, pkce: pkce, resource: endpoint)
        else { throw OAuthError.discoveryFailed("bad authorization endpoint") }

        let callback = try await browserCallback(authURL, authenticate: authenticate)
        guard let code = OAuthCore.authorizationCode(from: callback, expectedState: state) else {
            throw OAuthError.tokenExchangeFailed("no authorization code returned")
        }
        try await ProviderOAuthStore.exchangeAndStore(server: server, code: code, clientID: clientID, verifier: pkce.verifier, for: provider)
        NotificationCenter.default.post(name: .providerKeysChanged, object: nil)
    }

    static func browserCallback(
        _ authorizationURL: URL,
        authenticate: (URL) async throws -> URL
    ) async throws -> URL {
        do {
            return try await authenticate(authorizationURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OAuthError {
            throw error
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                throw OAuthError.userCancelled
            }
            throw OAuthError.tokenExchangeFailed(error.localizedDescription)
        }
    }

    private static func randomToken(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return OAuthCore.base64URL(data)
    }
}
