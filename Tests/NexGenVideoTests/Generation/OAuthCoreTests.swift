import Foundation
import Testing
@testable import NexGenVideo

/// The deterministic OAuth protocol logic (PKCE, discovery-URL building, auth-URL, callback parsing,
/// metadata decode) + the provider auth-capability model. The browser round-trip is device-verified;
/// everything here is CI-testable.
@Suite("OAuth core + provider auth")
struct OAuthCoreTests {
    // MARK: - PKCE (RFC 7636 Appendix B vector)

    @Test("PKCE S256 matches the RFC 7636 test vector")
    func pkceVector() {
        let pkce = OAuthCore.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("base64url has no padding or +/ characters")
    func base64url() {
        let s = OAuthCore.base64URL(Data([0xFB, 0xFF, 0xBF]))
        #expect(!s.contains("+") && !s.contains("/") && !s.contains("="))
    }

    // MARK: - Well-known discovery URL (RFC 8414: well-known inserted at the root)

    @Test("well-known segment goes to the root, before any tenant path")
    func wellKnown() {
        let tenant = OAuthCore.wellKnown("oauth-authorization-server", for: URL(string: "https://auth.example.com/tenant1")!)
        #expect(tenant?.absoluteString == "https://auth.example.com/.well-known/oauth-authorization-server/tenant1")
        let root = OAuthCore.wellKnown("oauth-authorization-server", for: URL(string: "https://auth.example.com")!)
        #expect(root?.absoluteString == "https://auth.example.com/.well-known/oauth-authorization-server")
    }

    // MARK: - Authorization request + callback

    @Test("authorization URL carries PKCE, redirect, state and resource")
    func authorizationURL() throws {
        let pkce = OAuthCore.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = try #require(OAuthCore.authorizationURL(
            authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
            clientID: "abc", scope: "generate", state: "xyz", pkce: pkce,
            resource: URL(string: "https://mcp.example.com/mcp")!))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(v("response_type") == "code")
        #expect(v("client_id") == "abc")
        #expect(v("redirect_uri") == "nexgenvideo://oauth-callback")
        #expect(v("state") == "xyz")
        #expect(v("code_challenge_method") == "S256")
        #expect(v("code_challenge") == pkce.challenge)
        #expect(v("resource") == "https://mcp.example.com/mcp")
        #expect(v("scope") == "generate")
    }

    @Test("callback yields the code only on a matching state and no error")
    func callbackParsing() {
        let ok = URL(string: "nexgenvideo://oauth-callback?code=AUTH123&state=xyz")!
        #expect(OAuthCore.authorizationCode(from: ok, expectedState: "xyz") == "AUTH123")
        #expect(OAuthCore.authorizationCode(from: ok, expectedState: "WRONG") == nil)
        let err = URL(string: "nexgenvideo://oauth-callback?error=access_denied&state=xyz")!
        #expect(OAuthCore.authorizationCode(from: err, expectedState: "xyz") == nil)
    }

    // MARK: - Metadata decode

    @Test("protected-resource + server metadata decode")
    func metadataDecode() throws {
        let pr = try JSONDecoder().decode(OAuthCore.ProtectedResourceMetadata.self,
            from: Data(#"{"authorization_servers":["https://auth.example.com"]}"#.utf8))
        #expect(pr.authorizationServers == [URL(string: "https://auth.example.com")!])
        let sm = try JSONDecoder().decode(OAuthCore.ServerMetadata.self, from: Data(#"""
        {"authorization_endpoint":"https://a/authorize","token_endpoint":"https://a/token","registration_endpoint":"https://a/register","scopes_supported":["x"]}
        """#.utf8))
        #expect(sm.tokenEndpoint == URL(string: "https://a/token")!)
        #expect(sm.registrationEndpoint == URL(string: "https://a/register")!)
    }

    @Test("stored tokens expire with a 60s safety margin")
    func tokenFreshness() {
        let now = Date(timeIntervalSince1970: 1000)
        let long = OAuthCore.StoredTokens(accessToken: "a", refreshToken: nil, expiresAt: nil, clientID: "c", tokenEndpoint: URL(string: "https://a/t")!)
        #expect(long.isFresh(now: now))
        var soon = long; soon.expiresAt = now.addingTimeInterval(30)
        #expect(!soon.isFresh(now: now))
        var later = long; later.expiresAt = now.addingTimeInterval(120)
        #expect(later.isFresh(now: now))
    }

    // MARK: - Provider auth capability model (grounded in real service auth)

    @Test("each provider offers only the auth methods it actually supports (verified against live endpoints)")
    func capabilityModel() {
        // OAuth-only MCP providers — no API key at all (Higgsfield: 'No API keys to manage or configure').
        #expect(GenerationProvider.higgsfield.mcpCapability?.auth == .oauth)
        #expect(GenerationProvider.higgsfield.mcpCapability?.defaultURL.absoluteString == "https://mcp.higgsfield.ai/mcp")
        #expect(GenerationProvider.higgsfield.supportsDirectAPI == false)   // no API-key field
        #expect(GenerationProvider.openart.mcpCapability?.auth == .oauth)
        #expect(GenerationProvider.openart.supportsDirectAPI == false)
        // Local-app bridge.
        #expect(GenerationProvider.ace.mcpCapability?.auth == .localApp)
        // API-key providers — no MCP surfaced (fal's MCP adds nothing; Runway's rejects the REST key;
        // ElevenLabs/Marble have no hosted MCP). One honest control: the API key.
        for p in [GenerationProvider.fal, .runway, .marble, .elevenlabs] {
            #expect(p.mcpCapability == nil)
            #expect(p.supportsDirectAPI == true)
        }
    }

    @Test("API-key providers never activate a separate .mcp binding (no mis-routing)")
    func apiKeyProvidersDoNotActivateMCP() {
        // fal/Runway are used over their REST key (.api); with no mcpCapability they can't register a
        // .mcp binding the resolver would wrongly prefer.
        #expect(ProviderMCP.hasConfig(.fal) == false)
        #expect(ProviderMCP.hasConfig(.runway) == false)
    }
}
