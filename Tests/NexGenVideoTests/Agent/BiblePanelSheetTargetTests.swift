import Foundation
import Testing
@testable import NexGenVideo

@MainActor
struct BiblePanelSheetTargetTests {
    @Test func sameLocationIDCannotMoveToAnotherProjectOrOpenSession() throws {
        let home = URL(fileURLWithPath: "/fixture/one"), generation = UUID()
        let context = BiblePanelSheetTarget.Context(home: home, projectID: "one", generation: generation)
        let target = try #require(BiblePanelSheetTarget(locationID: "shared_location", context: context))
        #expect(target.isCurrent(context))
        #expect(target.home == home)
        #expect(target.locationID == "shared_location")
        for changed in [
            BiblePanelSheetTarget.Context(home: URL(fileURLWithPath: "/fixture/two"), projectID: "one", generation: generation),
            .init(home: home, projectID: "two", generation: generation),
            .init(home: home, projectID: "one", generation: UUID()),
            .init(home: nil, projectID: "one", generation: generation),
            .init(home: home, projectID: nil, generation: generation),
            .init(home: home, projectID: "one", generation: nil)
        ] {
            #expect(!target.isCurrent(changed))
        }
    }

    @Test func missingProjectIdentityCannotCreateAnEmptySheetTarget() {
        let home = URL(fileURLWithPath: "/fixture/one"), generation = UUID()
        for context in [
            BiblePanelSheetTarget.Context(home: nil, projectID: "one", generation: generation),
            .init(home: home, projectID: nil, generation: generation),
            .init(home: home, projectID: "", generation: generation),
            .init(home: home, projectID: "one", generation: nil)
        ] {
            #expect(BiblePanelSheetTarget(locationID: "shared_location", context: context) == nil)
        }
        #expect(BiblePanelSheetTarget(locationID: "", context: .init(home: home, projectID: "one", generation: generation)) == nil)
    }
}
