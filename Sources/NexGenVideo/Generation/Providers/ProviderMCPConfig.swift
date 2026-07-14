import Foundation

/// A provider's `.mcp` transport connection the user configured (Settings → Providers, MCP mode):
/// the server endpoint in UserDefaults, an optional subscription/OAuth bearer token in the Keychain.
/// Presence of an endpoint ACTIVATES the provider's `.mcp` transport — parallel to how an API key
/// activates `.api`. A provider may have both (API pay-per-call AND an MCP subscription); the
/// resolver then weighs them by billing.
enum ProviderMCP {
    private static func endpointKey(_ p: GenerationProvider) -> String { "provider.\(p.rawValue).mcp-endpoint" }
    private static func tokenAccount(_ p: GenerationProvider) -> String { "provider.\(p.rawValue).mcp-token" }

    /// A user-overridden endpoint (rare — the capability's known default is used otherwise).
    static func configuredEndpoint(_ p: GenerationProvider) -> URL? {
        guard let s = UserDefaults.standard.string(forKey: endpointKey(p)), let u = URL(string: s) else { return nil }
        return u
    }

    /// The endpoint NGV actually connects to: a user override, else the provider's known default URL —
    /// so the user never types a URL.
    static func resolvedEndpoint(_ p: GenerationProvider) -> URL? {
        configuredEndpoint(p) ?? p.mcpCapability?.defaultURL
    }

    /// Whether the provider's `.mcp` transport is ACTIVE — i.e. the user has done what it needs:
    /// OAuth sign-in (subscription/credits), or opting into a local-app bridge. API-key providers
    /// (fal, Runway, Marble, ElevenLabs) have no `mcpCapability`, so they never register a separate
    /// `.mcp` binding — they're used over their REST key (`.api`). A capability-less provider still
    /// honors a manually-set endpoint (legacy).
    static func hasConfig(_ p: GenerationProvider) -> Bool {
        guard let cap = p.mcpCapability else { return configuredEndpoint(p) != nil }
        switch cap.auth {
        case .oauth: return ProviderOAuthStore.isConnected(p)
        case .localApp: return configuredEndpoint(p) != nil
        }
    }

    static func token(_ p: GenerationProvider) -> String? { KeychainStore.load(account: tokenAccount(p)) }

    /// The bearer NGV sends when driving this provider's MCP: an OAuth access token (refreshed), the
    /// forwarded API key, or nil for a local bridge.
    static func bearer(for p: GenerationProvider) async -> String? {
        guard let cap = p.mcpCapability else { return token(p) }
        switch cap.auth {
        case .oauth: return await ProviderOAuthStore.validAccessToken(p)
        case .localApp: return nil
        }
    }

    static func setEndpoint(_ url: String?, for p: GenerationProvider) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: endpointKey(p))
        } else {
            UserDefaults.standard.removeObject(forKey: endpointKey(p))
        }
        NotificationCenter.default.post(name: .providerKeysChanged, object: nil)
    }

    static func setToken(_ token: String?, for p: GenerationProvider) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            KeychainStore.save(trimmed, account: tokenAccount(p))
        } else {
            KeychainStore.delete(account: tokenAccount(p))
        }
    }

    /// An NGV-as-client for this provider's MCP, or nil when there's no endpoint. Resolves the bearer
    /// just-in-time (OAuth access token refreshed as needed / forwarded API key), so a long editing
    /// session never sends a stale token.
    static func client(for p: GenerationProvider) async -> MCPProviderClient? {
        guard let endpoint = resolvedEndpoint(p) else { return nil }
        return MCPProviderClient(config: .init(endpoint: endpoint, bearerToken: await bearer(for: p)))
    }
}
