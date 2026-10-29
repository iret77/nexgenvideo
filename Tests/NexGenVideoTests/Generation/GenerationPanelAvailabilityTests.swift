import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Previously selected generation target becomes unavailable")
struct GenerationPanelAvailabilityTests {
    @Test func actualPanelServicesRejectWithdrawalAndDisabledModelWithoutCredentials() throws {
        let catalog = ModelCatalog()
        catalog.load(entries: ModelCatalog.launchEntries)
        let suite = "generation-panel-availability-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ModelPreferences(defaults: defaults)
        var active = Set(GenerationProvider.allCases.flatMap { provider in
            [ProviderActivation.Key(provider: provider, transport: .api), .init(provider: provider, transport: .mcp)]
        })
        let services = GenerationPanelServices(catalog: catalog, preferences: preferences,
            activation: { .init(active: active) }, quoteLoader: { _, _ in GenerationPackageFixture.money() })
        let target = try #require(catalog.image.map { services.target($0.id) }.first { $0.binding != nil })
        #expect(services.isCurrent(target))
        let original = active
        active.removeAll()
        #expect(!services.isCurrent(target))
        active = original
        #expect(services.isCurrent(target))
        preferences.setEnabled(target.modelId, false)
        #expect(!services.isCurrent(target))
    }
}
