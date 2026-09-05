import Foundation

public struct ProductionRouteDisciplineV1: Codable, Sendable, Equatable {
    public let maximumVisibleCharacters: Int?
    public let maximumDurationSeconds: Double?
    public let maximumReferences: Int?

    public init(
        maximumVisibleCharacters: Int? = nil,
        maximumDurationSeconds: Double? = nil,
        maximumReferences: Int? = nil
    ) {
        self.maximumVisibleCharacters = maximumVisibleCharacters
        self.maximumDurationSeconds = maximumDurationSeconds
        self.maximumReferences = maximumReferences
    }

    public init(capabilityProfile: ResolvedCapabilityProfileV1) {
        maximumVisibleCharacters = capabilityProfile.fields.integers[
            CapabilityFieldIDV1.visibleCharacters
        ]?.value
        maximumDurationSeconds = capabilityProfile.fields.decimals[
            CapabilityFieldIDV1.durationMaximum
        ]?.value
        maximumReferences = capabilityProfile.fields.integers[
            CapabilityFieldIDV1.totalReferences
        ]?.value
    }
}

public struct ProductionDisciplineSidecarV1: Codable, Sendable, Equatable {
    public let routesByShotID: [String: ProductionRouteDisciplineV1]

    public init(routesByShotID: [String: ProductionRouteDisciplineV1]) {
        self.routesByShotID = routesByShotID
    }

    public func route(for shotID: String) -> ProductionRouteDisciplineV1? {
        routesByShotID[shotID]
    }
}
