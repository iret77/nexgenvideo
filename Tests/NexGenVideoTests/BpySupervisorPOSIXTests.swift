import BpySupervisorPOSIX
import Darwin
import XCTest

final class BpySupervisorPOSIXTests: XCTestCase {
    func testResourceInfinityUsesDarwinSentinelWithoutChangingLimits() {
        var before = rlimit()
        var after = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_AS, &before), 0)
        XCTAssertEqual(ngv_bpy_rlim_infinity(), UInt64(Int64.max))
        XCTAssertNotEqual(ngv_bpy_rlim_infinity(), UInt64.max)
        XCTAssertEqual(getrlimit(RLIMIT_AS, &after), 0)
        XCTAssertEqual(before.rlim_cur, after.rlim_cur)
        XCTAssertEqual(before.rlim_max, after.rlim_max)
    }

    func testForkProbeReapsUnsandboxedChild() {
        var forkErrno: Int32 = -1
        let probeError = ngv_bpy_probe_fork(&forkErrno)
        XCTAssertEqual(probeError, 0)
        XCTAssertEqual(forkErrno, 0)
    }
}
