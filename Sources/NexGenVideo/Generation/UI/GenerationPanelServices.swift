import Foundation

@MainActor
struct GenerationPanelServices {
    let catalog: ModelCatalog
    let preferences: ModelPreferences
    let activation: () -> ProviderActivation
    let quoteLoader: GenerationBudgetGuard.QuoteLoader

    static var live: Self {
        .init(catalog: .shared, preferences: .shared, activation: { .current() }, quoteLoader: LiveGenerationPricing.quote)
    }

    func canRun(_ modelID: String) -> Bool {
        preferences.isEnabled(modelID) && target(modelID).binding != nil
    }

    func target(_ modelID: String, sourceVideo: Bool? = nil, preferred: ResolvedGenerationTarget? = nil) -> ResolvedGenerationTarget {
        let available = ProviderManifest.bindings(forModelId: modelID, catalog: catalog).filter {
            GenerationService.videoBindingIsCompatible($0, requiringSourceVideo: sourceVideo)
        }
        let active = activation()
        let previous = preferred.flatMap { target in
            available.first { target.modelId == modelID && $0.provider == target.provider && $0.transport == target.transport
                && ($0.providerRef ?? modelID) == target.endpoint && $0.modelParam == target.binding?.modelParam
                && active.isActive($0.provider, $0.transport) }
        }
        let binding = previous ?? ProviderResolver.resolve(bindings: available, activation: active, effectiveCost: ProviderManifest.effectiveCost)
        return ResolvedGenerationTarget(modelId: modelID,
            provider: binding?.provider ?? ProviderManifest.nominalProvider(forModelId: modelID),
            endpoint: binding?.providerRef ?? modelID, binding: binding)
    }

    func upscaleSelections(for asset: MediaAsset, duration: Double? = nil) -> [UpscaleSelection] {
        UpscaleModelConfig.availableModels(in: catalog.upscale, for: asset.type,
            isEnabled: preferences.isEnabled, canRun: canRun).flatMap {
                $0.selections(sourceType: asset.type, sourceWidth: asset.sourceWidth, sourceHeight: asset.sourceHeight,
                    durationSeconds: duration ?? asset.duration)
            }
    }

    func isCurrent(_ target: ResolvedGenerationTarget) -> Bool {
        guard preferences.isEnabled(target.modelId), let binding = target.binding else { return false }
        return activation().isActive(binding.provider, binding.transport)
            && ProviderManifest.bindings(forModelId: target.modelId, catalog: catalog).contains(binding)
    }

    func videoTarget(_ modelID: String, hasSource: Bool, preferred: ResolvedGenerationTarget? = nil) -> ResolvedGenerationTarget {
        let selected = target(modelID, sourceVideo: hasSource, preferred: preferred)
        return selected.binding == nil ? target(modelID, sourceVideo: !hasSource, preferred: preferred) : selected
    }
}
