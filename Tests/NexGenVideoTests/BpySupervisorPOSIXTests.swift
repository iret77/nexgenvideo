import BpySupervisorPOSIX
import XCTest

final class BpySupervisorPOSIXTests: XCTestCase {
    func testForkProbeReapsUnsandboxedChild() {
        var forkErrno: Int32 = -1
        let probeError = ngv_bpy_probe_fork(&forkErrno)
        XCTAssertEqual(probeError, 0)
        XCTAssertEqual(forkErrno, 0)
    }
}
