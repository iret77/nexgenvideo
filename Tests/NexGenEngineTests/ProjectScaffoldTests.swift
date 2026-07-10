import Foundation
import Testing
@testable import NexGenEngine

/// Port of `engine/tests/test_gates_layout.py`: scaffold creates core + pack dirs and saves
/// ProjectMeta/Gates; gates block until approved; rewind resets the target and everything after it
/// (including an injected pack phase).
@Suite("ProjectScaffold + Gates")
struct ProjectScaffoldTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scaffold-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - test_layout_creates_core_plus_pack_dirs

    @Test("init_project creates core + pack dirs and saves meta + gates")
    func layoutCreatesCorePlusPackDirs() throws {
        let tmp = tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = tmp.appendingPathComponent("proj")

        let dataRoot = try ProjectScaffold.initProject(
            home: home, name: "demo", mode: .beat, extraDirs: ["audio", "lyrics", "analysis"]
        )

        let fm = FileManager.default
        var isDir: ObjCBool = false
        for core in ["bible", "treatment"] {
            #expect(fm.fileExists(atPath: dataRoot.appendingPathComponent(core).path, isDirectory: &isDir) && isDir.boolValue)
        }
        for pack in ["audio", "analysis"] {
            #expect(fm.fileExists(atPath: dataRoot.appendingPathComponent(pack).path, isDirectory: &isDir) && isDir.boolValue)
        }
        // .gitkeep dropped in each dir.
        #expect(fm.fileExists(atPath: dataRoot.appendingPathComponent("bible/.gitkeep").path))
        // No stray user zones at home — a project is just its pipeline data root.
        for zone in ["inbox", "review", "final"] {
            #expect(!fm.fileExists(atPath: home.appendingPathComponent(zone).path))
        }

        let store = YAMLArtifactStore(dataRoot: dataRoot)
        let meta = try store.load(ProjectMeta.self, at: PipelineLayout.projectFile)
        #expect(meta.project == "demo")
        #expect(meta.budgetEur == 50.0)
        #expect(fm.fileExists(atPath: dataRoot.appendingPathComponent(PipelineLayout.gatesFile).path))
    }

    @Test("init_project on an existing project throws alreadyAProject")
    func initTwiceThrows() throws {
        let tmp = tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = tmp.appendingPathComponent("proj")
        _ = try ProjectScaffold.initProject(home: home, name: "demo")
        #expect(throws: ProjectScaffold.ScaffoldError.self) {
            try ProjectScaffold.initProject(home: home, name: "demo")
        }
    }

    // MARK: - test_gates_block_until_approved

    @Test("gates block until approved")
    func gatesBlockUntilApproved() throws {
        var gates = Gates(project: "demo")
        #expect(throws: GateBlocked.self) {
            _ = try GatesOperations.require(gates, phase: "bible")
        }
        GatesOperations.approve(&gates, phase: "bible", notes: "ok")
        #expect(try GatesOperations.require(gates, phase: "bible").approved)
        #expect(gates.get("bible").approved)
    }

    // MARK: - test_rewind_resets_target_and_following (incl. pack phase)

    @Test("rewind resets target and everything after it, keeping earlier phases")
    func rewindResetsTargetAndFollowing() throws {
        var gates = Gates(project: "demo")
        for phase in ["treatment", "bible", "frames"] {
            GatesOperations.approve(&gates, phase: phase)
        }
        let affected = try GatesOperations.rewindTo(&gates, target: "bible")
        #expect(gates.get("treatment").approved)   // before target → untouched
        #expect(!gates.get("bible").approved)       // target + following → reset
        #expect(!gates.get("frames").approved)
        #expect(affected == ["bible", "shotlist", "sanity", "frames", "render"])
    }

    @Test("rewind over a merged core+pack phase order includes the injected pack phase")
    func rewindWithPackPhase() throws {
        // Music pack inserts "analysis" after project_init; the merged order is what rewind walks.
        let order = ["project_init", "analysis", "brief", "production_design", "treatment",
                     "storyboard", "bible", "shotlist", "sanity", "frames", "render"]
        var gates = Gates(project: "demo")
        for phase in order { GatesOperations.approve(&gates, phase: phase) }
        let affected = try GatesOperations.rewindTo(&gates, target: "analysis", order: order)
        #expect(gates.get("project_init").approved)   // before target → untouched
        #expect(!gates.get("analysis").approved)
        #expect(!gates.get("brief").approved)
        #expect(affected.first == "analysis")
        #expect(affected.contains("brief"))
        #expect(affected.last == "render")
    }
}
