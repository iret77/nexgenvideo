import Foundation
import Testing
@testable import NexGenVideo

/// #212 — the direct image provider (Google): fal is *a* way to images, not *the* way. These pin the
/// pure parts: availability filtering and the shared-id merge that makes one model reachable through
/// several providers.
///
/// OpenAI-direct was dropped by owner decision: almost no private user holds an OpenAI platform key,
/// and the same models (gpt_image_2, gemini image 3.x) turn out to be resold by Runway — a key people
/// actually have, over the existing `.api` transport. No client ⇒ no provider ⇒ no key field.
@Suite("direct image providers (#212)")
@MainActor
struct DirectImageProviderTests {

    // MARK: - Availability filtering (#159: only what the key really exposes)

    @Test("a Google model whose candidates the key doesn't expose is not offered at all")
    func googleDropsUnavailableModels() {
        #expect(GoogleModelRegistry.entries(availableModelIds: []).isEmpty)
        #expect(GoogleModelRegistry.entries(availableModelIds: ["some-unrelated-model"]).isEmpty)
    }

    @Test("a Google model resolves to whichever candidate id the key exposes")
    func googleResolvesCandidate() throws {
        let model = try #require(GoogleModelRegistry.models.first { $0.entry.id == "fal-ai/imagen4" })
        // Take the LAST candidate to prove it isn't just picking the first blindly.
        let fallback = try #require(model.apiModelCandidates.last)
        let entries = GoogleModelRegistry.entries(availableModelIds: [fallback])
        let entry = try #require(entries.first { $0.id == "fal-ai/imagen4" })
        let offer = try #require(entry.offers?.first)
        #expect(offer.provider == .google)
        #expect(offer.providerRef == fallback)
    }

    @Test("candidate order wins when the key exposes several")
    func googlePrefersFirstCandidate() throws {
        let model = try #require(GoogleModelRegistry.models.first { $0.entry.id == "fal-ai/imagen4" })
        let entries = GoogleModelRegistry.entries(availableModelIds: Set(model.apiModelCandidates))
        let offer = try #require(entries.first { $0.id == "fal-ai/imagen4" }?.offers?.first)
        #expect(offer.providerRef == model.apiModelCandidates.first)
    }

    // MARK: - One model, several providers

    @Test("the Google Imagen entry shares the fal id, so the catalog merges them into ONE model")
    func googleSharesFalIdForMergedOffers() throws {
        let google = try #require(GoogleModelRegistry.models.first { $0.entry.id == "fal-ai/imagen4" })
        let fal = FalModelRegistry.entries.first { $0.id == google.entry.id }
        // A different id here would put two "Imagen 4" rows in front of the user instead of one model
        // with two routes — the thing #212 is for.
        #expect(fal != nil, "the Google entry must reuse the fal entry's id to merge offers")
        #expect(fal?.offers?.contains { $0.provider == .fal } == true)
    }

