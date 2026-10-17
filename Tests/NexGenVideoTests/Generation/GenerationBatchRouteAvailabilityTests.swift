import Testing
@testable import NexGenVideo

@Suite("Batch route availability remains exact")
@MainActor
struct GenerationBatchRouteAvailabilityTests {
    @Test func instanceActivationStillRequiresTheExactCurrentCatalogBinding() throws {
        let catalog = ModelCatalog()
        catalog.load(entries: ModelCatalog.launchEntries)
        let modelID = "bytedance/seedance-2.5/reference-to-video"
        let binding = try #require(ProviderManifest.bindings(forModelId: modelID, catalog: catalog).first)
        let active = ProviderActivation(active: [.init(provider: binding.provider, transport: binding.transport)])
        func option(_ selected: ProviderBinding?, model: String? = nil) -> SpendOption {
            let model = model ?? modelID
            return SpendOption(modelId: model, modelName: model,
                target: .init(modelId: model, provider: binding.provider,
                    endpoint: selected?.providerRef ?? binding.providerRef, binding: selected),
                credits: nil, requiresCatalogAvailability: true)
        }
        #expect(option(binding).isAvailable(activation: active, catalog: catalog))
        #expect(!option(binding).isAvailable(activation: .init(), catalog: catalog))
        #expect(!option(nil).isAvailable(activation: active, catalog: catalog))
        #expect(!option(binding, model: "absent-model").isAvailable(activation: active, catalog: catalog))
        let changed = ProviderBinding(provider: binding.provider, transport: binding.transport, kind: binding.kind,
            providerRef: binding.providerRef + "-different", billing: binding.billing)
        #expect(!option(changed).isAvailable(activation: active, catalog: catalog))
        catalog.load(entries: [])
        #expect(!option(binding).isAvailable(activation: active, catalog: catalog))
    }
}
