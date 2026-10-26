import Foundation

public enum BpyProcessTreeInspection {
    public struct Listing: Sendable {
        public let count: Int
        public let error: Int32
        public let pids: [Int32]

        public init(count: Int, error: Int32, pids: [Int32]) {
            self.count = count; self.error = error; self.pids = pids
        }
    }

    public enum Failure: Error, Equatable {
        case query(Int32)
        case capacity
        case malformed
    }

    public static func descendants(root: Int32, start: UInt64, maximum: Int = 65_536,
        identity: (Int32) throws -> UInt64?, list: (Int32, Int) -> Listing) throws -> [Int32] {
        guard (2...65_536).contains(maximum) else { throw Failure.capacity }
        var seen: Set<Int32> = [root]
        var pending: [(Int32, UInt64)] = [(root, start)]
        var result: [Int32] = []
        while let (parent, expectedStart) = pending.popLast() {
            guard try identity(parent) == expectedStart else { continue }
            var capacity = min(64, maximum)
            while true {
                let children = list(parent, capacity)
                guard try identity(parent) == expectedStart else { break }
                guard children.count >= 0, children.count != 0 || children.error == 0 else {
                    throw Failure.query(children.error)
                }
                guard children.count <= capacity, children.pids.count >= children.count else { throw Failure.malformed }
                if children.count == capacity {
                    guard capacity < maximum else { throw Failure.capacity }
                    capacity = min(maximum, capacity * 2)
                    continue
                }
                for child in children.pids.prefix(children.count) where child > 1 && !seen.contains(child) {
                    guard let started = try identity(child) else { continue }
                    guard seen.count < maximum else { throw Failure.capacity }
                    seen.insert(child); result.append(child); pending.append((child, started))
                }
                break
            }
        }
        return result
    }
}
