import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Managed bpy runtime contract")
struct BpyRuntimeContractTests {
    @Test func storagePairsRejectEachIndependentIdentityRoleAndCapacityMismatch() throws {
        let limits = BpyRuntimeLimits(), id = UUID(), workerID = UUID(), dataID = UUID()
        let dataCapacity = try #require(limits.dataStorageBytes)
        let worker = BpyStorageLease(id: workerID, mountPath: "/Fixture/worker", device: 11,
            capacityBytes: limits.physicalStorageBytes, bookmark: Data(), role: .worker, pairID: id)
        let data = BpyStorageLease(id: dataID, mountPath: "/Fixture/data", device: 12,
            capacityBytes: dataCapacity, bookmark: Data(), role: .data, pairID: id)
        let pair = BpyStoragePair(id: id, worker: worker, data: data)
        #expect(pair.isValid(limits: limits))
        let baseline = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(pair)) as? [String: Any])
        let mutations: [(String, String?, String, Any)] = [
            ("schema", nil, "schema", "unknown"),
            ("worker-role", "worker", "role", "data"), ("data-role", "data", "role", "worker"),
            ("missing-worker-role", "worker", "role", NSNull()), ("missing-data-role", "data", "role", NSNull()),
            ("foreign-worker-pair", "worker", "pairID", UUID().uuidString), ("foreign-data-pair", "data", "pairID", UUID().uuidString),
            ("missing-worker-pair", "worker", "pairID", NSNull()), ("missing-data-pair", "data", "pairID", NSNull()),
            ("same-lease", "data", "id", workerID.uuidString), ("same-device", "data", "device", worker.device),
            ("same-mount", "data", "mountPath", worker.mountPath),
            ("zero-worker", "worker", "capacityBytes", 0), ("oversized-worker", "worker", "capacityBytes", limits.physicalStorageBytes + 1),
            ("zero-data", "data", "capacityBytes", 0), ("oversized-data", "data", "capacityBytes", dataCapacity + 1)
        ]
        for (name, role, field, value) in mutations {
            var changed = baseline
            if let role {
                var lease = try #require(changed[role] as? [String: Any])
                lease[field] = value; changed[role] = lease
            } else { changed[field] = value }
            let candidate = try JSONDecoder().decode(BpyStoragePair.self, from: JSONSerialization.data(withJSONObject: changed))
            #expect(!candidate.isValid(limits: limits), "Accepted \(name)")
        }
    }

    @Test func crashedStorageRequiresBootChangeDespitePIDReuse() throws {
        let boot = UUID()
        let operation = BpyStorageOperation(id: UUID(), bootSessionID: boot, pid: 22, start: 200,
                                           completed: false, ownerPID: 11, ownerStart: 100)
        #expect(throws: BpyStorageRecoveryError.restartRequired) {
            try BpyRuntimeVolume.requireStopped(operation, currentBoot: boot, processStart: { _ in nil })
        }
        #expect(throws: BpyStorageRecoveryError.pending) {
            try BpyRuntimeVolume.requireStopped(operation, currentBoot: boot, processStart: { $0 == 22 ? 200 : nil })
        }
        try BpyRuntimeVolume.requireStopped(operation, currentBoot: UUID(), processStart: { $0 == 22 ? 200 : 100 })
    }

    @Test func unstartedStorageIntentRequiresOwnerExitOrExplicitAbandonment() throws {
        let boot = UUID()
        let intent = BpyStorageOperation(id: UUID(), bootSessionID: boot, pid: 0, start: 0,
                                        completed: false, ownerPID: 11, ownerStart: 100)
        #expect(throws: BpyStorageRecoveryError.pending) {
            try BpyRuntimeVolume.requireStopped(intent, currentBoot: boot, processStart: { _ in 100 })
        }
        try BpyRuntimeVolume.requireStopped(intent, currentBoot: boot, processStart: { _ in nil })
        try BpyRuntimeVolume.requireStopped(intent, currentBoot: boot, processStart: { _ in 101 })
        let abandoned = BpyStorageOperation(id: intent.id, bootSessionID: boot, pid: 0, start: 0,
                                           completed: true, ownerPID: 11, ownerStart: 100)
        try BpyRuntimeVolume.requireStopped(abandoned, currentBoot: boot, processStart: { _ in 100 })
    }

    @Test func reservedStorageQuitNeedsEndedOwnershipAndProvenRestartRecovery() {
        #expect(BpyRuntimeSession.permitsReservedStorageQuit(closed: true, closing: false,
            cleanupComplete: false, requiresRestart: true, serviceReleased: true))
        #expect(!BpyRuntimeSession.permitsReservedStorageQuit(closed: true, closing: false,
            cleanupComplete: true, requiresRestart: true, serviceReleased: true))
        #expect(!BpyRuntimeSession.permitsReservedStorageQuit(closed: true, closing: false,
            cleanupComplete: false, requiresRestart: true, serviceReleased: false))
        #expect(!BpyRuntimeSession.permitsReservedStorageQuit(closed: true, closing: false,
            cleanupComplete: false, requiresRestart: false, serviceReleased: true))
        #expect(!BpyRuntimeSession.permitsReservedStorageQuit(closed: false, closing: true,
            cleanupComplete: false, requiresRestart: true, serviceReleased: true))
    }

    @Test func workerSlotsHaveIndependentSandboxIdentities() {
        #expect(bpyRuntimeServiceNames.count == 2)
        #expect(Set(bpyRuntimeServiceNames).count == 2)
    }

    @Test func defaultLimitsAreBounded() {
        let limits = BpyRuntimeLimits()
        #expect(limits.isValid)
        #expect(limits.timeoutSeconds == 120)
        #expect(limits.outputBytes <= 512 * 1_024 * 1_024)
        #expect(limits.diskBytes >= limits.outputBytes)
        #expect(limits.renderPixels <= limits.renderWidth * limits.renderHeight)
    }

    @Test func invalidLimitsFailClosed() {
        var limits = BpyRuntimeLimits()
        limits.timeoutSeconds = 0
        #expect(!limits.isValid)
        limits = BpyRuntimeLimits()
        limits.diskBytes = limits.outputBytes - 1
        #expect(!limits.isValid)
    }

    @Test func missingOrUnknownMemoryPolicyFailsDecoding() throws {
        let bytes = try JSONEncoder().encode(BpyRuntimeLimits())
        var value = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        value.removeValue(forKey: "memoryPolicy")
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(BpyRuntimeLimits.self, from: JSONSerialization.data(withJSONObject: value))
        }
        value["memoryPolicy"] = "unsupported-policy"
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(BpyRuntimeLimits.self, from: JSONSerialization.data(withJSONObject: value))
        }
    }

    @Test func dataImageDoesNotEnlargeTheWorkerFilesystem() throws {
        let defaults = BpyRuntimeLimits()
        #expect(defaults.physicalStorageBytes == 2 * 1_024 * 1_024 * 1_024)
        #expect(defaults.dataStorageBytes == 5 * 1_024 * 1_024 * 1_024)
        var minimumSlack = defaults
        minimumSlack.inputBytes = 448 * 1_024 * 1_024
        let minimumCapacity = try #require(minimumSlack.dataStorageBytes)
        let fourGiB: UInt64 = 4 * 1_024 * 1_024 * 1_024
        #expect(minimumCapacity == fourGiB)
        #expect(minimumSlack.physicalStorageBytes == defaults.physicalStorageBytes)
        minimumSlack.inputBytes = 496 * 1_024 * 1_024
        #expect(minimumSlack.dataStorageBytes == 5 * 1_024 * 1_024 * 1_024)
        var largeWorker = defaults
        largeWorker.diskBytes = 8 * 1_024 * 1_024 * 1_024
        #expect(largeWorker.isValid)
        #expect(largeWorker.physicalStorageBytes == 8 * 1_024 * 1_024 * 1_024)
        #expect(largeWorker.dataStorageBytes == 5 * 1_024 * 1_024 * 1_024)
    }

    @Test func inputCopyOnlyAcceptsSingleSafeName() throws {
        let root = URL(fileURLWithPath: "/tmp/approved", isDirectory: true)
        _ = try BpyApprovedInputCopy(approvedDirectory: root, filename: "scene.blend")
        #expect(throws: BpyRuntimeError.self) {
            _ = try BpyApprovedInputCopy(approvedDirectory: root, filename: "../scene.blend")
        }
        #expect(throws: BpyRuntimeError.self) {
            _ = try BpyApprovedInputCopy(approvedDirectory: root, filename: "folder/scene.blend")
        }
    }

    @Test func diagnosticPathsPinOneAbsoluteFileNamespace() throws {
        try BpyRuntimeSession.requireDiagnosticPaths([])
        try BpyRuntimeSession.requireDiagnosticPaths(["/tmp/positive-control", "/private/tmp/other-control"])
        for paths in [["relative/control"], [""], ["/tmp/control\0suffix"],
                      ["/tmp/control", "/tmp/control"], [String(repeating: "/", count: 4_097)],
                      (0..<9).map { "/tmp/control-\($0)" }] {
            #expect(throws: BpyRuntimeError.self) {
                try BpyRuntimeSession.requireDiagnosticPaths(paths)
            }
        }
    }

    @Test func terminalStateSeparatesCandidateFromConfirmation() {
        #expect(!BpyRuntimeJobState.awaitingConfirmation.isTerminal)
        #expect(BpyRuntimeJobState.confirmed.isTerminal)
        #expect(BpyRuntimeJobState.crashed.isTerminal)
        #expect(BpyRuntimeJobState.timedOut.isTerminal)
        #expect(BpyRuntimeJobState.resourceLimited.isTerminal)
    }

    @Test func requestsRoundTripWithoutPaths() throws {
        let request = BpyRunJobRequest(
            sessionID: UUID(),
            jobID: UUID(),
            expectedRevision: "r1",
            source: "import bpy",
            inputNames: ["approved.blend"],
            timeoutSeconds: 10,
            fingerprint: String(repeating: "a", count: 64),
            diagnosticDeniedPaths: ["/denied/fixture"],
            diagnosticAutoexecPositiveControl: true
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(BpyRunJobRequest.self, from: data)
        #expect(decoded == request)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("projectURL"))
    }

    @Test func serviceResponseRoundTripsTrustedProcessLease() throws {
        let jobID = UUID()
        let response = BpyServiceResponse(
            ok: true,
            jobID: jobID,
            state: .running,
            jobFingerprint: String(repeating: "b", count: 64),
            activeProcessIdentifier: 321,
            activeProcessStartAbsoluteTime: 654,
            activeProcessExecutable: "/Applications/NexGenVideo.app/Contents/Frameworks/Python.framework/Versions/3.13/bin/python3"
        )
        let decoded = try JSONDecoder().decode(
            BpyServiceResponse.self,
            from: JSONEncoder().encode(response)
        )
        #expect(decoded == response)
        #expect(decoded.jobID == jobID)
    }
}
