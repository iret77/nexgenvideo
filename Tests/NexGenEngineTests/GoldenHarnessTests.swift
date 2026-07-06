import Foundation
import Testing
@testable import NexGenEngine

/// Proves the golden plumbing: the Python-oracle JSON produced by
/// `scripts/regen-goldens.sh` is bundled and decodable. M1 turns these into
/// full parity assertions against the Swift artifact types.
@Suite("GoldenHarness")
struct GoldenHarnessTests {
    /// Load a bundled golden as a JSON object.
    static func golden(_ kind: String) throws -> [String: Any] {
        let url = try #require(
            Bundle.module.url(
                forResource: kind, withExtension: "json",
                subdirectory: "Goldens/basic-project"
            ),
            "golden \(kind).json not found in test bundle"
        )
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any], "\(kind).json is not a JSON object")
    }

    @Test("state golden parses and carries the expected top-level keys")
    func stateGoldenParses() throws {
        let state = try Self.golden("state")
        for key in ["project", "mode", "phases", "next_phase", "budget_eur"] {
            #expect(state[key] != nil, "state golden missing key \(key)")
        }
        #expect(state["project"] as? String == "basic-project")
        let phases = try #require(state["phases"] as? [Any])
        #expect(phases.count == 10)
    }

    @Test("phases golden is the ordered core pipeline")
    func phasesGoldenIsOrderedPipeline() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "phases", withExtension: "json", subdirectory: "Goldens/basic-project"
            )
        )
        let phases = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String]
        #expect(phases?.first == "project_init")
        #expect(phases?.last == "render")
    }

    @Test("brief and ledger goldens are decodable objects")
    func sidecarGoldensParse() throws {
        let brief = try Self.golden("brief")
        #expect(brief["project"] as? String == "basic-project")
        #expect(brief["schema"] as? String == "brief/v1")

        let ledger = try Self.golden("ledger")
        #expect(ledger["schema"] as? String == "ledger/v1")
        #expect(ledger["objects"] != nil)
    }
}
