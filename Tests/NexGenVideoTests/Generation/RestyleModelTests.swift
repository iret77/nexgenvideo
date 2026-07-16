import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

/// #223 — Aleph 2 on the source-video edit path, and the profile selecting itself from the model.
@Suite("restyle model wiring (#223)")
@MainActor
struct RestyleModelTests {

    @Test("Aleph is registered as a source-video edit model")
    func alephRequiresSourceVideo() throws {
        let model = try #require(RunwayModelRegistry.model(for: "runway/aleph2"))
        // aleph2, not gen4_aleph: the predecessor is sunset 2026-07-30. Verified against the live
        // account model list, which is also what now gates the entry.
        #expect(model.apiModel == "aleph2")
        // requiresSourceVideo is what routes it to the edit path AND selects the restyle prompt profile.
        #expect(RunwayModelRegistry.requiresSourceVideo(model))
        // The i2v models must NOT be treated as restyles.
        let gen45 = try #require(RunwayModelRegistry.model(for: "runway/gen4.5"))
        #expect(!RunwayModelRegistry.requiresSourceVideo(gen45))
    }

    @Test("Aleph advertises no durations — the output follows the source clip")
    func alephHasNoDurationKnob() throws {
        let model = try #require(RunwayModelRegistry.model(for: "runway/aleph2"))
        guard case .video(let caps) = model.entry.uiCapabilities else {
            Issue.record("expected video capabilities"); return
        }
        // A duration here would be a knob that does nothing.
        #expect(caps.durations.isEmpty)
        // The source clip is the input; it takes no reference images.
        #expect(caps.maxTotalReferences == 0)
        #expect(!caps.requiresReferenceImage)
    }

    @Test("Aleph is a Runway model and resolves to the Runway provider")
    func alephRoutesToRunway() {
        #expect(RunwayModelRegistry.isRunwayModel("runway/aleph2"))
        #expect(ProviderManifest.nominalProvider(forModelId: "runway/aleph2") == .runway)
    }

    // MARK: - Discovery gate (the owner's #223 decision, honoured)

    @Test("Aleph is NOT in the launch seed — only the account's own list can offer it")
    func alephIsNotSeeded() {
        // A pinned seed entry is exactly how gen4_aleph (sunset 2026-07-30) would have shipped.
        #expect(!RunwayModelRegistry.entries.contains { $0.id == "runway/aleph2" })
        // The stable Runway models stay seeded and unaffected.
        #expect(RunwayModelRegistry.entries.contains { $0.id == "runway/gen4.5" })
        #expect(RunwayModelRegistry.entries.contains { $0.id == "runway/gen4_image" })
    }

    @Test("an account carrying aleph2 gets the entry; one without it gets nothing")
    func alephAppearsOnlyWhenTheAccountHasIt() throws {
        let entries = RunwayModelRegistry.discoveredEntries(availableModelIds: ["aleph2", "gen4.5"])
        let entry = try #require(entries.first { $0.id == "runway/aleph2" })
        #expect(entry.offers?.first?.provider == .runway)

        // An account still on the sunset model gets no restyle entry rather than a dying one.
        #expect(RunwayModelRegistry.discoveredEntries(availableModelIds: ["gen4_aleph"]).isEmpty)
        #expect(RunwayModelRegistry.discoveredEntries(availableModelIds: []).isEmpty)
    }

    @Test("discovery covers Runway alongside the image providers")
    func discoveryIncludesRunway() {
        #expect(DirectImageDiscovery.providers.contains(.runway))
    }

    @Test("it was the first model on the edit path — which is no longer a facade")
    func editPathNowHasAModel() {
        // generateVideoEdit and the submission's requiresSourceVideo branch existed with nothing
        // routing to them. If this ever returns empty again, the edit path is dead code once more.
        let editModels = RunwayModelRegistry.models.filter { RunwayModelRegistry.requiresSourceVideo($0) }
        #expect(!editModels.isEmpty)
    }
}
