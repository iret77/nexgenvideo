import Foundation
import Testing
@testable import NexGenEngine

@Suite("RenderManifest")
struct RenderManifestTests {
    // MARK: - Round-trip through the custom Codable implementation

    @Test("round-trips 2 entries through the custom Codable implementation")
    func roundTrip() throws {
        var manifest = RenderManifest(project: "proj", phase: "frames")
        manifest.entries["s001"] = RenderEntry(
            shotId: "s001", phase: "frames", status: .rendered, output: "s001.png", costEur: 1.23,
            updatedAt: "2026-01-01T00:00:00+00:00"
        )
        manifest.entries["s002"] = RenderEntry(shotId: "s002", phase: "frames", status: .pending)

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(RenderManifest.self, from: data)

        #expect(decoded.entries["s001"] == manifest.entries["s001"])
        #expect(decoded.entries["s002"] == manifest.entries["s002"])
        #expect(decoded.project == "proj")
        #expect(decoded.phase == "frames")
    }

    // MARK: - Legacy-mirror-keys wire format

    @Test("encodes both shots and results arrays with dual-mirror-key rows")
    func legacyMirrorKeys() throws {
        var manifest = RenderManifest(project: "proj", phase: "frames")
        manifest.entries["s001"] = RenderEntry(
            shotId: "s001", phase: "frames", status: .rendered, output: "s001.png", costEur: 1.5,
            updatedAt: "2026-01-01T00:00:00+00:00"
        )

        let data = try JSONEncoder().encode(manifest)
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let shots = try #require(raw["shots"] as? [[String: Any]])
        let results = try #require(raw["results"] as? [[String: Any]])
        #expect(shots.count == 1)
        #expect(results.count == 1)

        let shotsRow = shots[0]
        let resultsRow = results[0]
        #expect(shotsRow["shot_id"] as? String == resultsRow["shot_id"] as? String)
        #expect(shotsRow["cost_eur"] as? Double == shotsRow["eur_spent"] as? Double)
        #expect(shotsRow["output"] as? String == shotsRow["out_path"] as? String)
        #expect(resultsRow["cost_eur"] as? Double == resultsRow["eur_spent"] as? Double)
        #expect(resultsRow["output"] as? String == resultsRow["out_path"] as? String)
    }

    // MARK: - `_from_disk` legacy-only-keys fallback

    @Test("decodes legacy rows carrying only eur_spent/out_path (no cost_eur/output keys)")
    func legacyOnlyKeysFallback() throws {
        let json = """
        {
            "project": "proj",
            "phase": "frames",
            "schema": "render_manifest/v1",
            "shots": [
                {"shot_id": "s001", "phase": "frames", "status": "rendered",
                 "eur_spent": 2.5, "out_path": "legacy.png"}
            ],
            "results": [
                {"shot_id": "s001", "phase": "frames", "status": "rendered",
                 "eur_spent": 2.5, "out_path": "legacy.png"}
            ]
        }
        """
        let manifest = try JSONDecoder().decode(RenderManifest.self, from: Data(json.utf8))
        let entry = try #require(manifest.entries["s001"])
        #expect(entry.costEur == 2.5)
        #expect(entry.output == "legacy.png")
    }

    @Test("a row missing shot_id is skipped, not crashing")
    func rowMissingShotIdSkipped() throws {
        let json = """
        {
            "project": "proj",
            "phase": "frames",
            "shots": [
                {"phase": "frames", "status": "rendered", "cost_eur": 1.0},
                {"shot_id": "s002", "phase": "frames", "status": "pending"}
            ]
        }
        """
        let manifest = try JSONDecoder().decode(RenderManifest.self, from: Data(json.utf8))
        #expect(manifest.entries.count == 1)
        #expect(manifest.entries["s002"] != nil)
    }

    @Test("a row whose shot_id is not a string is skipped, not crashing")
    func rowNonStringShotIdSkipped() throws {
        let json = """
        {
            "project": "proj",
            "phase": "frames",
            "shots": [
                {"shot_id": 42, "phase": "frames", "status": "rendered", "cost_eur": 1.0},
                {"shot_id": "s002", "phase": "frames", "status": "pending"}
            ]
        }
        """
        let manifest = try JSONDecoder().decode(RenderManifest.self, from: Data(json.utf8))
        #expect(manifest.entries.count == 1)
        #expect(manifest.entries["s002"] != nil)
    }

    // MARK: - nextUnrendered()

    @Test("nextUnrendered returns the first shot that isn't rendered, in order")
    func nextUnrenderedOrderPreserving() {
        var manifest = RenderManifest(project: "proj", phase: "frames")
        manifest.entries["s002"] = RenderEntry(shotId: "s002", phase: "frames", status: .rendered)
        manifest.entries["s003"] = RenderEntry(shotId: "s003", phase: "frames", status: .failed)
        // s001 has no entry at all.
        let next = nextUnrendered(orderedShotIds: ["s001", "s002", "s003"], manifest: manifest)
        #expect(next == "s001")
    }

    // MARK: - record()

    @Test("record upserts an entry and defaults updatedAt via now() when nil")
    func recordUpsertsAndDefaultsUpdatedAt() {
        var manifest = RenderManifest(project: "proj", phase: "frames")
        record(
            &manifest, shotId: "s001", output: "s001.png", costEur: 1.0, phase: "frames",
            updatedAt: nil, now: { "2026-03-03T03:03:03+00:00" }
        )
        let entry = manifest.entries["s001"]
        #expect(entry?.output == "s001.png")
        #expect(entry?.status == .rendered)
        #expect(entry?.updatedAt == "2026-03-03T03:03:03+00:00")
    }

    // MARK: - spent()

    @Test("spent sums cost_eur across entries and rounds to 2 decimals")
    func spentSumsAndRounds() {
        var manifest = RenderManifest(project: "proj", phase: "frames")
        manifest.entries["s001"] = RenderEntry(shotId: "s001", phase: "frames", costEur: 1.111)
        manifest.entries["s002"] = RenderEntry(shotId: "s002", phase: "frames", costEur: 2.222)
        #expect(spent(manifest) == 3.33)
    }

    // MARK: - summary()

    @Test("summary counts total/rendered/pending/failed, including missing entries as pending")
    func summaryCounts() {
        var manifest = RenderManifest(project: "proj", phase: "frames")
        manifest.entries["s001"] = RenderEntry(shotId: "s001", phase: "frames", status: .rendered, costEur: 1.0)
        manifest.entries["s002"] = RenderEntry(shotId: "s002", phase: "frames", status: .failed)
        // s003 has no entry -> pending. s004 explicitly pending.
        manifest.entries["s004"] = RenderEntry(shotId: "s004", phase: "frames", status: .pending)

        let result = summary(orderedShotIds: ["s001", "s002", "s003", "s004"], manifest: manifest)
        #expect(result.total == 4)
        #expect(result.rendered == 1)
        #expect(result.failed == 1)
        #expect(result.pending == 2)
        #expect(result.spentEur == 1.0)
    }
}
