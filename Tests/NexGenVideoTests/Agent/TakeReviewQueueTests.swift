import Testing
import Foundation
@testable import NexGenVideo

@Suite("Take review navigation")
struct TakeReviewQueueTests {
    private let shots: [TakeReviewQueue.Shot] = [
        .init(id: "first", number: 1, takeID: "take-first"),
        .init(id: "second", number: 3, takeID: nil),
        .init(id: "last", number: 5, takeID: "take-last")]

    @Test func followsPlanOrderAndRetainsMissingOutput() {
        let queue = TakeReviewQueue(shots: shots, selectedShotIDs: ["first"])
        #expect(queue.next(after: "first") == shots[1])
        #expect(queue.next(after: "first")?.takeID == nil)
    }

    @Test func skipsSelectedShotsAndWrapsToEarlierOpenWork() {
        #expect(TakeReviewQueue(shots: shots, selectedShotIDs: ["first", "second"]).next(after: "first") == shots[2])
        #expect(TakeReviewQueue(shots: shots, selectedShotIDs: ["last"]).next(after: "last") == shots[0])
    }

    @Test func doesNotAdvanceAnUnselectedOrUnknownShot() {
        let queue = TakeReviewQueue(shots: shots, selectedShotIDs: ["first"])
        #expect(queue.next(after: "second") == nil)
        #expect(queue.next(after: "old-plan") == nil)
    }

    @Test func completedPlanHasNoNextShot() {
        let queue = TakeReviewQueue(shots: shots, selectedShotIDs: Set(shots.map(\.id)))
        #expect(queue.next(after: "first") == nil)
        #expect(TakeReviewQueue(shots: [], selectedShotIDs: []).next(after: "first") == nil)
    }

    @Test func selectedShotsDoNotValidateAnotherCandidate() throws {
        var checked: [String] = []
        let queue = try TakeReviewQueue.assemble(shots: shots, isSelected: { $0 == "first" }, candidate: {
            checked.append($0)
            return $0 == "last" ? "current-last" : nil
        })
        #expect(checked == ["second", "last"])
        #expect(queue.selectedShotIDs == ["first"])
        #expect(queue.shots[2].takeID == "current-last")
        #expect(queue.next(after: "first")?.takeID == nil)
    }

    @Test func cancellationStopsBeforeAnotherShotIsRead() async {
        let shots = shots
        let canceled = await Task {
            var visited: [String] = []
            do {
                _ = try TakeReviewQueue.assemble(shots: shots, isSelected: {
                    visited.append($0)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                }, candidate: { _ in Issue.record("Canceled queue read a candidate"); return nil })
                return false
            } catch is CancellationError { return visited == ["first"] }
            catch { return false }
        }.value
        #expect(canceled)
    }
}
