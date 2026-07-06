import Foundation
import Testing
@testable import NexGenEngine

/// Port of `engine/tests/test_router_contract.py`: deliberate (non-uniform) floors, one-step bounded
/// escalation, project manifest override of known tiers only, contract validation, and every core
/// phase covered by the contract.
@Suite("ModelRouter + UIContract")
struct ModelRouterTests {

    private func tempDataRoot() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-\(UUID().uuidString)")
        let home = tmp.appendingPathComponent("p")
        return try ProjectScaffold.initProject(home: home, name: "demo", mode: .section)
    }

    // MARK: - test_floors_are_deliberate_not_uniform

    @Test("floors are deliberate, not uniform")
    func floorsAreDeliberate() throws {
        let distill = try ModelRouter.resolve("distill")
        #expect(distill.taskClass == "distill")
        #expect(distill.tier == "fast")
        #expect(distill.model == ModelRouter.defaultManifest["fast"])
        #expect(distill.effort == "low")
        #expect(!distill.escalated)

        let interp = try ModelRouter.resolve("interpretation")
        #expect(interp.tier == "deep")
        #expect(interp.effort == "high")
    }

    // MARK: - test_escalation_is_one_step_and_bounded_at_deep

    @Test("escalation is one step and bounded at deep")
    func escalationBounded() throws {
        #expect(try ModelRouter.resolve("distill", escalate: true).tier == "medium")
        let deep = try ModelRouter.resolve("planning", escalate: true)
        #expect(deep.tier == "deep")
        #expect(!deep.escalated)  // already at ceiling — nothing to escalate to
    }

    // MARK: - test_unknown_task_class_raises

    @Test("unknown task class throws")
    func unknownTaskClassThrows() {
        #expect(throws: ModelRouter.UnknownTaskClass.self) {
            try ModelRouter.resolve("vibes")
        }
    }

    // MARK: - test_project_manifest_overrides_known_tiers_only

    @Test("project models.yaml overrides known tiers only")
    func manifestOverrideKnownTiersOnly() throws {
        let dataRoot = try tempDataRoot()
        defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent().deletingLastPathComponent()) }
        let manifestURL = dataRoot.appendingPathComponent(ModelRouter.manifestFilename)
        try "fast: my-tiny-model\nbogus: nope\n".write(to: manifestURL, atomically: true, encoding: .utf8)

        let resolved = ModelRouter.manifest(dataRoot: dataRoot)
        #expect(resolved["fast"] == "my-tiny-model")
        #expect(resolved["medium"] == ModelRouter.defaultManifest["medium"])
        #expect(resolved["bogus"] == nil)
    }

    // MARK: - test_registry_validates_contract_entries

    @Test("contract entry validation accepts valid, rejects bad surface / task_class")
    func contractValidation() throws {
        let entry = try UIContract.validateEntry(phase: "analysis", surface: "choice", taskClass: "classification")
        #expect(entry == UIContract.Entry(surface: "choice", taskClass: "classification"))
        #expect(throws: UIContract.ValidationError.self) {
            try UIContract.validateEntry(phase: "x", surface: "wizard", taskClass: "distill")
        }
        #expect(throws: UIContract.ValidationError.self) {
            try UIContract.validateEntry(phase: "x", surface: "prose", taskClass: "vibes")
        }
    }

    // MARK: - test_core_contract_covers_every_core_phase

    @Test("core contract covers every core phase (minus the pack-only ones) and validates")
    func coreContractCoversPhases() throws {
        let contractPhases = Set(UIContract.coreContract.map(\.phase))
        // CORE_CONTRACT covers the same phases CORE_PHASES lists (both are the ten core phases).
        #expect(contractPhases == Set(coreGatePhases))
        for (phase, entry) in UIContract.coreContract {
            try UIContract.validateEntry(phase: phase, surface: entry.surface, taskClass: entry.taskClass)
        }
    }

    // MARK: - pack overlay (full_contract semantics)

    @Test("fullContract overlays pack entries on the core defaults")
    func fullContractOverlaysPack() throws {
        let pack = ["analysis": UIContract.Entry(surface: "choice", taskClass: "classification")]
        let full = UIContract.fullContract(packEntries: pack)
        #expect(full["brief"] == UIContract.Entry(surface: "prose", taskClass: "interpretation"))
        #expect(full["analysis"] == UIContract.Entry(surface: "choice", taskClass: "classification"))
    }
}
