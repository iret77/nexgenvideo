import Foundation
import NexGenEngine

@MainActor
enum GenerationBatchBusyOwnerAcceptance {
    @MainActor
    private final class CatalogBarrier {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private(set) var started = false
        private(set) var resumed = false
        private(set) var waiterCount = 0

        func wait() async {
            started = true
            waiterCount += 1
            if !released {
                await withCheckedContinuation { continuations.append($0) }
            }
            resumed = true
        }

        func release() {
            released = true
            let waiting = continuations
            continuations.removeAll()
            waiting.forEach { $0.resume() }
        }
    }

    static func generateFrame(shotID: String, role: String, image: Data,
        context: ProductionPlanningAcceptanceFixture.Context, generation: ProductionV2GenerationAcceptance,
        driver: ProductionVisualSourcesDriver) async throws -> PipelineProductionFrameCandidates.Item {
        guard WorkspaceUIAcceptance.isRequested, let home = context.editor.workingRoot else {
            throw GateBlocked("The isolated native batch acceptance process is required.")
        }
        let editor = context.editor, coordinator = editor.generationBatchCoordinator
        let originalReadiness = coordinator.catalogReadiness
        let barrier = CatalogBarrier()
        var approvedID: String?
        var armedBatchID: String?
        var completed = false
        defer {
            if !completed, let batchID = approvedID ?? armedBatchID,
               let actual = try? GenerationBatchStore.load(id: batchID, home: home), actual.authorityAvailable {
                coordinator.cancelRemaining(batchID: batchID, editor: editor)
            }
            coordinator.catalogReadiness = originalReadiness
            barrier.release()
        }
        let item = try await ProductionFramesOwnerAcceptance.generate(shotID: shotID, role: role, image: image,
            context: context, generation: generation, driver: driver, afterBatchApproval: { batchID in
                approvedID = batchID
                try await driver.wait("approved batch reached actual catalog barrier") {
                    barrier.started && coordinator.activeBatchID == batchID
                }
                let activeBatchBeforeRelease = coordinator.activeBatchID
                let approved = try GenerationBatchStore.load(id: batchID, home: home)
                guard approved.authorityAvailable, approved.journal.executions.allSatisfy({ $0.state == .queued }),
                      MusicvideoGenerationHTTP.requests.isEmpty else { throw GateBlocked("The approved requests were sent before the host lease check.") }
                let spendBefore = editor.generationLog.spendEvents
                guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: context.dataRoot, label: "Isolated competing native edit") else {
                    throw GateBlocked("The actual competing mutation lease is unavailable.")
                }
                var holdsLease = true
                defer { if holdsLease { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: context.dataRoot, id: lease) } }
                coordinator.catalogReadiness = originalReadiness
                barrier.release()
                try await driver.wait("batch paused without a provider submission") {
                    barrier.resumed && coordinator.activeBatchID == nil
                        && coordinator.pausedBatches[batchID]?.reason == .hostBusy
                }
                guard let pause = coordinator.pausedBatches[batchID],
                      pause.detail == "Isolated competing native edit" else { throw GateBlocked("The batch did not pause for this actual native lease.") }
                let paused = try GenerationBatchStore.load(id: batchID, home: home)
                let approvedBytes = try GenerationPackageV1.canonicalData(approved.journal)
                let pausedBytes = try GenerationPackageV1.canonicalData(paused.journal)
                guard paused == approved, pausedBytes == approvedBytes, editor.generationLog.spendEvents == spendBefore,
                      MusicvideoGenerationHTTP.requests.isEmpty else { throw GateBlocked("A busy host changed the approved execution or submitted provider work.") }
                let control = "generation-batch.continue." + batchID
                try await driver.wait("busy Continue is disabled") { driver.state(control, in: driver.window) == false }
                let busyState = driver.state(control, in: driver.window)
                try await driver.reveal(control, in: driver.window)
                try driver.capture("batch-paused-host-busy", target: driver.window)
                editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: context.dataRoot, id: lease)
                holdsLease = false
                try await driver.wait("idle Continue is enabled") { driver.state(control, in: driver.window) == true }
                let idleState = driver.state(control, in: driver.window)
                try await Task.sleep(for: .milliseconds(250))
                guard coordinator.activeBatchID == nil, MusicvideoGenerationHTTP.requests.isEmpty,
                      try GenerationBatchStore.load(id: batchID, home: home) == approved else {
                    throw GateBlocked("Releasing the competing lease automatically submitted the batch.")
                }
                try driver.capture("batch-paused-host-idle", target: driver.window)
                try save(approvedBytes, name: "journal-approved.json", driver: driver)
                try save(pausedBytes, name: "journal-paused.json", driver: driver)
                let batchBytes = try GenerationPackageV1.canonicalData(approved.batch)
                try save(batchBytes, name: "batch.json", driver: driver)
                try driver.record("approved batch paused by competing host lease", fields: ["batchID": batchID,
                    "batchSHA256": FileDigest.sha256(of: batchBytes),
                    "journalSHA256": FileDigest.sha256(of: approvedBytes), "pausedSHA256": FileDigest.sha256(of: pausedBytes),
                    "requestCountBeforeContinue": MusicvideoGenerationHTTP.requests.count,
                    "spendEventCountBefore": spendBefore.count, "spendEventCountPaused": editor.generationLog.spendEvents.count,
                    "continueEnabledWhileBusy": busyState ?? true, "continueEnabledWhenIdle": idleState ?? false,
                    "activeBatchBeforeRelease": activeBatchBeforeRelease ?? "", "catalogBarrierResumed": barrier.resumed,
                    "catalogWaiterCount": barrier.waiterCount, "pauseReason": pause.reason.rawValue,
                    "pauseLabel": pause.detail, "idleSettleMilliseconds": 250,
                    "liveProvider": false, "fault": "actual host mutation lease held after real native approval"])
                try await driver.click(control, in: driver.window)
            }, beforeBatchApproval: { batchID in
                armedBatchID = batchID
                coordinator.catalogReadiness = { await barrier.wait() }
            })
        guard let batchID = approvedID else { throw GateBlocked("The real native batch approval was not observed.") }
        let complete = try GenerationBatchStore.load(id: batchID, home: home)
        guard complete.authorityAvailable, complete.journal.executions.count == 1,
              complete.journal.executions[0].state == .complete,
              complete.journal.executions[0].outputAssetIDs == [item.candidate.receipt.generation.assetID] else {
            throw GateBlocked("The explicitly continued request did not produce its exact canonical frame.")
        }
        try save(GenerationPackageV1.canonicalData(complete.journal), name: "journal-complete.json", driver: driver)
        let requests = try MusicvideoGenerationHTTP.requests.enumerated().map { index, request in
            let filename = "request-\(index).bin"
            try save(request.body, name: filename, driver: driver)
            return ["method": request.method, "url": request.url,
                "bodySHA256": FileDigest.sha256(of: request.body), "bodyFile": filename]
        }
        try save(GenerationPackageV1.canonicalData(requests), name: "requests.json", driver: driver)
        try driver.record("approved batch explicitly continued", fields: ["batchID": batchID,
            "candidateID": item.id, "assetID": item.candidate.receipt.generation.assetID,
            "outputSHA256": item.candidate.usage.outputSHA256, "liveProvider": false])
        completed = true
        return item
    }

    private static func save(_ data: Data, name: String, driver: ProductionVisualSourcesDriver) throws {
        let directory = driver.output.appendingPathComponent("batch-busy-evidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
