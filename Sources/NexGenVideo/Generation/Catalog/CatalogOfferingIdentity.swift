import NexGenEngine

enum CatalogOfferingIdentity {
    static func make(
        offer: ProviderOffer,
        modelID: String,
        modality: CapabilityModalityV1
    ) -> CapabilityOfferingIdentityV1 {
        let endpointID = offer.providerRef ?? modelID
        return CapabilityOfferingIdentityV1(
            providerID: offer.provider.rawValue,
            offeringID: id(offer: offer, modelID: modelID),
            endpointID: endpointID,
            catalogModelID: modelID,
            modality: modality
        )
    }

    static func id(offer: ProviderOffer, modelID: String) -> String {
        let endpointID = offer.providerRef ?? modelID
        return [
            offer.provider.rawValue,
            offer.transport.rawValue,
            endpointID,
            offer.modelParam ?? modelID,
        ].joined(separator: "/")
    }
}
