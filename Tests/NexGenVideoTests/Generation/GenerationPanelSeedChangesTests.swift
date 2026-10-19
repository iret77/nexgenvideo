import Testing
@testable import NexGenVideo

@Suite("Value-bound generation seed changes")
struct GenerationPanelSeedChangesTests {
    @Test func restoresEachChangedFieldExactlyOnceRegardlessOfDeliveryOrder() {
        var changes = GenerationPanelSeedChanges(before: [.type: "Video", .audioModel: "old", .aspect: "16:9"],
            after: [.type: "Audio", .audioModel: "new", .aspect: "16:9"])
        #expect(changes.consume(.audioModel, value: "new"))
        #expect(changes.consume(.type, value: "Audio"))
        #expect(!changes.consume(.type, value: "Audio"))
        #expect(!changes.consume(.aspect, value: "16:9"))
    }

    @Test func userChangeConsumesAnUnmatchedTokenAndCannotSuppressARoundTrip() {
        var changes = GenerationPanelSeedChanges(before: [.videoModel: "0"], after: [.videoModel: "1"])
        #expect(!changes.consume(.videoModel, value: "2"))
        #expect(!changes.consume(.videoModel, value: "1"))
    }

    @Test func aNewSeedReplacesTheOldPendingChanges() {
        var changes = GenerationPanelSeedChanges(before: [.imageModel: "0"], after: [.imageModel: "1"])
        changes = .init(before: [.imageModel: "1"], after: [.imageModel: "2"])
        #expect(changes.consume(.imageModel, value: "1", currentValue: "2"))
        #expect(changes.consume(.imageModel, value: "2", currentValue: "2"))
        #expect(!changes.consume(.imageModel, value: "2", currentValue: "2"))
    }
}
