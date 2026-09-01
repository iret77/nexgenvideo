import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite(
    "Pipeline phase execution",
    .serialized,
    .timeLimit(.minutes(1))
)
struct PipelinePhaseExecutionTests {
    @Test("native mutations and phase jobs exclude each other")
    func mutationReservation() async {
        let coordinator = PipelinePhaseRunCoordinator()
        let state = PipelinePhaseExecutionState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let mutation = coordinator.beginMutation(
            projectRoot: root,
            label: "Shot List edit"
        )
        #expect(mutation != nil)
        #expect(coordinator.runningPhase(projectRoot: root) == "Shot List edit")

        let outcome = await coordinator.run(
            projectRoot: root,
            phase: "shotlist",
            sourceFilename: nil,
            runner: { _ in },
            progressRunner: nil,
            state: state
        )
        #expect(outcome == .refused(activePhase: "Shot List edit"))

        let waiter = Task { await coordinator.waitUntilIdle(projectRoot: root) }
        await Task.yield()
        coordinator.endMutation(projectRoot: root, id: try! #require(mutation))
        await waiter.value
        #expect(coordinator.runningPhase(projectRoot: root) == nil)
    }

    @Test("record_render reserves the project across suspension and excludes run_phase")
    func recordRenderToolMutationLease() async throws {
        let harness = ToolHarness(enforceHardGates: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let mutation = try #require(
            harness.executor.reserveDurablePipelineMutation(
                tool: .recordRender,
                phase: "render",
                dataRoot: root,
                editor: harness.editor
            )
        )
        #expect(
            harness.editor.pipelinePhaseRunCoordinator.holdsMutation(
                projectRoot: root,
                id: mutation
            )
        )

        await Task.yield()
        let outcome = await harness.editor.pipelinePhaseRunCoordinator.run(
            projectRoot: root,
            phase: "render",
            sourceFilename: nil,
            runner: { _ in },
            progressRunner: nil,
            state: PipelinePhaseExecutionState()
        )

        #expect(outcome == .refused(activePhase: "render"))
        harness.editor.pipelinePhaseRunCoordinator.endMutation(
            projectRoot: root,
            id: mutation
        )
        #expect(
            !harness.editor.pipelinePhaseRunCoordinator.holdsMutation(
                projectRoot: root,
                id: mutation
            )
        )
        #expect(
            try harness.executor.reserveDurablePipelineMutation(
                tool: .runPhase,
                phase: "render",
                dataRoot: root,
                editor: harness.editor
            ) == nil
        )
    }

    @Test("approval control fails closed for blocked, writing, and running states")
    func approvalControlPredicate() {
        #expect(PipelineApprovalControl.isEnabled(
            approvalReady: true,
            controlsAvailable: true,
            gateWriting: false,
            pipelineIsRunning: false,
            hostDecisionPending: false
        ))
        #expect(!PipelineApprovalControl.isEnabled(
            approvalReady: false,
            controlsAvailable: true,
            gateWriting: false,
            pipelineIsRunning: false,
            hostDecisionPending: false
        ))
        #expect(!PipelineApprovalControl.isEnabled(
            approvalReady: true,
            controlsAvailable: true,
            gateWriting: true,
            pipelineIsRunning: false,
            hostDecisionPending: false
        ))
        #expect(!PipelineApprovalControl.isEnabled(
            approvalReady: true,
            controlsAvailable: true,
            gateWriting: false,
            pipelineIsRunning: true,
            hostDecisionPending: false
        ))
        #expect(!PipelineApprovalControl.isEnabled(
            approvalReady: true,
            controlsAvailable: false,
            gateWriting: false,
            pipelineIsRunning: false,
            hostDecisionPending: false
        ))
        #expect(!PipelineApprovalControl.isEnabled(
            approvalReady: true,
            controlsAvailable: true,
            gateWriting: false,
            pipelineIsRunning: false,
            hostDecisionPending: true
        ))
    }

    @Test("concurrent retries join one phase run")
    func retriesJoinOneRun() async {
        let counter = LockedCounter()
        let coordinator = PipelinePhaseRunCoordinator()
        let state = PipelinePhaseExecutionState()
        let latch = PhaseRunnerLatch()
        let retryJoined = TestAsyncSignal()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let runner: EngineRegistry.PhaseRunner = { _ in
            counter.increment()
            latch.block()
        }

        let first = Task.detached {
            await coordinator.run(
                projectRoot: root,
                phase: "analysis",
                sourceFilename: "track.wav",
                runner: runner,
                progressRunner: nil,
                state: state
            )
        }
        await latch.waitUntilEntered()
        let retry = Task.detached {
            await coordinator.run(
                projectRoot: root,
                phase: "analysis",
                sourceFilename: "track.wav",
                runner: runner,
                progressRunner: nil,
                state: state,
                onJoin: {
                    await retryJoined.signal()
                }
            )
        }
        await retryJoined.wait()

        #expect(counter.value == 1)
        latch.allowCompletion()
        let retryResult = await retry.value
        #expect(retryResult == .completed)
        #expect(state.snapshot?.status == .completed)
        #expect(await first.value == .completed)
        #expect(counter.value == 1)
    }

    @Test("a project runs only one phase at a time")
    func distinctPhaseIsRefused() async {
        let coordinator = PipelinePhaseRunCoordinator()
        let state = PipelinePhaseExecutionState()
        let latch = PhaseRunnerLatch()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let runner: EngineRegistry.PhaseRunner = { _ in
            latch.block()
        }

        let first = Task.detached {
            await coordinator.run(
                projectRoot: root,
                phase: "analysis",
                sourceFilename: "track.wav",
                runner: runner,
                progressRunner: nil,
                state: state
            )
        }
        await latch.waitUntilEntered()
        let refused = await coordinator.run(
            projectRoot: root,
            phase: "brief",
            sourceFilename: nil,
            runner: { _ in },
            progressRunner: nil,
            state: state
        )

        #expect(refused == .refused(activePhase: "analysis"))
        #expect(state.runningPhase(projectRoot: root) == "analysis")
        latch.allowCompletion()
        #expect(await first.value == .completed)
    }

    @Test("progress runner publishes the current deterministic stage")
    func progressRunnerPublishesStage() async {
        let coordinator = PipelinePhaseRunCoordinator()
        let state = PipelinePhaseExecutionState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let runner: EngineRegistry.PhaseRunner = { _ in }
        let progressRunner: EngineRegistry.ProgressPhaseRunner = { _, progress in
            progress(
                PhaseProgress(
                    sourceFilename: "Original Song.wav",
                    stageID: "detect_beat_grid",
                    completedUnitCount: 3,
                    totalUnitCount: 7,
                    nextStageID: "detect_harmony"
                )
            )
        }

        let outcome = await coordinator.run(
            projectRoot: root,
            phase: "analysis",
            sourceFilename: nil,
            runner: runner,
            progressRunner: progressRunner,
            state: state
        )

        #expect(outcome == .completed)
        #expect(state.snapshot?.sourceFilename == "Original Song.wav")
        #expect(state.snapshot?.stageID == "detect_beat_grid")
        #expect(state.snapshot?.completedUnitCount == 7)
        #expect(state.snapshot?.totalUnitCount == 7)
        #expect(state.snapshot?.status == .completed)
    }

    @Test("joined retries settle lineage once while the phase still owns the project")
    func joinedRetriesSettleOnce() async {
        let settlementCount = LockedCounter()
        let coordinator = PipelinePhaseRunCoordinator()
        let state = PipelinePhaseExecutionState()
        let latch = PhaseRunnerLatch()
        let retryJoined = TestAsyncSignal()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let runner: EngineRegistry.PhaseRunner = { _ in
            latch.block()
        }
        let settle: @MainActor @Sendable () async throws -> Void = {
            #expect(coordinator.runningPhase(projectRoot: root) == "analysis")
            settlementCount.increment()
        }

        let first = Task.detached {
            await coordinator.run(
                projectRoot: root,
                phase: "analysis",
                sourceFilename: "track.wav",
                runner: runner,
                progressRunner: nil,
                state: state,
                settleOnce: settle
            )
        }
        await latch.waitUntilEntered()
        let retry = Task.detached {
            await coordinator.run(
                projectRoot: root,
                phase: "analysis",
                sourceFilename: "track.wav",
                runner: runner,
                progressRunner: nil,
                state: state,
                settleOnce: settle,
                onJoin: {
                    await retryJoined.signal()
                }
            )
        }

        await retryJoined.wait()
        latch.allowCompletion()
        #expect(await first.value == .completed)
        #expect(await retry.value == .completed)
        #expect(settlementCount.value == 1)
        #expect(coordinator.runningPhase(projectRoot: root) == nil)
    }

    @Test("failed and blocked runners never settle phase lineage")
    func unsuccessfulRunsDoNotSettle() async {
        let settlementCount = LockedCounter()
        let coordinator = PipelinePhaseRunCoordinator()
        let state = PipelinePhaseExecutionState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settle: @MainActor @Sendable () async throws -> Void = {
            settlementCount.increment()
        }

        let failed = await coordinator.run(
            projectRoot: root,
            phase: "analysis",
            sourceFilename: nil,
            runner: { _ in throw ToolError("runner failed") },
            progressRunner: nil,
            state: state,
            settleOnce: settle
        )
        let blocked = await coordinator.run(
            projectRoot: root,
            phase: "analysis",
            sourceFilename: nil,
            runner: { _ in throw PipelinePhaseBlocked("track missing") },
            progressRunner: nil,
            state: state,
            settleOnce: settle
        )

        #expect(failed == .failed("runner failed"))
        #expect(blocked == .blocked("track missing"))
        #expect(settlementCount.value == 0)
        #expect(coordinator.runningPhase(projectRoot: root) == nil)
    }
}

final class PhaseRunnerLatch: @unchecked Sendable {
    private let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let condition = NSCondition()
    private var released = false

    init() {
        let pair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        entered = pair.stream
        enteredContinuation = pair.continuation
    }

    func block() {
        enteredContinuation.yield()
        condition.lock()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilEntered() async {
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
    }

    func allowCompletion() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
        enteredContinuation.finish()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.withLock { storedValue }
    }

    func increment() {
        lock.withLock {
            storedValue += 1
        }
    }
}
