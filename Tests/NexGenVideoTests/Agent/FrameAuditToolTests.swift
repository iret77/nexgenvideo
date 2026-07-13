import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine
import MusicvideoPlugin

/// `save_frame_audit` / `get_frame_audit` driven through ToolExecutor against a temp scaffolded
/// project. Asserts the strict schema (all standard keys, enum statuses, overall/worst consistency),
/// that machine-owned fields (render_sha256, expected, auto_rerender_attempt) are executor-set and
/// adversarial agent values are ignored, and the routing verdict.
@MainActor
@Suite("Frame audit tools")
struct FrameAuditToolTests {

    private func scaffold() throws -> (ToolHarness, URL, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("frameaudit-tools-\(UUID().uuidString)", isDirectory: true)
        let home = tmp.appendingPathComponent("proj", isDirectory: true)
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "demo", mode: .beat)
        return (ToolHarness(), dataRoot, tmp)
    }

    private func minimalShotlist() throws -> Shotlist {
        let shot = try Shot(
            id: "s001", section: "verse", timeStart: 0.0, timeEnd: 4.0, durationS: 4.0,
            type: .performance, description: "d", visualPrompt: "p", mood: "m")
        let song = try Song(title: "t", audioPath: "a.wav", analysisPath: "an.json", bpm: 120.0, durationS: 4.0)
        return try Shotlist(
            schema_: shotlistSchemaVersion, mode: .section, project: "demo", song: song,
            generated: "2026-01-01", generator: "test", shots: [shot])
    }

    /// All 10 standard keys, defaulting to clean; `overrides` swaps individual statuses. `extra`
    /// injects additional per-check fields (e.g. an adversarial `expected`) into the given key.
    private func checks(_ overrides: [String: String] = [:], extra: [String: [String: Any]] = [:]) -> [String: Any] {
        var out: [String: Any] = [:]
        for k in standardAuditCheckKeys {
            var c: [String: Any] = ["status": overrides[k] ?? "clean"]
            for (ek, ev) in extra[k] ?? [:] { c[ek] = ev }
            out[k] = c
        }
        return out
    }

    /// Write `bytes` to a frame image under the project home and return its absolute path.
    private func writeFrame(_ bytes: String, dataRoot: URL, name: String = "s001-start.png") throws -> String {
        let home = FrameInventory.projectHome(of: dataRoot)
        let dir = home.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url.path
    }

    @Test("clean audit → APPROVE, with machine-set sha + spec-derived expected")
    func cleanApprove() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try minimalShotlist(), to: dataRoot)
        let path = try writeFrame("frameA", dataRoot: dataRoot)

        let res = try await h.runOK("save_frame_audit", args: [
            "project_dir": dataRoot.path, "shot_id": "s001", "auditor": "orchestrator-claude",
            "overall": "clean", "path": path, "checks": checks(),
        ]) as? [String: Any]
        #expect(res?["verdict"] as? String == "APPROVE")
        #expect(res?["has_blocking"] as? Bool == false)
        #expect((res?["render_sha256"] as? String)?.isEmpty == false)
        #expect(res?["auto_rerender_attempt"] as? Int == 0)
        // character_count expected comes from the shot spec (0 refs), not the model.
        let ck = try #require(res?["checks"] as? [String: Any])
        let cc = try #require(ck["character_count"] as? [String: Any])
        #expect(cc["expected"] as? String == "0")
    }

    @Test("adversarial expected inside a check is overridden by the shot spec")
    func expectedIsMachineOwned() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try minimalShotlist(), to: dataRoot)
        let path = try writeFrame("frameA", dataRoot: dataRoot)

        let res = try await h.runOK("save_frame_audit", args: [
            "project_dir": dataRoot.path, "shot_id": "s001", "auditor": "x", "overall": "clean",
            "path": path, "checks": checks(extra: ["character_count": ["expected": "999 LIE"]]),
        ]) as? [String: Any]
        let ck = try #require(res?["checks"] as? [String: Any])
        let cc = try #require(ck["character_count"] as? [String: Any])
        #expect(cc["expected"] as? String == "0")
    }

    @Test("blocking check with a non-blocking overall is rejected (fix-and-recall)")
    func inconsistentOverallRejected() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try minimalShotlist(), to: dataRoot)
        let path = try writeFrame("frameA", dataRoot: dataRoot)

        let raw = await h.runRaw("save_frame_audit", args: [
            "project_dir": dataRoot.path, "shot_id": "s001", "auditor": "x", "overall": "clean",
            "path": path, "checks": checks(["framing": "blocking"]),
        ])
        #expect(raw.isError)
        #expect(ToolHarness.textOf(raw).contains("blocking"))
    }

    @Test("a missing standard check key is rejected")
    func missingKeyRejected() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try minimalShotlist(), to: dataRoot)
        let path = try writeFrame("frameA", dataRoot: dataRoot)
        var partial = checks()
        partial.removeValue(forKey: "gaze")

        let raw = await h.runRaw("save_frame_audit", args: [
            "project_dir": dataRoot.path, "shot_id": "s001", "auditor": "x", "overall": "clean",
            "path": path, "checks": partial,
        ])
        #expect(raw.isError)
        #expect(ToolHarness.textOf(raw).contains("gaze"))
    }

    @Test("blocking → RERENDER, and a genuine re-render (new sha) bumps the attempt counter")
    func rerenderAttemptCounter() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try minimalShotlist(), to: dataRoot)

        let pathA = try writeFrame("frameA", dataRoot: dataRoot)
        let first = try await h.runOK("save_frame_audit", args: [
            "project_dir": dataRoot.path, "shot_id": "s001", "auditor": "x", "overall": "blocking",
            "path": pathA, "checks": checks(["framing": "blocking"]),
            "auto_rerender_patch": "STRICT: subject must face away",
        ]) as? [String: Any]
        #expect(first?["verdict"] as? String == "RERENDER")
        #expect(first?["auto_rerender_attempt"] as? Int == 0)
        #expect(first?["attempts_left"] as? Int == 2)

        // Re-render produced different bytes at the same path → new sha → attempt bumps to 1.
        let pathB = try writeFrame("frameB-different", dataRoot: dataRoot)
        #expect(pathA == pathB)  // same filename, new content
        let second = try await h.runOK("save_frame_audit", args: [
            "project_dir": dataRoot.path, "shot_id": "s001", "auditor": "x", "overall": "blocking",
            "path": pathB, "checks": checks(["framing": "blocking"]),
        ]) as? [String: Any]
        #expect(second?["auto_rerender_attempt"] as? Int == 1)
        #expect(second?["verdict"] as? String == "RERENDER")

        // get_frame_audit reflects the stored verdict.
        let got = try await h.runOK("get_frame_audit", args: [
            "project_dir": dataRoot.path, "shot_id": "s001",
        ]) as? [String: Any]
        #expect(got?["exists"] as? Bool == true)
        #expect(got?["auto_rerender_attempt"] as? Int == 1)
        #expect(got?["overall"] as? String == "blocking")
    }

    @Test("get_frame_audit reports exists:false when nothing was saved")
    func getAbsent() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let got = try await h.runOK("get_frame_audit", args: [
            "project_dir": dataRoot.path, "shot_id": "s001",
        ]) as? [String: Any]
        #expect(got?["exists"] as? Bool == false)
    }
}
