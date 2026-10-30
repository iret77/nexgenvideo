import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

struct BpyLaunchFailureTests {
    @Test func observationFailuresRetainTheirPrimaryCause() {
        let stages: [BpyLaunchStage] = [.sandboxUnavailable, .sandboxRejected, .denialCheckFailed, .execFailed, .invalidLaunch, .identityCaptureFailed]
        for stage in stages {
            #expect(BpyHostLauncher.observationStop(error: POSIXError(.EIO), stage: stage) == .launchFailed)
        }
        #expect(BpyHostLauncher.observationStop(error: POSIXError(.EPERM), stage: .childReady) == .ownershipViolation)
        #expect(BpyHostLauncher.observationStop(error: POSIXError(.EBUSY), stage: .childReady) == .orphanedWorker)
        #expect(BpyHostLauncher.observationStop(error: POSIXError(.EIO), stage: .childReady) == .observationFailed)
        #expect(BpyHostLauncher.observationStop(error: POSIXError(.EPIPE), stage: .childReady) == .launchFailed)
        #expect(BpyHostLauncher.observationStop(error: POSIXError(.EOVERFLOW), stage: .childReady) == .processCount)
    }
}
