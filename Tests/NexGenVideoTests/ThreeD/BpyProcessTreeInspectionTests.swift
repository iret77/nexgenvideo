import BpyRuntimeProtocol
import Testing

@Suite("Bpy PID-count enumeration")
struct BpyProcessTreeInspectionTests {
    @Test func singleChildAndGrandchildAreCountsRatherThanBytes() throws {
        let actual = try BpyProcessTreeInspection.descendants(root: 10, start: 100, identity: { UInt64($0 * 10) }) { parent, _ in
            let children: [Int32] = parent == 10 ? [20] : parent == 20 ? [30] : []
            return .init(count: children.count, error: 0, pids: children)
        }
        #expect(actual == [20, 30])
    }

    @Test func fullBuffersGrowAndCannotSilentlyTruncate() throws {
        var capacities: [Int] = []
        let actual = try BpyProcessTreeInspection.descendants(root: 10, start: 100, maximum: 256, identity: { UInt64($0 * 10) }) { parent, capacity in
            guard parent == 10 else { return .init(count: 0, error: 0, pids: []) }
            capacities.append(capacity)
            let children = Array(Int32(20)...Int32(89)).prefix(capacity)
            return .init(count: children.count, error: 0, pids: Array(children))
        }
        #expect(capacities == [64, 128])
        #expect(actual.count == 70)
        #expect(throws: BpyProcessTreeInspection.Failure.capacity) {
            try BpyProcessTreeInspection.descendants(root: 10, start: 100, maximum: 64, identity: { UInt64($0 * 10) }) { _, capacity in
                .init(count: capacity, error: 0, pids: Array(repeating: 20, count: capacity))
            }
        }
    }

    @Test func zeroOnLibprocErrorFailsClosed() throws {
        #expect(throws: BpyProcessTreeInspection.Failure.query(1)) {
            try BpyProcessTreeInspection.descendants(root: 10, start: 100, identity: { UInt64($0 * 10) }) { _, _ in
                .init(count: 0, error: 1, pids: [])
            }
        }
        #expect(throws: BpyProcessTreeInspection.Failure.query(5)) {
            try BpyProcessTreeInspection.descendants(root: 10, start: 100, identity: { UInt64($0 * 10) }) { _, _ in
                .init(count: -1, error: 5, pids: [])
            }
        }
    }

    @Test func changedParentIdentityDoesNotInspectReusedPID() throws {
        var calls = 0
        let actual = try BpyProcessTreeInspection.descendants(root: 10, start: 100, identity: { _ in 101 }) { _, _ in
            calls += 1; return .init(count: 0, error: 0, pids: [])
        }
        #expect(calls == 0)
        #expect(actual.isEmpty)
    }
}
