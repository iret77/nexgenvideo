import BpyRuntimeProtocol
import Darwin
import Foundation
import Testing
@testable import NexGenVideo

struct BpyKernelInspectionTests {
    private func identity(start: UInt64 = 100, flags: UInt32 = 0) -> BpyKernelInspection.ProcessIdentity {
        .init(start: start, footprint: 4_096, parent: 40, flags: flags)
    }

    private func process(_ identities: [BpyKernelInspection.ProcessIdentity?], error: Int32 = 0,
                         path: String? = "/bin/sh") throws -> BpyObservedProcess? {
        var index = 0
        return try BpyKernelInspection.process(41, identity: { _ in
            let value = identities[min(index, identities.count - 1)]
            index += 1
            return value
        }, executablePath: { _ in (error == 0 ? 7 : 0, error, path) })
    }

    @Test func stableIdentityAndPendingExitRemainDistinct() throws {
        let live = try #require(try process([identity(flags: 2)]))
        #expect(live.pid == 41 && live.start == 100 && live.parent == 40 && live.footprint == 4_096)
        #expect(live.executable == (try BpyRuntimePath.canonical(URL(fileURLWithPath: "/bin/sh"))))
        var queriedPath = false
        #expect(throws: BpyKernelInspection.ExitPending(pid: 41, start: 100)) {
            try BpyKernelInspection.process(41, identity: { _ in identity(flags: 6) }, executablePath: { _ in
                queriedPath = true
                return (0, ESRCH, nil)
            })
        }
        #expect(!queriedPath)
        #expect(throws: BpyKernelInspection.ExitPending(pid: 41, start: 100)) {
            try process([identity(), identity(flags: 4)])
        }
    }

    @Test func executableLossRequiresTheSameBirthAndExitFlag() throws {
        #expect(throws: BpyKernelInspection.ExitPending(pid: 41, start: 100)) {
            try process([identity(), identity(flags: 4)], error: ESRCH, path: nil)
        }
        #expect(try process([identity(), nil], error: ESRCH, path: nil) == nil)
        #expect(try process([identity(), identity(start: 101, flags: 4)], error: ESRCH, path: nil) == nil)
        #expect(try process([nil], error: ESRCH, path: nil) == nil)
    }

    @Test func liveQueryAndPermissionFailuresAreNeverExitDeferrals() throws {
        for code: Int32 in [ESRCH, EPERM, EACCES, EIO] {
            do {
                _ = try process([identity()], error: code, path: nil)
                Issue.record("Live executable query unexpectedly succeeded")
            } catch let error as POSIXError {
                #expect(error.code.rawValue == code)
            }
        }
        for code: Int32 in [EPERM, EACCES, EIO] {
            do {
                _ = try process([identity(), identity(flags: 4)], error: code, path: nil)
                Issue.record("Executable query failure was hidden by exit state")
            } catch let error as POSIXError {
                #expect(error.code.rawValue == code)
            }
        }
        #expect(throws: POSIXError(.EPERM)) {
            try BpyKernelInspection.process(41, identity: { _ in throw POSIXError(.EPERM) },
                executablePath: { _ in (0, ESRCH, nil) })
        }
    }

    @Test func identityMatchingNeverReportsAnExitingProcessAsGone() throws {
        let observed = BpyObservedProcess(pid: 41, start: 100, parent: 40, executable: "/bin/sh", footprint: 4_096)
        #expect(try BpyKernelInspection.matches(observed, identity: { _ in identity() }))
        #expect(try !BpyKernelInspection.matches(observed, identity: { _ in nil }))
        #expect(try !BpyKernelInspection.matches(observed, identity: { _ in identity(start: 101, flags: 4) }))
        #expect(throws: BpyKernelInspection.ExitPending(pid: 41, start: 100)) {
            try BpyKernelInspection.matches(observed, identity: { _ in identity(flags: 4) })
        }
        #expect(throws: POSIXError(.EPERM)) {
            try BpyKernelInspection.matches(observed, identity: { _ in throw POSIXError(.EPERM) })
        }
    }

    @Test func exitDeferralRequiresOwnedIdentityAndAnUnterminatedHealthyLaunch() {
        let supervisor = BpyObservedProcess(pid: 40, start: 99, parent: 39, executable: "/supervisor", footprint: 1)
        let worker = BpyObservedProcess(pid: 41, start: 100, parent: 40, executable: "/worker", footprint: 1)
        for owned in [supervisor, worker] {
            let pending = BpyKernelInspection.ExitPending(pid: owned.pid, start: owned.start)
            #expect(BpyHostLauncher.shouldDeferExit(pending, supervisor: supervisor, worker: worker,
                terminated: false, stage: .childReady))
            #expect(!BpyHostLauncher.shouldDeferExit(pending, supervisor: supervisor, worker: worker,
                terminated: true, stage: .childReady))
            for stage: BpyLaunchStage in [.sandboxUnavailable, .sandboxRejected, .denialCheckFailed,
                                         .execFailed, .invalidLaunch, .identityCaptureFailed] {
                #expect(!BpyHostLauncher.shouldDeferExit(pending, supervisor: supervisor, worker: worker,
                    terminated: false, stage: stage))
            }
        }
        for pending in [BpyKernelInspection.ExitPending(pid: 41, start: 101), .init(pid: 42, start: 100)] {
            #expect(!BpyHostLauncher.shouldDeferExit(pending, supervisor: supervisor, worker: worker,
                terminated: false, stage: .childReady))
        }
        #expect(!BpyHostLauncher.shouldDeferExit(.init(pid: 41, start: 100), supervisor: supervisor, worker: nil,
            terminated: false, stage: .childReady))
    }

    @Test func terminalExitObservationRequiresTypedOwnedIdentityAndTerminalState() {
        let supervisor = BpyObservedProcess(pid: 40, start: 99, parent: 39, executable: "/supervisor", footprint: 1)
        let worker = BpyObservedProcess(pid: 41, start: 100, parent: 40, executable: "/worker", footprint: 1)
        let owners: [(BpyObservedProcess, BpyRuntimeObservation.TerminalExitRole)] = [(supervisor, .supervisor), (worker, .worker)]
        for (process, role) in owners {
            let pending = BpyKernelInspection.ExitPending(pid: process.pid, start: process.start)
            #expect(BpyHostLauncher.expectedTerminalExitRole(pending, supervisor: supervisor, worker: worker,
                terminated: false, stage: .childReady) == nil)
            #expect(BpyHostLauncher.expectedTerminalExitRole(pending, supervisor: supervisor, worker: worker,
                terminated: true, stage: .childReady) == role)
            for stage: BpyLaunchStage in [.sandboxUnavailable, .sandboxRejected, .denialCheckFailed,
                                         .execFailed, .invalidLaunch, .identityCaptureFailed] {
                #expect(BpyHostLauncher.expectedTerminalExitRole(pending, supervisor: supervisor, worker: worker,
                    terminated: false, stage: stage) == role)
            }
        }
        let failures: [any Error] = [BpyKernelInspection.ExitPending(pid: 41, start: 101),
                                    BpyKernelInspection.ExitPending(pid: 42, start: 100), POSIXError(.EPERM), POSIXError(.EIO)]
        for error in failures {
            #expect(BpyHostLauncher.expectedTerminalExitRole(error, supervisor: supervisor, worker: worker,
                terminated: true, stage: .invalidLaunch) == nil)
        }
        let uncaptured = BpyKernelInspection.ExitPending(pid: worker.pid, start: worker.start)
        #expect(!BpyHostLauncher.shouldDeferExit(uncaptured, supervisor: supervisor, worker: nil,
            terminated: false, stage: .childReady))
        #expect(BpyHostLauncher.expectedTerminalExitRole(uncaptured, supervisor: supervisor, worker: nil,
            terminated: false, stage: .childReady) == nil)
        #expect(BpyHostLauncher.expectedTerminalExitRole(uncaptured, supervisor: supervisor, worker: nil,
            terminated: true, stage: .invalidLaunch) == nil)
    }

    @Test func expectedTerminalExitDiagnosticsUseInspectionGatesAndBoundedSeparateRecords() throws {
        let pending = BpyKernelInspection.ExitPending(pid: 40, start: 99)
        let context = ["execution": UUID().uuidString, "permit": UUID().uuidString,
                       "existingStop": "transportLost", "terminated": "true"]
        for flag in ["NGV_SELFTEST_BPY", "NGV_SELFTEST_BPY_BOUNDARY", "NGV_SELFTEST_BPY_HOST_CRASH"] {
            let observation = BpyRuntimeObservation(environment: ["GITHUB_ACTIONS": "true",
                "NGV_BPY_COMMAND_EVIDENCE": "evidence", flag: "1"])
            for _ in 0..<2 {
                observation.expectedTerminalExit(operation: "observeLaunches", role: .supervisor, pending: pending, context: context)
            }
            observation.inspectionFailure(operation: "observeLaunches", pid: 10, error: POSIXError(.EPERM), context: context)
            let snapshot = try observation.inspectionFailureSnapshot()
            let exits = try #require(snapshot["expectedTerminalExits"] as? [[String: Any]])
            let failures = try #require(snapshot["events"] as? [[String: Any]])
            #expect(snapshot["enabled"] as? Bool == true && snapshot["overflow"] as? Bool == false)
            #expect(exits.count == 1 && failures.count == 1)
            let exit = try #require(exits.first)
            #expect(exit["role"] as? String == "supervisor")
            #expect(exit["pendingPID"] as? Int32 == pending.pid && exit["pendingStart"] as? UInt64 == pending.start)
            #expect(exit["context"] as? [String: String] == context)
            #expect(failures.first?["domain"] as? String == NSPOSIXErrorDomain)
            if flag == "NGV_SELFTEST_BPY" {
                let diagnostic = try observation.diagnosticSnapshot()
                let trace = try #require(diagnostic["trace"] as? [String: Any])
                #expect((trace["activity"] as? [[String: Any]])?.isEmpty == true)
            }
            for index in 1...128 {
                observation.expectedTerminalExit(operation: "observeLaunches", role: .worker,
                    pending: .init(pid: Int32(40 + index), start: UInt64(99 + index)), context: context)
            }
            let full = try observation.inspectionFailureSnapshot()
            #expect(full["overflow"] as? Bool == true)
            #expect((full["expectedTerminalExits"] as? [[String: Any]])?.count == 128)
            #expect((full["events"] as? [[String: Any]])?.count == 1)
        }
        let disabledEnvironments: [[String: String]] = [[:], ["GITHUB_ACTIONS": "true", "NGV_SELFTEST_BPY_BOUNDARY": "1"],
            ["NGV_BPY_COMMAND_EVIDENCE": "evidence", "NGV_SELFTEST_BPY_HOST_CRASH": "1"],
            ["GITHUB_ACTIONS": "true", "NGV_BPY_COMMAND_EVIDENCE": "evidence"]]
        for environment in disabledEnvironments {
            let observation = BpyRuntimeObservation(environment: environment)
            observation.expectedTerminalExit(operation: "observeLaunches", role: .supervisor, pending: pending, context: context)
            observation.inspectionFailure(operation: "observeLaunches", pid: 10, error: POSIXError(.EPERM))
            let snapshot = try observation.inspectionFailureSnapshot()
            #expect(snapshot["enabled"] as? Bool == false)
            #expect((snapshot["expectedTerminalExits"] as? [[String: Any]])?.isEmpty == true)
            #expect((snapshot["events"] as? [[String: Any]])?.isEmpty == true)
        }
    }
}
