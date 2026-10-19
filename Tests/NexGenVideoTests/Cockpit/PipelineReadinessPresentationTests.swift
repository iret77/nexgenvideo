import Foundation
import NexGenEngine
import Testing
@testable import MusicvideoPlugin
@testable import NexGenVideo

@Suite("Pipeline readiness presentation")
struct PipelineReadinessPresentationTests {
    @Test("References failures carry a typed requirement without exposing diagnostics")
    func missingBible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try MusicvideoGateChecks.requireRealBible(dataRoot: root)
            Issue.record("A missing Bible must block approval")
        } catch let failure as PhaseArtifactFailure {
            #expect(failure.requirement == .document)
            #expect(failure.diagnostic.contains("bible/bible.yaml"))
            let message = PipelineReadinessPresentation.message(for: failure.requirement, phase: "bible")
            #expect(message.contains("References"))
            #expect(message.contains("reference images"))
            #expect(!message.contains("bible.yaml"))
            #expect(!message.contains(root.path))
        }
    }

    @Test("Missing character and location views have distinct visible explanations")
    func missingViews() {
        let characters = PipelineReadinessPresentation.message(for: .characterViews, phase: "bible")
        let locations = PipelineReadinessPresentation.message(for: .locationViews, phase: "bible")
        #expect(characters.contains("References"))
        #expect(characters.contains("character views"))
        #expect(locations.contains("location views"))
        #expect(!characters.contains("character_view_request"))
        #expect(!locations.contains("sheets"))
    }

    @Test("Current incomplete, running, reviewable and future phases remain distinct")
    func phaseStates() throws {
        let phase = try JSONDecoder().decode(ProjectPhase.self,
            from: Data(#"{"phase":"bible","approved":false,"state":"pending"}"#.utf8))
        let incomplete = PipelinePhasePresentation.resolve(phase: phase, isCurrent: true, isRunning: false, ready: false)
        let upcoming = PipelinePhasePresentation.resolve(phase: phase, isCurrent: false, isRunning: false, ready: false)
        #expect(incomplete == .incomplete)
        #expect(upcoming == .upcoming)
        #expect(incomplete.symbol != upcoming.symbol)
        #expect(incomplete.label != "Not started")
        #expect(PipelinePhasePresentation.resolve(phase: phase, isCurrent: true, isRunning: true, ready: false) == .running)
        #expect(PipelinePhasePresentation.resolve(phase: phase, isCurrent: true, isRunning: false, ready: true) == .ready)
    }

    @Test("Unsupported phases have no invented review destination")
    func noFallbackToTasks() throws {
        let contract = try JSONDecoder().decode(ContractData.self,
            from: Data(#"{"phases":{"unavailable":{"surface":"choice","task_class":"review"},"project_init":{"surface":"choice","task_class":"input"}}}"#.utf8))
        #expect(PipelineSurfaceRouting.route(for: "unavailable", contract: contract, availablePackSurfaces: []) == nil)
        #expect(PipelineSurfaceRouting.route(for: "project_init", contract: contract, availablePackSurfaces: [])?.destination == .tab(.project))
    }
}
