import Foundation
import Testing
@testable import NexGenVideo

@MainActor
struct SpatialSheetCloseTests {
    @Test func closingCancelsTheInFlightReadAndRenderBeforeDismissal() async {
        let reads = BpyOperationCancellation(), read = BpyOperationCancellation()
        read.follow(reads)
        let render = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        var readCancelledAtDismissal: Bool?, renderCancelledAtDismissal: Bool?
        SpatialSheetClose.close(render: render, reads: reads) {
            readCancelledAtDismissal = read.isCancelled
            renderCancelledAtDismissal = render.isCancelled
        }
        #expect(readCancelledAtDismissal == true)
        #expect(renderCancelledAtDismissal == true)
        await render.value
    }

    @Test func closingWithoutARenderStillCancelsEveryFollowingRead() {
        let reads = BpyOperationCancellation(), list = BpyOperationCancellation(), scene = BpyOperationCancellation()
        list.follow(reads); scene.follow(reads)
        var dismissed = 0
        SpatialSheetClose.close(render: nil, reads: reads) { dismissed += 1 }
        #expect(dismissed == 1)
        #expect(list.isCancelled && scene.isCancelled)
    }
}
