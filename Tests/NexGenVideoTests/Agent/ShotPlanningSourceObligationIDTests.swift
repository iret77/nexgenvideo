import Testing
import NexGenEngine
@testable import NexGenVideo

struct ShotPlanningSourceObligationIDTests {
    @Test func sourceSelectionDoesNotReuseAnotherObligationsID() {
        let obligations = [obligation("source-footage", kind: .look), obligation("source-footage-2", kind: .prop)]
        #expect(ShotPlanningSourceObligationID.make(preferred: nil, obligations: obligations) == "source-footage-3")
        #expect(ShotPlanningSourceObligationID.make(preferred: "source-footage", obligations: obligations) == "source-footage-3")
    }

    @Test func anExistingRequiredSourceChoiceRetainsItsID() {
        let obligations = [obligation("assigned-source", kind: .sourceFootage), obligation("source-footage", kind: .look)]
        #expect(ShotPlanningSourceObligationID.make(preferred: "assigned-source", obligations: obligations) == "assigned-source")
    }

    private func obligation(_ id: String, kind: ShotPlanningDraftV1.Obligation.Kind) -> ShotPlanningDraftV1.Obligation {
        .init(id: id, kind: kind, subject: "Shot", requirement: "Approved input", required: true)
    }
}
