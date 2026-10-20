import Testing
@testable import NexGenVideo

@Suite("Value-bound generation seed changes")
struct GenerationPanelSeedChangesTests {
    @Test func restoresEachChangedFieldExactlyOnceRegardlessOfDeliveryOrder() {
        var changes = GenerationPanelSeedChanges(before: [.type: "Video", .audioModel: "old", .aspect: "16:9"],
            after: [.type: "Audio", .audioModel: "new", .aspect: "16:9"])
        let consumedAudioModel = changes.consume(.audioModel, value: "new")
        #expect(consumedAudioModel)
        let consumedType = changes.consume(.type, value: "Audio")
        #expect(consumedType)
        let consumedDuplicateType = changes.consume(.type, value: "Audio")
        #expect(!consumedDuplicateType)
        let consumedUnchangedAspect = changes.consume(.aspect, value: "16:9")
        #expect(!consumedUnchangedAspect)
    }

    @Test func userChangeConsumesAnUnmatchedTokenAndCannotSuppressARoundTrip() {
        var changes = GenerationPanelSeedChanges(before: [.videoModel: "0"], after: [.videoModel: "1"])
        let consumedUserChange = changes.consume(.videoModel, value: "2")
        #expect(!consumedUserChange)
        let consumedRoundTrip = changes.consume(.videoModel, value: "1")
        #expect(!consumedRoundTrip)
    }

    @Test func aNewSeedReplacesTheOldPendingChanges() {
        var changes = GenerationPanelSeedChanges(before: [.imageModel: "0"], after: [.imageModel: "1"])
        changes = .init(before: [.imageModel: "1"], after: [.imageModel: "2"])
        let consumedStaleDelivery = changes.consume(.imageModel, value: "1", currentValue: "2")
        #expect(consumedStaleDelivery)
        let consumedCurrentDelivery = changes.consume(.imageModel, value: "2", currentValue: "2")
        #expect(consumedCurrentDelivery)
        let consumedDuplicateDelivery = changes.consume(.imageModel, value: "2", currentValue: "2")
        #expect(!consumedDuplicateDelivery)
    }
}
