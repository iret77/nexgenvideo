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

    private func descriptorFixture(fileports: Bool = true, failureStage: Int? = nil,
                                   error: Int32 = ESRCH, failureValue: Int32 = 0, identityLost: Bool = false,
                                   record: (String) -> Void = { _ in }) throws -> [BpyObservedVnode] {
        let owned = BpyObservedProcess(pid: 41, start: 100, parent: 40, executable: "/bin/sh", footprint: 4_096)
        var failed = false
        return try BpyKernelInspection.descriptors(owned, fileports: fileports, matching: { value in
            #expect(value == owned)
            return !(failed && identityLost)
        }, list: { flavor, buffer, size in
            #expect(flavor == (fileports ? 14 : 1))
            let stage = buffer == nil ? 0 : 1
            record(stage == 0 ? "capacity" : "list")
            if failureStage == stage { failed = true; return (Int(failureValue), error) }
            guard let buffer else { #expect(size == 0); return (16, 0) }
            #expect(size > 16)
            for offset in [0, 8] {
                buffer.storeBytes(of: Int32(7 + offset / 8), toByteOffset: offset, as: Int32.self)
                buffer.storeBytes(of: UInt32(1), toByteOffset: offset + 4, as: UInt32.self)
            }
            return (16, 0)
        }, vnode: { descriptor, buffer in
            record("vnode:\(descriptor)")
            if failureStage == 2, descriptor == 8 { failed = true; return (failureValue, error) }
            buffer.storeBytes(of: UInt32(2), toByteOffset: 24, as: UInt32.self)
            buffer.storeBytes(of: UInt16(S_IFREG), toByteOffset: 28, as: UInt16.self)
            buffer.storeBytes(of: UInt16(1), toByteOffset: 30, as: UInt16.self)
            buffer.storeBytes(of: UInt64(descriptor), toByteOffset: 32, as: UInt64.self)
            buffer.storeBytes(of: Int64(1_234), toByteOffset: 112, as: Int64.self)
            buffer.storeBytes(of: Int64(8), toByteOffset: 120, as: Int64.self)
            for (index, byte) in (Array("/owned/\(descriptor)".utf8) + [0]).enumerated() {
                buffer.storeBytes(of: byte, toByteOffset: 176 + index, as: UInt8.self)
            }
            return (1_200, 0)
        })
    }

    @Test func fileportTaskTransitionsDiscardPartialSnapshotsAndResample() throws {
        for stage in 0...2 {
            var published = false
            var queries: [String] = []
            do {
                _ = try descriptorFixture(failureStage: stage, record: { queries.append($0) })
                published = true
            } catch is BpyLaunchDeferral {
            } catch {
                Issue.record("A live fileport task transition became a permanent failure: \(error)")
            }
            #expect(!published)
            if stage == 2 { #expect(queries.contains("vnode:7") && queries.contains("vnode:8")) }
            let complete = try descriptorFixture()
            #expect(complete.count == 2 && complete.map(\.inode) == [7, 8])
            #expect(complete.map(\.path) == ["/owned/7", "/owned/8"])
            #expect(complete.allSatisfy { $0.logical == 1_234 && $0.blocks == 8 && $0.links == 1 })
        }
        #expect(try descriptorFixture(failureStage: 0, error: 0).isEmpty)
        #expect(try descriptorFixture(failureStage: 1, error: 0).isEmpty)
    }

    @Test func fileportDeferralRequiresZeroESRCHAndTheSameOwnedBirth() throws {
        for fileports in [false, true] {
            for stage in 0...2 {
                for code: Int32 in [ESRCH, EPERM, EACCES, EIO] {
                    do {
                        _ = try descriptorFixture(fileports: fileports, failureStage: stage, error: code)
                        Issue.record("An incomplete kernel inspection was accepted")
                    } catch is BpyLaunchDeferral {
                        #expect(fileports && code == ESRCH)
                    } catch let error as POSIXError {
                        #expect(!(fileports && code == ESRCH) && error.code.rawValue == code)
                    }
                    let gone = try descriptorFixture(fileports: fileports, failureStage: stage, error: code, identityLost: true)
                    #expect(gone.isEmpty)
                }
                do {
                    _ = try descriptorFixture(fileports: fileports, failureStage: stage, failureValue: -1)
                    Issue.record("A malformed nonzero inspection result was accepted")
                } catch let error as POSIXError {
                    #expect(error.code == .ESRCH)
                }
            }
        }
    }
}
