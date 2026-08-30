import Foundation

/// Availability discovery for direct-API image providers.
///
/// The registries carry the curated capabilities (aspect ratios, reference support, image count) that
/// no model-list call can tell you. This supplies the other half: which of those models the provider
/// says exist for this key, so a renamed or retired id simply never appears.
///
/// **How much this filter is worth differs per provider — do not blur them:**
/// - **fal.ai** — the authenticated active-model catalog selects the exact supported endpoint set.
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
    enum Result: Sendable {
        case inactive
        case success([CatalogEntry])
        case authenticationFailure(String)
        case unavailableFailure(String)
        case transientFailure(String)
    }

    /// The direct-API providers whose catalog is resolved at runtime against the key.
    ///
    /// Runway is entirely discovery-gated: only the account's own model list proves that a pinned id
    /// is currently entitled and runnable.
    static let providers: [GenerationProvider] = [.fal, .google, .runway]

    static func discover(_ provider: GenerationProvider) async -> Result {
        guard providers.contains(provider), let apiKey = ProviderKeychain.load(provider) else {
            return .inactive
        }
        do {
            let entries: [CatalogEntry]
            switch provider {
            case .fal:
                let ids = try await FalClient(apiKey: apiKey).availableImageModelIds()
                entries = FalModelRegistry.discoveredEntries(availableModelIds: ids)
            case .google:
                let ids = try await GoogleImageClient(apiKey: apiKey).availableModelIds()
                entries = GoogleModelRegistry.entries(availableModelIds: ids)
            case .runway:
                let ids = try await RunwayClient(apiKey: apiKey).availableModelIds()
                entries = RunwayModelRegistry.discoveredEntries(availableModelIds: ids)
            default:
                return .inactive
            }
            return .success(entries)
        } catch {
            Log.generation.notice(
                "direct image discovery failed for \(provider.rawValue): \(error.localizedDescription)")
            if Self.isAuthenticationFailure(error) {
                return .authenticationFailure(
                    "The saved key was rejected. Replace it to refresh this provider's models."
                )
            }
            if !Self.isTransientFailure(error) {
                return .unavailableFailure(
                    "Model catalog refresh was rejected: \(error.localizedDescription)"
                )
            }
            return .transientFailure(
                "Model catalog refresh failed: \(error.localizedDescription). NexGenVideo will retry automatically."
            )
        }
    }

    static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let backendError = error as? GenerationBackendError,
              case .api(let status, _, _) = backendError else {
            return false
        }
        return status == 401 || status == 403
    }

    static func isTransientFailure(_ error: Error) -> Bool {
        guard let backendError = error as? GenerationBackendError,
              case .api(let status, _, _) = backendError else {
            return true
        }
        return status == 408 || status == 425 || status == 429 || status >= 500
    }

    static func preservesLastKnownGood(after result: Result, currentModelCount: Int) -> Bool {
        guard currentModelCount > 0 else { return false }
        if case .transientFailure = result { return true }
        return false
    }
}
