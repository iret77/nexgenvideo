import AppKit
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
enum ProviderOAuthStore {
    static func account(_ p: GenerationProvider) -> String { "provider.\(p.rawValue).oauth" }

    static func isConnected(_ provider: GenerationProvider) -> Bool { load(provider) != nil }

    static func disconnect(_ provider: GenerationProvider) {
        KeychainStore.delete(account: account(provider))
        NotificationCenter.default.post(name: .providerKeysChanged, object: nil)
    }

    /// A currently-valid access token, refreshing transparently when expired. Nil when not signed in
    /// or a refresh failed (→ the UI prompts a fresh sign-in).
    static func validAccessToken(_ provider: GenerationProvider, now: Date = Date()) async -> String? {
        guard var tokens = load(provider) else { return nil }
        if tokens.isFresh(now: now) { return tokens.accessToken }
        guard let refresh = tokens.refreshToken else { return nil }
        do {
            let resp = try await postToken(tokens.tokenEndpoint, body: OAuthCore.refreshBody(refreshToken: refresh, clientID: tokens.clientID))
            tokens.accessToken = resp.accessToken
            if let r = resp.refreshToken { tokens.refreshToken = r }
            tokens.expiresAt = resp.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
            store(tokens, for: provider)
            return tokens.accessToken
        } catch { return nil }
    }

    static func load(_ provider: GenerationProvider) -> OAuthCore.StoredTokens? {
        guard let raw = KeychainStore.load(account: account(provider)),
              let data = raw.data(using: .utf8),
              let tokens = try? JSONDecoder().decode(OAuthCore.StoredTokens.self, from: data) else { return nil }
        return tokens
    }

    static func store(_ tokens: OAuthCore.StoredTokens, for provider: GenerationProvider) {
        guard let data = try? JSONEncoder().encode(tokens), let raw = String(data: data, encoding: .utf8) else { return }
        KeychainStore.save(raw, account: account(provider))
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
        store(OAuthCore.StoredTokens(
            accessToken: resp.accessToken, refreshToken: resp.refreshToken,
            expiresAt: resp.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            clientID: clientID, tokenEndpoint: server.tokenEndpoint), for: provider)
    }

    static func postToken(_ url: URL, body: String) async throws -> OAuthCore.TokenResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OAuthError.tokenExchangeFailed("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try JSONDecoder().decode(OAuthCore.TokenResponse.self, from: data)
    }

    static func getJSON<T: Decodable>(_ url: URL) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OAuthError.discoveryFailed("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Drives the browser step of the MCP OAuth flow. Verified on-device — a browser round-trip against a
/// live auth server can't run in CI; the deterministic protocol logic is in `OAuthCore` (tested).
@MainActor
final class ProviderOAuth: NSObject {
    /// Held for the duration of the flow — ASWebAuthenticationSession is deallocated (and the sign-in
    /// silently aborts) if nothing retains it.
    private var authSession: ASWebAuthenticationSession?

    func signIn(_ provider: GenerationProvider) async throws {
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

        let callback = try await presentAuth(url: authURL)
        guard let code = OAuthCore.authorizationCode(from: callback, expectedState: state) else {
            throw OAuthError.tokenExchangeFailed("no authorization code returned")
        }
        try await ProviderOAuthStore.exchangeAndStore(server: server, code: code, clientID: clientID, verifier: pkce.verifier, for: provider)
        NotificationCenter.default.post(name: .providerKeysChanged, object: nil)
    }

    private func presentAuth(url: URL) async throws -> URL {
        defer { authSession = nil }
        return try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "nexgenvideo") { callback, error in
                if let callback { cont.resume(returning: callback) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    cont.resume(throwing: OAuthError.userCancelled)
                } else {
                    cont.resume(throwing: OAuthError.tokenExchangeFailed(error?.localizedDescription ?? "unknown"))
                }
            }
            session.presentationContextProvider = self
            authSession = session   // retain for the duration of the flow
            if !session.start() { cont.resume(throwing: OAuthError.tokenExchangeFailed("couldn't open the sign-in window")) }
        }
    }

    private static func randomToken(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return OAuthCore.base64URL(data)
    }
}

extension ProviderOAuth: ASWebAuthenticationPresentationContextProviding {
    // The system calls this on the main thread; assume the isolation to read NSApp.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }
}
