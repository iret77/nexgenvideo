import Foundation

/// Availability discovery for the direct-API providers (#212 Google images, #223 Runway).
///
/// The registries carry the curated capabilities (aspect ratios, reference support, image count) that
/// no model-list call can tell you. This supplies the other half: which of those models the provider
/// says exist for this key, so a renamed or retired id simply never appears.
///
/// **How much this filter is worth differs per provider — do not blur them:**
/// - **Runway** — `GET /v1/organization` returns `tier.models`, the ACCOUNT's entitlements. Presence
///   there really does mean runnable.
/// - **Google** — `GET /v1beta/models` is a CATALOG, not an entitlement list. Verified the hard way:
///   every `imagen-4.0-*` is listed, advertises `methods: ["predict"]`, and still answers 404 "no
///   longer available to new users" when called. Nothing in the listing distinguishes it. So here
///   absence is proof of unavailability; **presence is not proof of availability**. The registry
///   carries only models verified to actually run — the filter is a safety net, not the guarantee.
///
/// Same self-correcting contract as the MCP side: re-run on every activation change, and whatever
/// isn't rediscovered disappears.
@MainActor
enum DirectImageDiscovery {
    /// The direct-API providers whose catalog is resolved at runtime against the key.
    ///
    /// Runway is here for its discovery-GATED models only (its stable ids stay a static seed): the
    /// Aleph line proved why a pinned id is not enough — `gen4_aleph` is sunset 2026-07-30, and only
    /// the account's own model list names the successor it can actually run.
    static let providers: [GenerationProvider] = [.google, .runway]

    static func discover(_ provider: GenerationProvider) async -> [CatalogEntry] {
        guard providers.contains(provider), let apiKey = ProviderKeychain.load(provider) else { return [] }
        do {
            switch provider {
            case .google:
                let ids = try await GoogleImageClient(apiKey: apiKey).availableModelIds()
                return GoogleModelRegistry.entries(availableModelIds: ids)
            case .runway:
                let ids = try await RunwayClient(apiKey: apiKey).availableModelIds()
                return RunwayModelRegistry.discoveredEntries(availableModelIds: ids)
            default:
                return []
            }
        } catch {
            // A bad key or an unreachable API is a normal state, not a crash: the provider simply
            // contributes nothing this round. Logged, because a user who entered a key and sees no
            // models needs the reason to be findable.
            Log.generation.notice(
                "direct image discovery failed for \(provider.rawValue): \(error.localizedDescription)")
            return []
        }
    }
}