    @Test("a model offered by fal AND Google resolves to Google when only Google is activated")
    func resolvesToActivatedProvider() throws {
        let bindings = [
            ProviderBinding(provider: .fal, transport: .api, kind: .generation,
                            providerRef: "fal-ai/imagen4", billing: .perCall),
            ProviderBinding(provider: .google, transport: .api, kind: .generation,
                            providerRef: "imagen-4.0-generate-001", billing: .perCall),
        ]
        let googleOnly = ProviderActivation(active: [.init(provider: .google, transport: .api)])
        let picked = try #require(ProviderResolver.resolve(
            bindings: bindings, activation: googleOnly, effectiveCost: ProviderManifest.effectiveCost))
        #expect(picked.provider == .google)
        // The dispatch endpoint is the provider's OWN model string, not the fal id.
        #expect(picked.providerRef == "imagen-4.0-generate-001")
    }

    @Test("with both activated, the direct provider beats the fal middleman")
    func directBeatsFalWhenBothActive() throws {
        let bindings = [
            ProviderBinding(provider: .fal, transport: .api, kind: .generation,
                            providerRef: "fal-ai/imagen4", billing: .perCall),
            ProviderBinding(provider: .google, transport: .api, kind: .generation,
                            providerRef: "imagen-4.0-generate-001", billing: .perCall),
        ]
        let both = ProviderActivation(active: [
            .init(provider: .google, transport: .api), .init(provider: .fal, transport: .api),
        ])
        let picked = try #require(ProviderResolver.resolve(
            bindings: bindings, activation: both, effectiveCost: ProviderManifest.effectiveCost))
        #expect(picked.provider == .google)
    }

    @Test("nothing activated → nothing resolves, so the catalog can't offer it")
    func nothingActivatedResolvesNil() {
        let bindings = [
            ProviderBinding(provider: .google, transport: .api, kind: .generation,
                            providerRef: "imagen-4.0-generate-001", billing: .perCall),
        ]
        #expect(ProviderResolver.resolve(
            bindings: bindings, activation: ProviderActivation(active: []),
            effectiveCost: ProviderManifest.effectiveCost) == nil)
    }

    // MARK: - The not-activated fallback tells the truth

    @Test("an unactivated Google model falls back to Google, not to fal")
    func nominalProviderKnowsTheGooglePrefix() {
        // Nothing activated → no binding resolves → dispatch falls back to nominalProvider. Landing on
        // .fal here would tell the user to add a *fal* key for a Google model.
        #expect(ProviderManifest.nominalProvider(forModelId: "google/some-image") == .google)
        // A model sharing the fal id is a fal model by default — falling back to fal is correct.
        #expect(ProviderManifest.nominalProvider(forModelId: "fal-ai/imagen4") == .fal)
    }

    @Test("the registry lookup resolves both the API model string and the catalog id")
    func lookupAcceptsEitherReference() throws {
        // Dispatch passes the resolved providerRef (API model) normally, and the catalog id on the
        // not-activated fallback — both must find the model, or that path reports "unsupported model"
        // instead of "add a key".
        let google = try #require(GoogleModelRegistry.models.first)
        #expect(GoogleModelRegistry.model(for: try #require(google.apiModelCandidates.first)) != nil)
        #expect(GoogleModelRegistry.model(for: google.entry.id) != nil)
        #expect(GoogleModelRegistry.model(for: "nope") == nil)
    }

    @Test("the direct provider is an honest key-field provider")
    func directProvidersAdvertiseDirectAPI() {
        #expect(GenerationProvider.google.supportsDirectAPI)
        // Settings renders a key field off this — a shipped client backs both (no dead field).
        // Asserted as membership, not as the whole set: the discovery list grows (Runway joined it for
        // its sunset-prone Aleph line), and pinning the exact set would turn red on every addition
        // rather than on a real defect.
        #expect(DirectImageDiscovery.providers.contains(.google))
    }

    @Test("the LLM sees provider-neutral logical ids")
    func logicalIdsAreProviderNeutral() {
        #expect(ModelCatalog.deriveLogicalId("google/some-image") == "some-image")
        #expect(ModelCatalog.deriveLogicalId("fal-ai/imagen4") == "imagen4")
    }

    @Test("OpenAI is gone entirely — no provider, so no key field can be dead")
    func openAIIsFullyRemoved() {
        // The whole point of dropping it: a key field with no client behind it is exactly the dead
        // affordance the house rule forbids. Removing the provider removes the field with it.
        #expect(!GenerationProvider.allCases.contains { $0.rawValue == "openai" })
        #expect(!DirectImageDiscovery.providers.contains { $0.rawValue == "openai" })
    }
}

/// The Gemini 3.x line and the format correction a live call exposed (#212).
@Suite("gemini 3.x (#212)")
@MainActor
struct Gemini3ImageTests {

    @Test("the current Gemini line is offered, with the preview id as the fallback candidate")
    func geminiThreeIsRegistered() throws {
        for id in ["google/gemini-3-pro-image", "google/gemini-3.1-flash-image"] {
            let model = try #require(GoogleModelRegistry.models.first { $0.entry.id == id })
            // GA first, preview only as fallback — never silently prefer a preview.
            #expect(model.apiModelCandidates.first == id.replacingOccurrences(of: "google/", with: ""))
            #expect(model.apiModelCandidates.last?.hasSuffix("-preview") == true)
            // Same envelope as 2.5 — verified live: every gemini image model lists generateContent.
            #expect(model.surface == .generateContent)
        }
    }

    @Test("Gemini advertises the aspects NGV speaks — including 16:9")
    func geminiAspectsCoverTheVocabulary() throws {
        // The 2.5 entry used to advertise NONE, while the API has taken an aspect all along.
        for id in ["google/gemini-3-pro-image", "fal-ai/gemini-25-flash-image/edit"] {
            let model = try #require(GoogleModelRegistry.models.first { $0.entry.id == id })
            guard case .image(let caps) = model.entry.uiCapabilities else {
                Issue.record("expected image capabilities"); return
            }
            #expect(Set(caps.aspectRatios) == Set(["1:1", "16:9", "9:16", "4:3", "3:4"]))
        }
    }

    @Test("an account without the 3.x line is offered none of it")
    func geminiThreeIsDiscoveryFiltered() {
        let entries = GoogleModelRegistry.entries(availableModelIds: ["gemini-2.5-flash-image"])
        #expect(!entries.contains { $0.id.hasPrefix("google/gemini-3") })
        // …and an account that has it gets exactly it.
        let three = GoogleModelRegistry.entries(availableModelIds: ["gemini-3.1-flash-image"])
        #expect(three.contains { $0.id == "google/gemini-3.1-flash-image" })
    }

    @Test("an unactivated Gemini 3.x model names Google, not fal")
    func geminiThreeFallsBackToGoogle() {
        #expect(ProviderManifest.nominalProvider(forModelId: "google/gemini-3-pro-image") == .google)
    }
}
