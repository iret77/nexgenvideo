import Foundation
import MusicvideoPlugin
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Review destinations — one name and one target per phase")
struct ReviewDestinationParityTests {

    @Test("Every routed phase names exactly the destination it opens")
    func everyPhaseNamesItsDestination() throws {
        _ = try CurrentMusicvideoFixture.load()
        for activePack in [nil, "musicvideo"] as [String?] {
            let contract = try JSONDecoder().decode(
                ContractData.self,
                from: NativeCockpitReader.contractJSON(activePack: activePack)
            )
            #expect(contract.phases["storyboard"] != nil)
            for surfaces in [contract.cockpitSurfaces, []] {
                for phase in contract.phases.keys.sorted() {
                    let label = PipelineSurfaceRouting.reviewDestinationLabel(
                        for: phase, contract: contract, availablePackSurfaces: surfaces)
                    guard let route = PipelineSurfaceRouting.route(
                        for: phase, contract: contract, availablePackSurfaces: surfaces) else {
                        #expect(label == CockpitTab.pipeline.displayName)
                        continue
                    }
                    #expect(route.destinationLabel == label, "\(phase)")
                    switch route.destination {
                    case .tab(let tab):
                        #expect(CockpitTab.allCases.contains(tab), "\(phase)")
                        #expect(label == tab.displayName, "\(phase)")
                    case .pack(let id, let title):
                        #expect(surfaces.contains { $0.id == id && $0.displayName == title && $0.phase == phase })
                        #expect(label == title, "\(phase)")
                    }
                }
            }
            let storyboard = PipelineSurfaceRouting.route(
                for: "storyboard", contract: contract, availablePackSurfaces: contract.cockpitSurfaces)
            #expect(storyboard?.destination == .tab(.storyboard))
            #expect(storyboard?.destinationLabel == "Storyboard")
        }
    }

    @Test("A pending Storyboard approval is named and opened as Storyboard by card, agent and Pipeline")
    func pendingStoryboardApprovalUsesOneDestination() async throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-destination-\(UUID().uuidString).ngv", isDirectory: true)
        let editor = EditorViewModel()
        defer {
            editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: package)
        }
        try Fixtures.prepareProjectPackage(at: package)
        _ = try ProjectScaffold.initProject(home: package, name: "review-destination")
        editor.projectURL = package
        await editor.refreshEngineState()
        let dataRoot = try #require(editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) })
        let contract = try #require(editor.uiContract)
        let label = PipelineSurfaceRouting.reviewDestinationLabel(
            for: "storyboard", contract: contract,
            availablePackSurfaces: editor.availableCockpitPackSurfaces)
        let row = try #require(PipelineSurfaceRouting.route(
            for: "storyboard", contract: contract,
            availablePackSurfaces: editor.availableCockpitPackSurfaces))
        #expect(label == CockpitTab.storyboard.displayName)
        #expect(row.destinationLabel == label)

        _ = try editor.agentService.requestGateApproval(GateApproval(phase: "storyboard", dataRoot: dataRoot))
        let executor = ToolExecutor(editor: editor, enforceHardGates: false)
        let result = await executor.execute(name: "approve_gate", args: ["phase": "project_init"])
        let json = try JSONSerialization.jsonObject(with: Data(ToolHarness.textOf(result).utf8))
        let payload = try #require(json as? [String: Any])
        #expect(result.turnDisposition == .suspendTurn)
        #expect(payload["phase"] as? String == "storyboard")
        #expect(payload["review_surface"] as? String == label)

        editor.cockpitTab = .pipeline
        editor.revealReviewSurface(for: "storyboard")
        #expect(editor.cockpitTab == .storyboard)
        #expect(editor.cockpitPackSurfaceID == nil)
        #expect(editor.workspaceFocus == .production)
    }

}
