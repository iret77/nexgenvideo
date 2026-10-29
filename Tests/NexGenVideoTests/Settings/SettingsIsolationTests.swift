import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Settings persistence and actual capability application")
struct SettingsIsolationTests {
    @Test func modelPreferencesPersistInTheirOwnStore() throws {
        let name = "settings-isolation." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let actual = UserDefaults.standard.stringArray(forKey: "disabledModelIds")
        let first = ModelPreferences(defaults: defaults)
        first.setEnabled("fal-ai/qwen-image", false)
        #expect(!ModelPreferences(defaults: defaults).isEnabled("fal-ai/qwen-image"))
        first.setEnabled("fal-ai/qwen-image", true)
        #expect(ModelPreferences(defaults: defaults).isEnabled("fal-ai/qwen-image"))
        #expect(UserDefaults.standard.stringArray(forKey: "disabledModelIds") == actual)
    }

    @Test func acceptedEvidenceActuallyChangesTheCatalogAndDisabledEvidenceRestoresItsBase() async throws {
        let catalog = ModelCatalog()
        let entry = try #require(FalModelRegistry.model(for: "fal-ai/qwen-image")?.entry)
        catalog.load(entries: [entry])
        let original = catalog.offeringCapabilitiesByModelID
        let capability = try #require(original[entry.id]?.first)
        let corpus = try #require(CatalogCapabilityRuntime.corpus)
        let resolved = ModelCapabilityResearchIdentityPolicy.binding(profile: capability.intrinsic, offering: capability.offering, corpus: corpus)
        let request = ModelCapabilityResearchRequestV1(binding: resolved.value, scope: .intrinsic, trigger: .defensiveProfile,
            fallbackResolution: .defensive, fallbackProfileID: "native-settings-test", allowedSourceHosts: ["fal.ai"])
        let evidence = CapabilityEvidenceV1(sourceURL: "https://fal.ai/synthetic-settings-test",
            sourceTitle: "Synthetic isolated Settings regression", observedAt: request.observedAt, kind: .documentedAPI, confidence: 1)
        let fieldID = CapabilityFieldIDV1.imageVisibleCharacters
        let candidate = ModelCapabilityResearchCandidateV1(binding: request.binding, scope: .intrinsic,
            fields: .init(integers: [fieldID: .init(value: 2, semantics: .reliableCapacity, evidence: [evidence])]))
        let review = try ModelCapabilityResearchReviewBuilder.build(request: request, candidate: candidate,
            fallback: ModelCapabilityResearchIdentityPolicy.bindingProfile(capability.intrinsic, to: resolved.value.identity))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-capability-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ModelCapabilityResearchStore(fileURL: directory.appendingPathComponent("records.json"))
        let record = try await store.accept(review, fieldIDs: [fieldID])
        #expect(catalog.offeringCapabilitiesByModelID == original)
        catalog.applyResearchRecords(try await store.snapshot().records)
        #expect(catalog.curatedOfferingCapabilitiesByModelID == original)
        #expect(catalog.offeringCapabilitiesByModelID[entry.id]?.first?.effective.fields.integers[fieldID]?.value == 2)
        try await store.disable(record.id)
        catalog.applyResearchRecords(try await store.snapshot().records)
        #expect(catalog.offeringCapabilitiesByModelID == original)
        try await store.enable(record.id)
        catalog.applyResearchRecords(try await store.snapshot().records)
        #expect(catalog.offeringCapabilitiesByModelID[entry.id]?.first?.effective.fields.integers[fieldID]?.value == 2)
        try await store.delete(record.id)
        catalog.applyResearchRecords(try await store.snapshot().records)
        #expect(catalog.offeringCapabilitiesByModelID == original)
        #expect(catalog.settingsBindings(forModelID: entry.id, activation: .init()).isEmpty)
        #expect(!catalog.settingsBindings(forModelID: entry.id, activation: .init(active: [.init(provider: .fal, transport: .api)])).isEmpty)
    }
}
