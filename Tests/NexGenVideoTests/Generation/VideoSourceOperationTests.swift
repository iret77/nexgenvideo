import Foundation
import Testing
@testable import NexGenVideo

@Suite("Video source operation compatibility")
struct VideoSourceOperationTests {
    @Test("legacy source-video proofs retain their exact canonical bytes")
    func legacyPolicyBytes() throws {
        let bytes = Data(#"{"framesCountTowardImageReferenceLimit":false,"framesCountTowardTotalReferenceLimit":false,"requiresSourceVideo":true}"#.utf8)
        let policy = try JSONDecoder().decode(ProviderProductionInputPolicyV1.self, from: bytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(policy) == bytes)
        #expect(policy.preservesSourceComposition)
        let forward = ProviderProductionInputPolicyV1(requiresSourceVideo: true,
            framesCountTowardImageReferenceLimit: false, framesCountTowardTotalReferenceLimit: false,
            sourceOperation: .extendForward)
        #expect(forward.requiresSourceVideo)
        #expect(!forward.preservesSourceComposition)
        #expect(try encoder.encode(forward) != bytes)
        let backward = ProviderProductionInputPolicyV1(requiresSourceVideo: true,
            framesCountTowardImageReferenceLimit: false, framesCountTowardTotalReferenceLimit: false,
            sourceOperation: .extendBackward)
        #expect(try encoder.encode(forward) != encoder.encode(backward))
    }
}
