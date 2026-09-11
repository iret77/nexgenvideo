import Foundation
import NexGenEngine

enum CatalogNativeCapabilities {
    static func applying(
        to capability: ResolvedOfferingCapabilityProfileV1,
        offer: ProviderOffer
    ) -> ResolvedOfferingCapabilityProfileV1 {
        guard offer.transport == .api,
              let entry = nativeEntry(modelID: capability.offering.catalogModelID, offer: offer) else {
            return capability
        }
        var fields = capability.effective.fields
        let evidence = CapabilityEvidenceV1(
            sourceTitle: "NexGenVideo \(offer.provider.displayName) request adapter",
            observedAt: "2026-09-11T00:00:00Z", kind: .providerSchema, confidence: 1
        )
        let origin = ResolvedCapabilityOriginV1(
            kind: .endpointOverlay, profileID: "native-adapter/\(entry.id)",
            endpointID: capability.offering.endpointID
        )
        func count(_ id: String, _ limit: Int) {
            let current = fields.integers[id]
            let value = current.flatMap { $0.semantics == .defensiveDefault ? nil : $0.value }
                .map { min($0, limit) } ?? limit
            fields.integers[id] = .init(value: value, semantics: .hardAPILimit, origin: origin,
                                        evidence: (current?.evidence ?? []) + [evidence])
        }
        func seconds(_ id: String, _ limit: Int, minimum: Bool) {
            let current = fields.decimals[id]
            let known = current.flatMap { $0.semantics == .defensiveDefault ? nil : $0.value }
            let value = known.map { minimum ? max($0, Double(limit)) : min($0, Double(limit)) } ?? Double(limit)
            fields.decimals[id] = .init(value: value, semantics: .hardAPILimit, origin: origin,
                                        evidence: (current?.evidence ?? []) + [evidence])
        }
        func values(_ id: String, _ supported: [String]) {
            let current = fields.strings[id]
            let known = current.flatMap { $0.semantics == .defensiveDefault ? nil : $0.value }
            fields.strings[id] = .init(value: known.map { $0.filter(Set(supported).contains) } ?? supported,
                                       semantics: .supportedSet, origin: origin,
                                       evidence: (current?.evidence ?? []) + [evidence])
        }
        switch entry.uiCapabilities {
        case .image(let caps):
            count(CapabilityFieldIDV1.imageReferences, caps.maxReferenceImages)
            count(CapabilityFieldIDV1.imageOutputsPerRequest, caps.maxImages)
            values(CapabilityFieldIDV1.aspectRatios, caps.aspectRatios)
            if let resolutions = caps.resolutions { values(CapabilityFieldIDV1.resolutions, resolutions) }
        case .audio(let caps):
            if let minimum = caps.minSeconds { seconds(CapabilityFieldIDV1.audioDurationMinimum, minimum, minimum: true) }
            if let maximum = caps.maxSeconds { seconds(CapabilityFieldIDV1.audioDurationMaximum, maximum, minimum: false) }
            let current = fields.booleans[CapabilityFieldIDV1.audioLyrics]
            let known = current.flatMap { $0.semantics == .defensiveDefault ? nil : $0.value }
            fields.booleans[CapabilityFieldIDV1.audioLyrics] = .init(
                value: (known ?? true) && caps.supportsLyrics, semantics: .hardAPILimit,
                origin: origin, evidence: (current?.evidence ?? []) + [evidence]
            )
        case .video, .upscale:
            return capability
        }
        return ResolvedOfferingCapabilityProfileV1(
            offering: capability.offering, intrinsic: capability.intrinsic,
            effective: ResolvedCapabilityProfileV1(
                requestedIdentity: capability.effective.requestedIdentity,
                resolvedIdentity: capability.effective.resolvedIdentity,
                defensiveProfileID: capability.effective.defensiveProfileID,
                researchNeeded: capability.effective.researchNeeded, fields: fields
            )
        )
    }

    private static func nativeEntry(modelID: String, offer: ProviderOffer) -> CatalogEntry? {
        let reference = offer.providerRef ?? modelID
        switch offer.provider {
        case .fal, .elevenlabs:
            let discovered = offer.provider == .fal
                ? FalModelRegistry.discoveredEntries(availableModelIds: [reference]) : []
            return (FalModelRegistry.entries + discovered).first { entry in
                entry.id == modelID && entry.offers?.contains(where: {
                    $0.provider == offer.provider && $0.providerRef == reference
                }) == true
            }
        case .runway:
            return RunwayModelRegistry.entries.first { entry in
                entry.id == modelID && entry.offers?.contains(where: {
                    $0.provider == .runway && $0.providerRef == reference
                }) == true
            }
        case .google:
            return GoogleModelRegistry.models.first {
                $0.entry.id == modelID && $0.apiModelCandidates.contains(reference)
            }?.entry
        case .marble:
            return MarbleModelRegistry.entries.first { $0.id == modelID && $0.id == reference }
        default:
            return nil
        }
    }
}
