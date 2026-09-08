import Foundation
import NexGenEngine

struct ProviderToolSchemaCheck: Codable, Sendable, Equatable {
    let toolName: String
    let schemaSHA256: String
    let observedAt: String
}

struct GenerationRouteReceipt: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case fromReference = "from_reference", liveChecked = "live_checked" }
    enum Scope: String, Codable, Sendable { case modelCatalog = "model_catalog", accountEntitlement = "account_entitlement", toolSchema = "tool_schema" }
    struct Check: Codable, Sendable, Equatable {
        let modelID: String
        let provider: GenerationProvider
        let transport: ProviderTransport
        let endpoint: String
        let modelParam: String?
        let scope: Scope
        let source: String
        let observedAt: String
        let evidenceSHA256: String

        func matches(_ target: ResolvedGenerationTarget) -> Bool {
            modelID == target.modelId && provider == target.provider && transport == target.transport
                && endpoint == target.endpoint && modelParam == target.binding?.modelParam
        }
    }
    let state: State
    let target: ResolvedGenerationTarget
    let checks: [Check]
    let capabilitySnapshot: ProductionRouteCapabilitySnapshotV1?

    init(target: ResolvedGenerationTarget, checks: [Check], capabilitySnapshot: ProductionRouteCapabilitySnapshotV1?) {
        self.target = target
        self.checks = checks.filter { $0.matches(target) }
        state = self.checks.isEmpty ? .fromReference : .liveChecked
        self.capabilitySnapshot = capabilitySnapshot
    }

    static func checks(entries: [CatalogEntry], provider: GenerationProvider, schemas: [ProviderToolSchemaCheck],
                       directObservedAt: String? = nil) -> [Check] {
        entries.flatMap { entry in
            (entry.offers ?? []).compactMap { offer -> Check? in
                guard offer.provider == provider, let endpoint = offer.providerRef else { return nil }
                if offer.transport == .mcp, let schema = schemas.first(where: { $0.toolName == endpoint }) {
                    return Check(modelID: entry.id, provider: provider, transport: .mcp, endpoint: endpoint,
                        modelParam: offer.modelParam, scope: .toolSchema, source: "MCP tools/list",
                        observedAt: schema.observedAt, evidenceSHA256: schema.schemaSHA256)
                }
                guard offer.transport == .api, let directObservedAt else { return nil }
                let source: String
                switch provider {
                case .fal: source = "https://api.fal.ai/v1/models"
                case .google: source = "https://generativelanguage.googleapis.com/v1beta/models"
                case .runway: source = "https://api.dev.runwayml.com/v1/organization"
                default: return nil
                }
                return Check(modelID: entry.id, provider: provider, transport: .api, endpoint: endpoint,
                    modelParam: offer.modelParam, scope: provider == .runway ? .accountEntitlement : .modelCatalog,
                    source: source, observedAt: directObservedAt,
                    evidenceSHA256: FileDigest.sha256(of: Data([entry.id, endpoint, offer.modelParam ?? ""].joined(separator: "\n").utf8)))
            }
        }
    }
}
