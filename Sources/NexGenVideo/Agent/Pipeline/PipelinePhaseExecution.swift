import Foundation
import NexGenEngine

enum PipelinePhaseExecutionStatus: Equatable {
    case running
    case completed
    case failed(String)
}

enum PipelinePhaseRunOutcome: Equatable {
    case completed
    case blocked(String)
    case failed(String)
    case refused(activePhase: String)
}

struct PipelinePhaseBlocked: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct PipelinePhaseExecutionSnapshot: Equatable {
    let runID: UUID
    let projectRootPath: String
    let phase: String
    var sourceFilename: String?
    var stageID: String?
    var completedUnitCount: Int
    var totalUnitCount: Int
    var nextStageID: String?
    var status: PipelinePhaseExecutionStatus

    var isRunning: Bool { status == .running }
}

@Observable
@MainActor
final class PipelinePhaseExecutionState {
    private(set) var snapshot: PipelinePhaseExecutionSnapshot?

    func begin(
        runID: UUID,
        projectRoot: URL,
        phase: String,
        sourceFilename: String?
    ) {
        snapshot = PipelinePhaseExecutionSnapshot(
            runID: runID,
            projectRootPath: Self.canonicalPath(projectRoot),
            phase: phase,
            sourceFilename: sourceFilename,
            stageID: nil,
            completedUnitCount: 0,
            totalUnitCount: 0,
            nextStageID: nil,
            status: .running
        )
    }

    func update(runID: UUID, progress: PhaseProgress) {
        guard var current = snapshot,
              current.runID == runID,
              current.status == .running
        else { return }
        current.sourceFilename = progress.sourceFilename ?? current.sourceFilename
        current.stageID = progress.stageID
        current.completedUnitCount = progress.completedUnitCount
        current.totalUnitCount = progress.totalUnitCount
        current.nextStageID = progress.nextStageID
        snapshot = current
    }

    func complete(runID: UUID) {
        guard snapshot?.runID == runID else { return }
        snapshot?.completedUnitCount = snapshot?.totalUnitCount ?? 0
        snapshot?.nextStageID = nil
        snapshot?.status = .completed
    }

    func fail(runID: UUID, message: String) {
        guard snapshot?.runID == runID else { return }
        snapshot?.nextStageID = nil
        snapshot?.status = .failed(message)
    }

    func reset() {
        snapshot = nil
    }

    func isRunning(projectRoot: URL, phase: String) -> Bool {
        guard let snapshot else { return false }
        return snapshot.isRunning
            && snapshot.phase == phase
            && snapshot.projectRootPath == Self.canonicalPath(projectRoot)
    }

    func runningPhase(projectRoot: URL) -> String? {
        guard let snapshot,
              snapshot.isRunning,
              snapshot.projectRootPath == Self.canonicalPath(projectRoot)
        else { return nil }
        return snapshot.phase
    }

    private static func canonicalPath(_ root: URL) -> String {
        root.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

@Observable
@MainActor
final class PipelinePhaseRunCoordinator {
    private enum RunnerResult: Sendable {
        case completed
        case blocked(String)
        case failed(String)
    }

    private struct Key: Hashable {
        let projectRootPath: String
    }

    private struct Job {
        let runID: UUID
        let phase: String
        let task: Task<PipelinePhaseRunOutcome, Never>
    }

    private var jobs: [Key: Job] = [:]

    private func key(for projectRoot: URL) -> Key {
        Key(
            projectRootPath: projectRoot.standardizedFileURL
                .resolvingSymlinksInPath().path
        )
    }

    var hasRunningJobs: Bool {
        !jobs.isEmpty
    }

    func runningPhase(projectRoot: URL) -> String? {
        jobs[key(for: projectRoot)]?.phase
    }

    func waitUntilIdle(projectRoot: URL) async {
        let key = key(for: projectRoot)
        if let job = jobs[key] {
            _ = await job.task.value
        }
    }

    func run(
        projectRoot: URL,
        phase: String,
        sourceFilename: String?,
        runner: @escaping EngineRegistry.PhaseRunner,
        progressRunner: EngineRegistry.ProgressPhaseRunner?,
        state: PipelinePhaseExecutionState,
        settleOnce: @escaping @MainActor @Sendable () async throws -> Void = {},
        onJoin: @escaping @MainActor @Sendable () async -> Void = {}
    ) async -> PipelinePhaseRunOutcome {
        let key = key(for: projectRoot)
        if let existing = jobs[key] {
            guard existing.phase == phase else {
                return .refused(activePhase: existing.phase)
            }
            Log.mcp.notice("phase run joined phase=\(phase) run=\(existing.runID.uuidString)")
            await onJoin()
            return await existing.task.value
        }

        let runID = UUID()
        let (progressStream, progressContinuation) = AsyncStream.makeStream(
            of: PhaseProgress.self
        )
        state.begin(
            runID: runID,
            projectRoot: projectRoot,
            phase: phase,
            sourceFilename: sourceFilename
        )
        let progressTask = Task {
            for await progress in progressStream {
                state.update(runID: runID, progress: progress)
            }
        }
        let runnerTask = Task {
            await Self.executeRunner(
                projectRoot: projectRoot,
                runner: runner,
                progressRunner: progressRunner,
                progressContinuation: progressContinuation
            )
        }
        let task = Task { @MainActor [weak self] () -> PipelinePhaseRunOutcome in
            var result = await runnerTask.value
            progressContinuation.finish()
            await progressTask.value
            if case .completed = result {
                do {
                    try await settleOnce()
                } catch {
                    result = .failed(error.localizedDescription)
                }
            }
            let outcome: PipelinePhaseRunOutcome
            switch result {
            case .completed:
                state.complete(runID: runID)
                Log.mcp.notice("phase run completed phase=\(phase) run=\(runID.uuidString)")
                outcome = .completed
            case .blocked(let message):
                state.fail(runID: runID, message: message)
                Log.mcp.notice("phase run blocked phase=\(phase) run=\(runID.uuidString)")
                outcome = .blocked(message)
            case .failed(let failure):
                state.fail(runID: runID, message: failure)
                Log.mcp.error("phase run failed phase=\(phase) run=\(runID.uuidString)")
                outcome = .failed(failure)
            }
            if self?.jobs[key]?.runID == runID {
                self?.jobs.removeValue(forKey: key)
            }
            return outcome
        }
        jobs[key] = Job(runID: runID, phase: phase, task: task)
        Log.mcp.notice("phase run started phase=\(phase) run=\(runID.uuidString)")
        return await task.value
    }

    private nonisolated static func executeRunner(
        projectRoot: URL,
        runner: @escaping EngineRegistry.PhaseRunner,
        progressRunner: EngineRegistry.ProgressPhaseRunner?,
        progressContinuation: AsyncStream<PhaseProgress>.Continuation
    ) async -> RunnerResult {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                let result: RunnerResult = autoreleasepool {
                    do {
                        if let progressRunner {
                            try progressRunner(projectRoot) {
                                progressContinuation.yield($0)
                            }
                        } else {
                            try runner(projectRoot)
                        }
                        return .completed
                    } catch let blocked as PipelinePhaseBlocked {
                        return .blocked(blocked.message)
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                }
                continuation.resume(returning: result)
            }
            thread.name = "NexGenVideo phase runner"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}
