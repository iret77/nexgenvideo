import BpyRuntimeProtocol
import Darwin
import Foundation

struct BpyMemoryDiagnosticEvidence: Codable, Sendable {
    let mode: BpyBoundaryMode
    let response: BpyMonitorResponse
    let receipt: BpyMemoryCoordinator.PermitReceipt
}

enum BpyPressureDiagnosticScenario: String, CaseIterable, Codable, Sendable {
    case sustainedWarning, criticalSensor, criticalEvent, missingSensor, stalledSensor
}

struct BpyPressureDiagnosticEvidence: Codable, Sendable {
    let scenario: BpyPressureDiagnosticScenario
    let injectedAt: BpyClockReading
    let warningAt: BpyClockReading?
    let execution: BpyMemoryDiagnosticEvidence
}

struct BpyWarningContinuationEvidence: Codable, Sendable {
    let response: BpyServiceResponse
    let receipt: BpyMemoryCoordinator.PermitReceipt
}

struct BpyDualPressureEvidence: Codable, Sendable {
    let event: BpyClockReading
    let executions: [BpyMemoryDiagnosticEvidence]
    let resumption: BpyMemoryDiagnosticEvidence
}

struct BpyHealthyRetryEvidence: Codable, Sendable {
    let interruptedExecution: UUID
    let response: BpyServiceResponse
    let receipt: BpyMemoryCoordinator.PermitReceipt
}

enum BpyMemoryRuntimeAcceptance {
    private static func healthyRetry(after execution: UUID, session: BpyRuntimeSession,
                                     revision: String) throws -> BpyHealthyRetryEvidence {
        let job = UUID()
        let result = try session.runJob(id: job, expectedRevision: revision,
            source: "bpy.context.scene.render.resolution_x = 64\nbpy.context.scene.render.resolution_y = 64")
        defer { result.release(); _ = try? session.cancel(jobID: job) }
        guard result.response.state == .awaitingConfirmation, let receipt = result.lease?.execution,
              receipt.stop == nil, receipt.cleanupComplete, receipt.terminalCommit != nil,
              receipt.releases.map(\.child) == [.worker, .verifier],
              receipt.identity.job == job, session.confirmedRevision == revision else {
            throw BpyRuntimeError.invalidOutput("The runtime did not complete a healthy job after the controlled stop.")
        }
        return .init(interruptedExecution: execution, response: result.response, receipt: receipt)
    }

    static func unavailableSensor(output: URL, serviceName: String) throws -> [String: String] {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else { throw SpatialSceneError.changed }
        let coordinator = BpyMemoryCoordinator()
        let session = BpyRuntimeSession(documentID: "unavailable-sensor-" + UUID().uuidString,
            serviceName: serviceName, memoryCoordinator: coordinator)
        defer { _ = session.close() }
        _ = try session.ready()
        let revision = "unavailable-sensor-checkpoint"
        let baseline = try session.runJob(id: UUID(), expectedRevision: nil,
            source: "bpy.data.objects.new('SENSOR_CHECKPOINT', None)")
        defer { baseline.release() }
        guard baseline.response.state == .awaitingConfirmation, let job = baseline.response.jobID else { throw SpatialSceneError.changed }
        _ = try session.confirm(jobID: job, revision: revision)
        baseline.release()
        let execution = try session.nativePressureDiagnostic(.missingSensor)
        let receipt = execution.execution.receipt
        guard receipt.stop == .monitorUnavailable, receipt.cleanupComplete,
              receipt.samples.contains(where: { $0.source == "selftest-sensor" && $0.error == 2 && $0.pressure == nil }),
              session.confirmedRevision == revision else { throw SpatialSceneError.changed }
        let before = try coordinator.selftestReleaseCount()
        let attempt = UUID()
        let failure: BpyAdmissionFailure
        do {
            let unexpected = try session.runJob(id: attempt, expectedRevision: revision, source: "pass")
            unexpected.release()
            throw SpatialSceneError.invalid("A permanently unavailable sensor admitted another worker.")
        } catch let error as BpyAdmissionFailure { failure = error }
        let after = try coordinator.selftestReleaseCount()
        guard failure == .sensorUnavailable, before == after, session.confirmedRevision == revision else { throw SpatialSceneError.changed }
        struct Evidence: Encodable {
            let execution: BpyPressureDiagnosticEvidence
            let failure: BpyAdmissionFailure
            let retryJob: UUID
            let releasesBeforeRetry: UInt64
            let releasesAfterRetry: UInt64
            let confirmedRevisionBefore: String
            let confirmedRevisionAfter: String
        }
        let bytes = try JSONEncoder().encode(Evidence(execution: execution, failure: failure, retryJob: attempt,
            releasesBeforeRetry: before, releasesAfterRetry: after,
            confirmedRevisionBefore: revision, confirmedRevisionAfter: session.confirmedRevision ?? ""))
        let name = "native-unavailable-sensor.json"
        try bytes.write(to: output.appendingPathComponent(name), options: .atomic)
        guard session.close() else { throw BpyRuntimeError.invalidOutput("The unavailable-sensor test did not release its storage.") }
        return ["file": name, "sha256": SpatialSceneStore.digest(bytes)]
    }

