import CryptoKit
import Foundation

/// Pure, CI-testable core of the MCP OAuth flow (RFC 8414 discovery, RFC 7591 dynamic client
/// registration, RFC 7636 PKCE, RFC 6749 authorization-code). No I/O, no browser — the device
/// orchestration lives in `ProviderOAuth`; everything here is deterministic and unit-tested.
enum OAuthCore {
    static let redirectURI = "nexgenvideo://oauth-callback"
    static let clientName = "NexGenVideo"

    // MARK: - PKCE (RFC 7636, S256)

    struct PKCE: Equatable {
        let verifier: String
        let challenge: String

        /// Build from a caller-supplied verifier (43–128 unreserved chars). The challenge is
        /// `base64url(sha256(verifier))` with no padding.
        init(verifier: String) {
            self.verifier = verifier
            let digest = SHA256.hash(data: Data(verifier.utf8))
            self.challenge = OAuthCore.base64URL(Data(digest))
        }
    }

    /// URL-safe base64 without padding — the encoding PKCE + JWK thumbprints use.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Discovery metadata (RFC 9728 protected-resource, RFC 8414 auth-server)

    struct ProtectedResourceMetadata: Decodable, Equatable {
        let authorizationServers: [URL]
        private enum CodingKeys: String, CodingKey { case authorizationServers = "authorization_servers" }
    }

    struct ServerMetadata: Decodable, Equatable {
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let registrationEndpoint: URL?
        let scopesSupported: [String]?
        private enum CodingKeys: String, CodingKey {
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case registrationEndpoint = "registration_endpoint"
            case scopesSupported = "scopes_supported"
        }
    }

    /// The well-known metadata URL for a base authorization-server URL (RFC 8414): the well-known
    /// segment is inserted at the ROOT, before any path — `https://h/tenant` →
    /// `https://h/.well-known/oauth-authorization-server/tenant`.
    static func wellKnown(_ suffix: String, for base: URL) -> URL? {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let path = comps.path
        comps.path = "/.well-known/\(suffix)" + (path == "/" ? "" : path)
        return comps.url
    }

    // MARK: - Authorization request (RFC 6749 §4.1 + PKCE + RFC 8707 resource)

    static func authorizationURL(
        authorizationEndpoint: URL, clientID: String, scope: String?, state: String,
        pkce: PKCE, resource: URL
    ) -> URL? {
        guard var comps = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false) else { return nil }
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resource.absoluteString),
        ]
        if let scope, !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
        comps.queryItems = (comps.queryItems ?? []) + items
        return comps.url
    }

    /// Extract the `code` from the OAuth callback URL, validating `state`. Returns nil on a mismatch or
    /// an error callback (so a spoofed/failed redirect never yields a code).
    static func authorizationCode(from callback: URL, expectedState: String) -> String? {
        guard let comps = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { return nil }
        let items = comps.queryItems ?? []
        guard items.first(where: { $0.name == "error" })?.value == nil else { return nil }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else { return nil }
        return items.first(where: { $0.name == "code" })?.value
    }

    // MARK: - Dynamic client registration + token bodies

    static func registrationBody(scope: String?) -> [String: Any] {
        var body: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        if let scope, !scope.isEmpty { body["scope"] = scope }
        return body
    }

    static func tokenExchangeBody(code: String, clientID: String, verifier: String) -> String {
        form([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    static func refreshBody(refreshToken: String, clientID: String) -> String {
        form([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    static func form(_ params: [String: String]) -> String {
        params.sorted { $0.key < $1.key }
            .map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }
            .joined(separator: "&")
    }

    private static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - Token response + storage

    struct TokenResponse: Decodable, Equatable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?
        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    /// Persisted per provider so a session survives relaunch and can refresh without a new sign-in.
    struct StoredTokens: Codable, Equatable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var clientID: String
        var tokenEndpoint: URL

        /// Fresh enough to use now (60 s safety margin), else it must be refreshed.
        func isFresh(now: Date) -> Bool {
            guard let expiresAt else { return true }   // no expiry advertised → treat as long-lived
            return expiresAt.timeIntervalSince(now) > 60
        }
    }
}
