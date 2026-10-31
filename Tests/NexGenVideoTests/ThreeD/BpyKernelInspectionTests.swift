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
}