    static func run(output: URL, session: BpyRuntimeSession, counterpart: BpyRuntimeSession, expectedRevision: String) throws -> [String: Any] {
        let modes: [BpyBoundaryMode] = [.diagnosticFootprint, .diagnosticFootprintAfterExec, .diagnosticPythonFootprint, .diagnosticVirtualMapping]
        var evidence: [BpyMemoryDiagnosticEvidence] = []
        var retries: [BpyHealthyRetryEvidence] = []
        for mode in modes {
            let value = try session.nativeMemoryDiagnostic(mode)
            let response = value.response
            guard value.receipt.policy == "system-pressure-v1", response.status == .gone,
                  response.outputComplete, response.supervisor == nil, response.worker == nil,
                  response.descendants.isEmpty, value.receipt.firstRelease != nil,
                  value.receipt.authorizationSamples.contains(where: {
                      $0.source == "sysctl" && $0.pressure == 1 && $0.error == nil
                          && $0.clock.awake <= (value.receipt.firstRelease ?? -1)
                          && (value.receipt.firstRelease ?? -1) - $0.clock.awake <= BpyMemoryState.freshness
                  }) else {
                throw BpyRuntimeError.invalidOutput("The memory probe has no live normal adapter or cleanup evidence.")
            }
            if mode == .diagnosticVirtualMapping {
                guard response.stage == .virtualMappingSucceeded, response.exitStatus == 0,
                      response.diagnosticMapping?.bytes == 8 * 1_024 * 1_024 * 1_024,
                      response.diagnosticMapping?.protection == 0, response.diagnosticMapping?.deallocated == true,
                      response.stopReason == nil, value.receipt.stop == nil else {
                    throw BpyRuntimeError.invalidOutput("The untouched virtual mapping did not complete.")
                }
            } else {
                guard let baseline = response.diagnosticBaseline, let observed = response.diagnosticObserved,
                      baseline.pid == observed.pid, baseline.start == observed.start,
                      baseline.footprint <= UInt64.max - 256 * 1_024 * 1_024,
                      response.diagnosticThresholdBytes == 128 * 1_024 * 1_024,
                      response.diagnosticSafetyBytes == baseline.footprint + 256 * 1_024 * 1_024,
                      observed.footprint >= baseline.footprint + 128 * 1_024 * 1_024,
                      observed.footprint < baseline.footprint + 256 * 1_024 * 1_024,
                      !response.diagnosticChunks.isEmpty, response.diagnosticChunks.count < 64,
                      response.diagnosticChunks == (1...response.diagnosticChunks.count).map({ UInt64($0) * 4 * 1_024 * 1_024 }),
                      response.stage == (mode == .diagnosticFootprintAfterExec ? .diagnosticExecReady : .diagnosticReady),
                      response.stopReason == "diagnosticMemory", value.receipt.stop == .diagnosticMemory,
                      response.ended.contains(where: { $0.pid == observed.pid && $0.start == observed.start }),
                      value.receipt.cleanupComplete else {
                    throw BpyRuntimeError.invalidOutput("The controlled footprint stop has no native observation.")
                }
            }
            guard session.confirmedRevision == expectedRevision else { throw SpatialSceneError.changed }
            evidence.append(value)
            if value.receipt.stop != nil {
                retries.append(try healthyRetry(after: value.response.execution, session: session, revision: expectedRevision))
            }
        }
        var bindings: [BpySourceBindingCase] = []
        for target in ["source.py", "job.json"] {
            let value = try session.nativeSourceBindingDiagnostic(target: target, expectedRevision: expectedRevision)
            guard value.originalSHA256 != value.replacementSHA256, value.originalInode != value.replacementInode,
                  value.receipt.cleanupComplete, let first = value.receipt.firstRelease,
                  first >= value.mutatedAt.awake, value.authorizedAt.awake >= value.mutatedAt.awake,
                  value.gateBefore.execution == value.ended.execution, value.gateAfter.execution == value.ended.execution,
                  value.gateBefore.permit == value.receipt.identity.id, value.gateAfter.permit == value.receipt.identity.id,
                  value.gateBefore.process == value.gateAfter.process,
                  value.gateBefore.clock.awake <= value.mutatedAt.awake, value.gateAfter.clock.awake >= value.mutatedAt.awake,
                  value.gateAfter.clock.awake <= first,
                  value.originalSHA256 == (target == "source.py" ? value.gateBefore.sourceSHA256 : value.gateBefore.configurationSHA256),
                  value.ended.outputComplete, value.ended.ended.contains(where: { $0.pid == value.gateBefore.process.pid && $0.start == value.gateBefore.process.start }),
                  value.ended.status == .detached, value.ended.supervisor == nil, value.ended.worker == nil,
                  value.ended.descendants.isEmpty else { throw SpatialSceneError.changed }
            if target == "source.py" {
                guard value.response.state == .failed, value.ended.exitStatus == 70,
                      value.receipt.releases.map(\.child) == [.worker], value.response.outputs.isEmpty,
                      value.response.stdout?.contains("invalid host bootstrap descriptor") == true,
                      value.response.stdout?.contains("BOUND_SOURCE_RAN") != true,
                      value.response.stdout?.contains("UNAPPROVED_SOURCE_EXECUTED") != true else { throw SpatialSceneError.changed }
            } else {
                guard value.response.state == .awaitingConfirmation, value.ended.exitStatus == 0,
                      value.receipt.releases.map(\.child) == [.worker, .verifier], value.receipt.terminalCommit != nil,
                      value.response.stdout?.contains("BOUND_SOURCE_RAN") == true else { throw SpatialSceneError.changed }
            }
            let retry = try healthyRetry(after: value.ended.execution, session: session, revision: expectedRevision)
            bindings.append(.init(mutation: value, retry: retry))
        }
        let bindingBytes = try JSONEncoder().encode(bindings)
        try bindingBytes.write(to: output.appendingPathComponent("native-source-binding.json"), options: .atomic)
        let bytes = try JSONEncoder().encode(evidence)
        let filename = "native-memory-policy.json"
        try bytes.write(to: output.appendingPathComponent(filename), options: .atomic)
        let continuation = try session.nativeWarningContinuation(expectedRevision: expectedRevision)
        guard continuation.response.state == .awaitingConfirmation, continuation.receipt.stop == nil,
              continuation.receipt.terminalCommit != nil,
              continuation.receipt.releases.map(\.child) == [.worker, .verifier],
              let verifier = continuation.receipt.releases.last,
              continuation.receipt.samples.contains(where: {
                  $0.source == "selftest-sensor" && $0.pressure == 2 && $0.clock.awake <= verifier.clock.awake
                      && verifier.clock.awake - $0.clock.awake <= BpyMemoryState.freshness
              }) else { throw BpyRuntimeError.invalidOutput("The warning probe did not complete its real verifier.") }
        var pressure: [BpyPressureDiagnosticEvidence] = []
        for scenario in BpyPressureDiagnosticScenario.allCases where scenario != .missingSensor {
            let value = try session.nativePressureDiagnostic(scenario)
            let result = value.execution.response, receipt = value.execution.receipt
            guard result.status == .gone, result.outputComplete, result.supervisor == nil, result.worker == nil,
                  result.descendants.isEmpty, let baseline = result.diagnosticBaseline,
                  receipt.cleanupComplete, let cleanup = receipt.cleanupStarted, let finished = receipt.cleanupFinishedAt,
                  result.ended.contains(where: { $0.pid == baseline.pid && $0.start == baseline.start }),
                  finished >= cleanup, finished <= cleanup + BpyMemoryState.cleanupBudget else {
                throw BpyRuntimeError.invalidOutput("The synthetic pressure probe did not prove native cleanup.")
            }
            switch scenario {
            case .sustainedWarning:
                guard let warning = value.warningAt, receipt.stop == .diagnosticMemory,
                      cleanup - warning.awake >= 1 else { throw SpatialSceneError.changed }
            case .criticalSensor, .criticalEvent:
                let source = scenario == .criticalSensor ? "selftest-sensor" : "selftest-event"
                guard let observed = receipt.samples.first(where: { $0.source == source && ($0.pressure ?? 0) & 4 != 0 }),
                      let delivered = result.stopDeliveredAt,
                      receipt.stop == .pressure, cleanup >= observed.clock.awake,
                      cleanup - observed.clock.awake <= BpyMemoryState.freshness,
                      delivered >= observed.clock.awake, delivered - observed.clock.awake <= BpyMemoryState.freshness else {
                    throw SpatialSceneError.changed
                }
            case .missingSensor:
                throw SpatialSceneError.changed
            case .stalledSensor:
                guard receipt.stop == .monitorUnresponsive,
                      cleanup >= value.injectedAt.awake,
                      cleanup - value.injectedAt.awake <= BpyMemoryState.observationBudget + BpyMemoryState.freshness else {
                    throw SpatialSceneError.changed
                }
            }
            guard session.confirmedRevision == expectedRevision else { throw SpatialSceneError.changed }
            pressure.append(value)
            retries.append(try healthyRetry(after: result.execution, session: session, revision: expectedRevision))
        }
        let otherRevision = counterpart.confirmedRevision
        let dual = try session.nativeCriticalBoth(with: counterpart)
        guard Set(dual.executions.map { $0.receipt.identity.owner }).count == 2,
              session.confirmedRevision == expectedRevision, counterpart.confirmedRevision == otherRevision else { throw SpatialSceneError.changed }
        for execution in dual.executions {
            guard execution.receipt.stop == .pressure, execution.receipt.cleanupComplete,
                  let began = execution.receipt.cleanupStarted, let finished = execution.receipt.cleanupFinishedAt,
                  let delivered = execution.response.stopDeliveredAt, let baseline = execution.response.diagnosticBaseline,
                  began >= dual.event.awake, delivered >= began, delivered - dual.event.awake <= BpyMemoryState.freshness,
                  finished >= began, finished - began <= BpyMemoryState.cleanupBudget,
                  execution.response.status == .gone, execution.response.outputComplete,
                  execution.response.ended.contains(where: { $0.pid == baseline.pid && $0.start == baseline.start }) else {
                throw BpyRuntimeError.invalidOutput("Critical pressure did not stop both owned children within the original bounds.")
            }
        }
        let normal = (dual.executions.flatMap { $0.receipt.samples } + dual.resumption.receipt.samples)
            .filter { $0.source == "selftest-sensor" && $0.clock.awake > dual.event.awake }
            .sorted { $0.clock.awake < $1.clock.awake }
        guard let since = normal.first?.clock.awake, let grant = dual.resumption.receipt.grantedAt,
              normal.allSatisfy({ $0.pressure == 1 && $0.error == nil }), grant - since >= 1,
              dual.executions.allSatisfy({ ($0.receipt.cleanupFinishedAt ?? .infinity) <= grant }),
              dual.resumption.receipt.stop == nil, dual.resumption.response.exitStatus == 0 else { throw SpatialSceneError.changed }
        guard let otherRevision else { throw SpatialSceneError.changed }
        for execution in dual.executions {
            let isFirst = execution.response.transport == dual.resumption.response.transport
            retries.append(try healthyRetry(after: execution.response.execution,
                session: isFirst ? session : counterpart, revision: isFirst ? expectedRevision : otherRevision))
        }
        struct Synthetic: Encodable {
            let warningContinuation: BpyWarningContinuationEvidence
            let pressure: [BpyPressureDiagnosticEvidence]
            let dualCritical: BpyDualPressureEvidence
            let healthyRetries: [BpyHealthyRetryEvidence]
        }
        let synthetic = try JSONEncoder().encode(Synthetic(warningContinuation: continuation, pressure: pressure,
            dualCritical: dual, healthyRetries: retries))
        try synthetic.write(to: output.appendingPathComponent("native-synthetic-pressure.json"), options: .atomic)
        let stdout = try session.nativeMemoryDiagnostic(.diagnosticStdoutBurst)
        guard stdout.response.exitStatus == 0, stdout.response.stage == .stdoutBurstComplete,
              stdout.response.outputComplete, stdout.response.stopReason == nil, stdout.receipt.stop == nil, stdout.receipt.cleanupComplete,
              let capture = stdout.response.diagnosticStdout, capture.burst.bytes == 1_048_576,
              capture.burst.flags & O_NONBLOCK == 0, capture.capturedBytes == 1_048_576,
              capture.capturedSHA256 == SpatialSceneStore.digest(Data(repeating: 0x52, count: 1_048_576)),
              capture.childReadyReceived.awake >= capture.childReadyWritten.awake,
              capture.childReadyReceived.awake - capture.childReadyWritten.awake <= 0.1,
              capture.resumed.awake - capture.paused.awake >= 0.25,
              capture.burst.started.awake >= capture.paused.awake, capture.burst.finished.awake >= capture.resumed.awake else {
            throw BpyRuntimeError.invalidOutput("The native stdout burst did not survive the paused host drain.")
        }
        let stdoutEvidence = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stdout))
        let roleLock = try BpyRoleLockAcceptance.run(holding: session, launching: counterpart, expectedRevision: otherRevision)
        let roleEvidence = try JSONSerialization.jsonObject(with: JSONEncoder().encode(roleLock))
        let media = try BpyMediaCancellationAcceptance.run(session: session)
        return ["schema": "nexgenvideo/bpy-memory-policy-evidence/3", "policy": "system-pressure-v1",
            "mediaCancellation": media,
            "stdoutBurst": stdoutEvidence,
            "roleLock": roleEvidence,
            "hostProcessIdentifier": ProcessInfo.processInfo.processIdentifier,
            "nativeEvidenceFile": filename, "nativeEvidenceSHA256": SpatialSceneStore.digest(bytes),
            "sourceBindingEvidenceFile": "native-source-binding.json", "sourceBindingEvidenceSHA256": SpatialSceneStore.digest(bindingBytes),
            "syntheticEvidenceFile": "native-synthetic-pressure.json", "syntheticEvidenceSHA256": SpatialSceneStore.digest(synthetic),
            "maximumRequestedBytesPerProbe": 256 * 1_024 * 1_024, "touchedChunkBytes": 4 * 1_024 * 1_024,
            "diagnosticThresholdDeltaBytes": 128 * 1_024 * 1_024, "diagnosticSafetyDeltaBytes": 256 * 1_024 * 1_024,
            "untouchedVirtualBytes": 8 * 1_024 * 1_024 * 1_024, "untouchedVirtualProtection": "PROT_NONE",
            "genuinePressureTransitionsProven": false]
    }
}
