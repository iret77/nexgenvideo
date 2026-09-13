import Foundation
import NexGenEngine

extension HostOperationOutcome {
    init(phase: String, validity: PhaseApprovalValidity) {
        let state: State
        if validity.historicallyApproved {
            state = validity.isCurrent ? .approvedCurrent : .staleAfterLineageChange
        } else if validity.isCurrent {
            state = .validatedAwaitingReview
        } else {
            state = validity.lineageRecorded ? .persistedButStructurallyInvalid : .rejectedBeforeWrite
        }
        self.init(state: state, phase: phase, diagnostic: validity.diagnostic)
    }

    var dictionary: [String: Any] {
        ["schema": schema, "state": state.rawValue, "phase": phase,
         "diagnostic": diagnostic.map { $0 as Any } ?? NSNull()]
    }
}
