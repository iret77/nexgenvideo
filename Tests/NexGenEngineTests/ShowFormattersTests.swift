import Foundation
import Testing
@testable import NexGenEngine

@Suite("ShowArtifact dispatch + formatters")
struct ShowFormattersTests {

    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("show-\(UUID().uuidString)")
        return url
    }

    @Test("unknown gate returns the no-display-artifact note")
    func unknownGate() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "demo")

        #expect(ShowArtifact.gate("nope", dataRoot: dataRoot) == "_Gate `nope` has no display artifact._")
    }

    @Test("gates with no artifact on an empty project return their placeholder")
    func missingArtifactPlaceholders() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "demo")

        #expect(ShowArtifact.gate("brief", dataRoot: dataRoot) == "_Nothing for gate `brief` yet._")
        #expect(ShowArtifact.gate("treatment", dataRoot: dataRoot) == "_Nothing for gate `treatment` yet._")
        #expect(ShowArtifact.gate("bible", dataRoot: dataRoot) == "_No bible.yaml exists._")
        #expect(ShowArtifact.gate("shotlist", dataRoot: dataRoot) == "_No shotlist/current.yaml exists._")
        #expect(ShowArtifact.gate("analysis", dataRoot: dataRoot) == "_No analysis/ directory exists — analysis has not run._")
        #expect(ShowArtifact.gate("production_design", dataRoot: dataRoot) == "_No production_design.yaml exists — Production Design has not run._")
        #expect(ShowArtifact.gate("storyboard", dataRoot: dataRoot) == "_No storyboard `current` exists — Storyboard has not run._")

        let renders = ShowArtifact.gate("render", dataRoot: dataRoot)
        #expect(renders.hasPrefix("## Renders · demo · preview"))
        #expect(renders.contains("render phase R1 has not run"))
    }

    @Test("brief gate renders the artifact once written")
    func briefSmoke() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "demo")

        let brief = try Brief(
            project: "demo",
            generated: "2026-01-01",
            mission: .singleRelease,
            targetPlatform: "YouTube",
            aspectRatio: .landscape16x9,
            projectMode: "beat",
            conceptType: .narrative,
            visualMedium: .liveActionRealistic,
            figures: .artistOnly,
            lyricsIntegration: .literal
        )
        try YAMLArtifactStore(dataRoot: dataRoot).save(brief, to: PipelineLayout.briefFile)

        let out = ShowArtifact.gate("brief", dataRoot: dataRoot)
        #expect(out.hasPrefix("## Brief · demo"))
        #expect(out.contains("| Mission | `single_release` → YouTube |"))
        #expect(out.contains("| Budget | 50.00 € |"))
    }
}
