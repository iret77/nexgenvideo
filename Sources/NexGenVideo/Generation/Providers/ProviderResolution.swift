import Foundation

/// LLM → NGV → Provider → Model.
///
/// The LLM never picks or calls a provider. It asks NGV for a *logical* model; NGV
/// resolves the concrete (provider, transport) here. This is the spine of that
/// resolution — pure and testable, no I/O. It replaces the hardcoded 1:1
/// model-id-prefix ladder in `GenerationProvider.servicing` / `GenerationService.runJob`.

/// How NGV reaches a provider. Never a raw LLM tool: for `.mcp`, NGV is the MCP *client*
/// (behind the prompt-engine gate), on the user's subscription/OAuth.
enum ProviderTransport: String, Sendable, Codable, CaseIterable, Hashable {
    case api   // direct REST on the user's own API key
    case mcp   // NGV-as-MCP-client to the provider's server
}

/// Billing reality of a transport — decisive for "cheapest": a flat subscription (`.mcp`)
/// can beat pay-per-use (`.api`) at the same raw rate, and often the reverse. NGV weighs
/// this, not just the sticker price.
enum BillingMode: String, Sendable, Codable, Hashable {
    case perCall        // separate account, charged per generation (typical API)
    case subscription   // flat / already paid (typical MCP)
}

/// One concrete way to produce a logical model: a (provider, transport) with the
/// provider's own endpoint/model reference and its billing mode.
struct ProviderBinding: Sendable, Hashable {
    let provider: GenerationProvider
    let transport: ProviderTransport
    /// The provider's own model/endpoint id (e.g. a fal endpoint, a Higgsfield model).
    let providerModelRef: String
    let billing: BillingMode
}

/// What the user has actually turned on — per (provider, transport). A provider can be
/// active over one transport but not the other (API key present, MCP not connected, …).
struct ProviderActivation: Sendable {
    struct Key: Hashable, Sendable {
        let provider: GenerationProvider
        let transport: ProviderTransport
    }
    let active: Set<Key>

    init(active: Set<Key> = []) { self.active = active }

    func isActive(_ provider: GenerationProvider, _ transport: ProviderTransport) -> Bool {
        active.contains(Key(provider: provider, transport: transport))
    }
}

enum ProviderResolver {
    /// Pick the cheapest ACTIVATED way to produce a logical model.
    ///
    /// `bindings` are all the ways it can be produced; `activation` is what the user turned
    /// on; `effectiveCost` returns the billing-aware cost of THIS call for a binding (a
    /// subscription transport typically reports a low/flat marginal cost). Returns `nil`
    /// when no activated provider offers the model — in which case the catalog must not
    /// have offered it to the LLM in the first place (usable-only rule).
    static func resolve(
        bindings: [ProviderBinding],
        activation: ProviderActivation,
        effectiveCost: (ProviderBinding) -> Double
    ) -> ProviderBinding? {
        bindings
            .filter { activation.isActive($0.provider, $0.transport) }
            .min { effectiveCost($0) < effectiveCost($1) }
    }
}
