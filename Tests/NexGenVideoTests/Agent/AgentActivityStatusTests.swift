import Foundation
import NexGenEngine
import os
import Testing
@testable import NexGenVideo

@Suite("Agent activity status")
struct AgentActivityStatusTests {
    @Test("An exact phase continuation avoids duplication without trimming a more specific task")
    func phaseContinuationTitle() {
        let continuation = AgentTaskActivityPresentation(task: .init(title: "Continue References", phase: "bible"))
        #expect(continuation.title == "Continue References")
        #expect(continuation.expectedResult == "Result: References for approval")
        let specific = AgentTaskActivityPresentation(task: .init(title: "Continue Bible images", phase: "bible"))
        #expect(specific.title == "Continue Bible images · References")
        let otherPhase = AgentTaskActivityPresentation(task: .init(title: "Continue Bible", phase: "shotlist"))
        #expect(otherPhase.title == "Continue Bible · Shot List")
    }

    @Test("Task identity and phase come from the host work order, not the latest tool")
    func taskIdentity() {
        let request = AgentMessage(role: .user, blocks: [.text("Host command")], hidden: true,
            userPresentation: .init(choiceRecord: .init(selections: [
                .init(label: "Task", values: ["Complete missing Bible images"]),
                .init(label: "Phase", values: ["bible"]),
            ], attachmentNames: [], confirmed: true), typedText: nil))
        let tool = AgentMessage(role: .assistant, blocks: [
            .toolUse(id: "read", name: "Read", inputJSON: #"{"file_path":"/project/treatment.md"}"#),
        ])
        let presentation = AgentTaskActivityPresentation(messages: [request, tool], phase: "render")
        #expect(presentation.title == "Complete missing Bible images · References")
        #expect(presentation.expectedResult == "Result: References for approval")
        let activity = AgentTranscriptProjection.turns(messages: [request, tool], isStreaming: true)
            .flatMap(\.items).compactMap { item -> AgentActivity? in
                guard case .activity(let value) = item else { return nil }
                return value
            }.last
        #expect(activity?.operationLabel == "Reading · treatment.md")
        #expect(!presentation.title.contains("Reading"))
    }

    @Test("A generic work order is never presented as an active production phase")
    func genericTaskDoesNotBorrowCurrentPhase() {
        let request = AgentMessage(role: .user, blocks: [], hidden: true,
            userPresentation: .init(choiceRecord: .init(selections: [
                .init(label: "Task", values: ["Organize media"]),
            ], attachmentNames: [], confirmed: true), typedText: nil))
        let presentation = AgentTaskActivityPresentation(messages: [request], phase: "bible")
        #expect(presentation.title == "Organize media")
        #expect(presentation.expectedResult == nil)
        #expect(ToolRunPresentation.label(for: "Read", inputJSON: "invalid") == "Reading a file")
    }

    @Test("Silence becomes prominent at sixty seconds, never before")
    func silenceThreshold() {
        let start = Date(timeIntervalSince1970: 1_000)
        let timing = AgentActivityTiming(startedAt: start, lastEventAt: start.addingTimeInterval(20))
        #expect(!timing.isUnconfirmed(at: start.addingTimeInterval(79)))
        #expect(timing.isUnconfirmed(at: start.addingTimeInterval(80)))
    }

    @Test("Provider confirmation is liveness, not step progress")
    func providerConfirmationTiming() {
        let start = Date(timeIntervalSince1970: 1_000)
        var timing = AgentActivityTiming(startedAt: start, lastEventAt: start.addingTimeInterval(5))
        #expect(timing.isUnconfirmed(at: start.addingTimeInterval(65)))

        timing.providerConfirmedAt = start.addingTimeInterval(50)
        #expect(timing.lastEventAt == start.addingTimeInterval(5))
        #expect(timing.silence(at: start.addingTimeInterval(65)) == 15)
        #expect(!timing.isUnconfirmed(at: start.addingTimeInterval(65)))
        #expect(timing.isUnconfirmed(at: start.addingTimeInterval(110)))
        #expect(timing.elapsed(at: start.addingTimeInterval(110)) == 110)
    }

    @Test("Activity history keeps distinct recent steps")
    func eventHistory() {
        var events: [AgentActivityEvent] = []
        let start = Date(timeIntervalSince1970: 0)
        events = AgentActivityEvent.appending(.init(at: start, label: "Read project"), to: events)
        events = AgentActivityEvent.appending(.init(at: start.addingTimeInterval(1), label: "Read project"), to: events)
        #expect(events == [.init(at: start, label: "Read project")])
        for index in 0..<10 {
            events = AgentActivityEvent.appending(.init(at: start, label: "Step \(index)"), to: events)
        }
        #expect(events.count == 8)
        #expect(events.last?.label == "Step 9")
    }

    @Test("Provider status reaches unstructured child tasks of its run only")
    func providerSignalScope() async {
        let confirmations = OSAllocatedUnfairLock(initialState: 0)
        ProviderStatusSignal.confirmRunning()
        await ProviderStatusSignal.$observer.withValue({ confirmations.withLock { $0 += 1 } }) {
            await Task { ProviderStatusSignal.confirmRunning() }.value
            await Task.detached { ProviderStatusSignal.confirmRunning() }.value
        }
        ProviderStatusSignal.confirmRunning()
        #expect(confirmations.withLock { $0 } == 1)
    }

    @MainActor
    @Test("Batch liveness ignores batches that are not running")
    func batchProviderStatus() {
        let coordinator = GenerationBatchCoordinator()
        coordinator.recordProviderStatus(batchID: "stale")
        #expect(coordinator.providerConfirmedAt["stale"] == nil)
    }

    @Test("Earlier answers are marked while new work runs")
    func lastResultMarker() {
        let firstRequest = AgentMessage(role: .user, blocks: [.text("Write the treatment")])
        let earlier = AgentMessage(role: .assistant, blocks: [.text("The treatment is approved.")])
        let nextRequest = AgentMessage(role: .user, blocks: [.text("Draft the storyboard")])
        let current = AgentMessage(role: .assistant, blocks: [.text("Reading the treatment")])
        let messages = [firstRequest, earlier, nextRequest, current]
        let items = AgentTranscriptProjection.taskItems(messages: messages, isStreaming: true)
        let earlierID = "result-\(earlier.id.uuidString)"
        let currentID = "result-\(current.id.uuidString)"

        #expect(AgentTaskResultMarker.lastEarlierResultID(
            items: items, messages: messages, currentTurnBaseline: nextRequest.id, workIsRunning: true
        ) == earlierID)
        #expect(AgentTaskResultMarker.lastEarlierResultID(
            items: items, messages: messages, currentTurnBaseline: nil, workIsRunning: true
        ) == currentID)
        #expect(AgentTaskResultMarker.lastEarlierResultID(
            items: items, messages: messages, currentTurnBaseline: nextRequest.id, workIsRunning: false
        ) == nil)
        #expect(AgentTaskResultMarker.lastEarlierResultID(
            items: items, messages: messages, currentTurnBaseline: UUID(), workIsRunning: true
        ) == nil)
    }

    @MainActor
    @Test("Phase history records runner stage boundaries, not timer ticks")
    func phaseStageHistory() {
        let state = PipelinePhaseExecutionState()
        let runID = UUID()
        let start = Date(timeIntervalSince1970: 0)
        state.begin(runID: runID, projectRoot: FileManager.default.temporaryDirectory,
                    phase: "analysis", sourceFilename: "song.wav")
        #expect(state.snapshot?.lastEventAt == nil)
        func progress(_ stage: String, _ completed: Int) -> PhaseProgress {
            PhaseProgress(sourceFilename: "song.wav", stageID: stage, completedUnitCount: completed,
                          totalUnitCount: 3, nextStageID: nil)
        }
        state.update(runID: runID, progress: progress("decode_audio", 0), at: start)
        state.update(runID: runID, progress: progress("decode_audio", 0), at: start.addingTimeInterval(4))
        state.update(runID: runID, progress: progress("measure_structure", 1), at: start.addingTimeInterval(9))
        state.update(runID: UUID(), progress: progress("write_analysis", 2), at: start.addingTimeInterval(12))

        #expect(state.snapshot?.stageEvents.map(\.stageID) == ["decode_audio", "measure_structure"])
        #expect(state.snapshot?.stageEvents.map(\.at) == [start, start.addingTimeInterval(9)])
        #expect(state.snapshot?.lastEventAt == start.addingTimeInterval(9))
    }
}
