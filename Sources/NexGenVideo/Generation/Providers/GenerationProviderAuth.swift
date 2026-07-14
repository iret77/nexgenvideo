import Foundation

/// How a provider's MCP server authenticates — grounded in each service's real, documented setup, so
/// Settings only ever offers a method the provider actually supports (no dead fields).
enum MCPAuthMethod: Equatable, Sendable {
    /// OAuth sign-in against the provider's hosted MCP (Higgsfield, OpenArt): a one-click browser login
    /// on the user's account — no key, no URL. Higgsfield's own docs: "No API keys to manage or
    /// configure." Handled by `ProviderOAuth`.
    case oauth
    /// A local MCP bridge the provider's desktop app exposes (ACE Studio on localhost) — no key, but
    /// the app must be running.
    case localApp
}

/// A provider's hosted MCP transport: the known endpoint (so the user never types a URL) + how it
/// authenticates. `nil` for a provider with no usable MCP server (Marble, ElevenLabs — API only).
struct MCPCapability: Equatable, Sendable {
    let defaultURL: URL
    let auth: MCPAuthMethod
    /// One-line, creative-facing explanation of what this transport is.
    let note: String
}

extension GenerationProvider {
    /// The provider's MCP capability, if it offers a usable MCP server. URLs are the services' real,
    /// documented endpoints — pre-filled so the user activates with one action, never URL-typing.
    var mcpCapability: MCPCapability? {
        switch self {
        case .higgsfield:
            return MCPCapability(defaultURL: URL(string: "https://mcp.higgsfield.ai/mcp")!,
                                 auth: .oauth,
                                 note: "30+ video/image models on your Higgsfield subscription — sign in, no key.")
        case .openart:
            return MCPCapability(defaultURL: URL(string: "https://mcp.openart.ai/mcp")!,
                                 auth: .oauth,
                                 note: "Image + video models on your OpenArt credits — sign in, no key.")
        case .ace:
            return MCPCapability(defaultURL: URL(string: "http://localhost:21572/mcp")!,
                                 auth: .localApp,
                                 note: "Singing-voice synthesis — requires the ACE Studio app running on this Mac.")
        case .fal, .runway, .elevenlabs, .marble:
            // API only for our purposes — verified against the live endpoints. fal has a hosted MCP
            // (mcp.fal.ai/mcp, 200 with `Authorization: Key`) but it adds nothing over the REST key and
            // is pay-per-call; Runway's MCP (mcp.runwayml.com/mcp) rejected the REST key (401) so it is
            // NOT key-forwarding; ElevenLabs' MCP is a local stdio tool; Marble is REST-only. Showing an
            // MCP field for any of these would be a dead/misleading affordance — they use the API key.
            return nil
        }
    }

    /// When a provider's MCP generate tools take a free-form `model` id (rather than an inline enum),
    /// the full model list lives behind a separate catalog tool. This names ONLY that tool + how to
    /// page it — the model list itself stays live/discovery-driven (never a hardcoded model table).
    /// `nil` → NGV maps the discovered generate tools directly (inline `model` enum expanded, else one
    /// entry per modality).
    var mcpModelCatalog: MCPModelCatalog? {
        switch self {
        // Higgsfield: `generate_*` take `model` as a required free string; `models_explore(action:list,
        // type:…)` paginates the full catalog (`items[]`, `has_more`, `next_page_token`).
        case .higgsfield:
            return MCPModelCatalog(tool: "models_explore", listArgs: ["action": "list"],
                                   typeArg: "type", cursorArg: "after")
        // OpenArt's model-advertising shape is not yet verified on-device; until it is, OpenArt maps its
        // discovered generate tools directly (usable, just not model-expanded). Fill this in once its
        // catalog tool is confirmed — no guessing a shape we can't test.
        case .openart, .ace, .fal, .runway, .elevenlabs, .marble:
            return nil
        }
    }
}

/// A provider's MCP model-catalog tool: the bounded per-provider hint that lets NGV enumerate the
/// provider's models when its generate tools take a free-form `model` id. NOT a model table — it only
/// names the tool and its paging args; the models come back live from the call.
struct MCPModelCatalog: Equatable, Sendable {
    /// The catalog tool name, e.g. `models_explore`.
    let tool: String
    /// Fixed arguments that request a listing, e.g. `["action": "list"]`.
    let listArgs: [String: String]
    /// The argument that filters by output modality (`type` → "video"/"image"/"audio"), or nil to list all.
    let typeArg: String?
    /// The argument that carries the next-page cursor back to the tool (`after`), or nil if unpaged.
    let cursorArg: String?
}
