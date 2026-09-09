import Foundation

public struct StoryCausalityDraftV1: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case narrative, hybrid, performance, abstract, documentary, other }
    public enum Relation: String, Codable, Sendable { case therefore, but }
    public enum ReviewQuestion: String, Codable, Sendable, CaseIterable {
        case thereforeBut, visibleCause, coincidenceDirection, endingTurn, plantPayoff, deletionRipple, sceneTurn, removalRewiring
    }
    public enum Verdict: String, Codable, Sendable { case satisfied, concern, notApplicable }

    public struct Beat: Codable, Sendable, Equatable {
        public let id: String
        public let sceneID: String
        public let excerpt: String
        public let elementIDs: [String]
        public let causalException: String?
    }
    public struct Edge: Codable, Sendable, Equatable {
        public let cause: String
        public let consequence: String
        public let relation: Relation
        public let reason: String
    }
    public struct Element: Codable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let introductionBeatID: String
        public let payoffBeatIDs: [String]
        public let noPayoffReason: String?
    }
    public struct StateChange: Codable, Sendable, Equatable {
        public let elementID: String
        public let beatID: String
        public let causeBeatID: String
        public let before: String
        public let after: String
        public let excerpt: String
    }
    public struct Decision: Codable, Sendable, Equatable {
        public let id: String
        public let affectedBeatIDs: [String]
        public let question: String
        public let alternatives: [String]
    }
    public struct Check: Codable, Sendable, Equatable {
        public let question: ReviewQuestion
        public let verdict: Verdict
        public let explanation: String
    }
    public struct ChangeReview: Codable, Sendable, Equatable {
        public let reviewer: String
        public let upstreamCause: String
        public let downstreamConsequence: String
        public let affectedBeatIDs: [String]
        public let checks: [Check]
    }

    public let mode: Mode
    public let applicationReason: String
    public let beats: [Beat]
    public let chronology: [String]
    public let edges: [Edge]
    public let elements: [Element]
    public let stateChanges: [StateChange]
    public let unresolvedDecisions: [Decision]
    public let changeReview: ChangeReview

    public func validate(body: String, previous: Self? = nil, approval: Bool = false) throws {
        func require(_ condition: Bool, _ reason: String) throws {
            guard condition else { throw GateBlocked("Story causality: " + reason) }
        }
        func concrete(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func unique(_ values: [String]) -> Bool { values.allSatisfy(concrete) && Set(values).count == values.count }
        func identifier(_ value: String) -> Bool {
            !value.isEmpty && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0) }
        }
        let beatIDs = Set(beats.map(\.id))
        let elementIDs = Set(elements.map(\.id))
        try require(concrete(applicationReason) && !beats.isEmpty && unique(beats.map(\.id)), "declare the concept mode and uniquely identified beats.")
        try require((beats.flatMap { [$0.id, $0.sceneID] } + elements.map(\.id) + unresolvedDecisions.map(\.id)).allSatisfy(identifier), "stable IDs may contain letters, numbers, hyphens, dots and underscores only.")
        try require(unique(chronology) && Set(chronology) == beatIDs, "chronology must cover every beat exactly once, independently of presentation order.")
        let indices = Dictionary(uniqueKeysWithValues: chronology.enumerated().map { ($0.element, $0.offset) })
        let byID = Dictionary(uniqueKeysWithValues: beats.map { ($0.id, $0) })
        for beat in beats {
            try require(concrete(beat.sceneID) && concrete(beat.excerpt) && body.contains(beat.excerpt), "beat \(beat.id) must cite exact treatment text and a scene.")
            try require(unique(beat.elementIDs) && Set(beat.elementIDs).isSubset(of: elementIDs), "beat \(beat.id) references an unknown or duplicate element.")
            if let exception = beat.causalException { try require(concrete(exception), "causal exceptions need a reason.") }
        }
        try require(unique(edges.map { $0.cause + ":" + $0.consequence }), "causal edges must be unique.")
        for edge in edges {
            try require(beatIDs.contains(edge.cause) && beatIDs.contains(edge.consequence) && concrete(edge.reason), "every causal edge needs known beats and an explanation.")
            try require(indices[edge.cause]! < indices[edge.consequence]!, "causes must precede consequences in story chronology; causal cycles are invalid.")
        }
        if mode == .narrative || mode == .hybrid {
            for id in chronology {
                guard byID[id]?.causalException == nil else { continue }
                if id != chronology.first { try require(edges.contains { $0.consequence == id }, "beat \(id) needs an upstream cause or an explicit exception.") }
                if id != chronology.last { try require(edges.contains { $0.cause == id }, "beat \(id) needs a downstream consequence or an explicit exception.") }
            }
        }
        try require(unique(elements.map(\.id)), "elements must have unique IDs.")
        for element in elements {
            try require(concrete(element.label) && beatIDs.contains(element.introductionBeatID), "elements need a label and a known introduction beat.")
            try require(byID[element.introductionBeatID]?.elementIDs.contains(element.id) == true, "the introduction beat must actually reference \(element.id).")
            try require(unique(element.payoffBeatIDs) && Set(element.payoffBeatIDs).isSubset(of: beatIDs), "payoffs must reference known, unique beats.")
            try require(!element.payoffBeatIDs.isEmpty || element.noPayoffReason.map(concrete) == true, "element \(element.id) needs a payoff or an explicit non-payoff role.")
            for payoff in element.payoffBeatIDs {
                try require(indices[element.introductionBeatID]! <= indices[payoff]! && byID[payoff]?.elementIDs.contains(element.id) == true, "payoff \(payoff) must use its previously introduced element.")
            }
        }
        try require(unique(stateChanges.map { $0.elementID + ":" + $0.beatID }), "an element has one declared state change per beat.")
        for change in stateChanges {
            try require(elementIDs.contains(change.elementID) && beatIDs.contains(change.beatID) && beatIDs.contains(change.causeBeatID), "state changes need known elements, beats and visible causes.")
            try require(indices[change.causeBeatID]! <= indices[change.beatID]!, "a state change cannot precede its cause.")
            try require(concrete(change.before) && concrete(change.after) && change.before != change.after && concrete(change.excerpt)
                && byID[change.beatID]?.excerpt.contains(change.excerpt) == true, "state changes must cite their exact treatment beat, with distinct before/after states.")
            try require(byID[change.beatID]?.elementIDs.contains(change.elementID) == true, "the changed element must be present in its beat.")
        }
        for element in elements {
            let changes = stateChanges.filter { $0.elementID == element.id }.sorted { indices[$0.beatID]! < indices[$1.beatID]! }
            for pair in zip(changes, changes.dropFirst()) {
                try require(pair.0.after == pair.1.before, "state ladder for \(element.id) has an unexplained discontinuity.")
            }
        }
        try require(unique(unresolvedDecisions.map(\.id)), "decision IDs must be unique.")
        for decision in unresolvedDecisions {
            try require(concrete(decision.question) && !decision.affectedBeatIDs.isEmpty && unique(decision.affectedBeatIDs)
                && Set(decision.affectedBeatIDs).isSubset(of: beatIDs) && decision.alternatives.count >= 2 && unique(decision.alternatives), "unresolved canon needs concrete alternatives and affected beats.")
        }
        let review = changeReview
        try require(concrete(review.reviewer) && concrete(review.upstreamCause) && concrete(review.downstreamConsequence), "attribute the change review and name its upstream cause and downstream consequence.")
        try require(review.checks.count == ReviewQuestion.allCases.count && Set(review.checks.map(\.question)) == Set(ReviewQuestion.allCases)
            && review.checks.allSatisfy({ concrete($0.explanation) }), "answer all eight causal change questions separately.")
        let known = beatIDs.union(previous.map { Set($0.beats.map(\.id)) } ?? [])
        try require(unique(review.affectedBeatIDs) && Set(review.affectedBeatIDs).isSubset(of: known), "change review references unknown or duplicate affected beats.")
        try require(affectedBeats(comparedWith: previous).isSubset(of: Set(review.affectedBeatIDs)), "the change review must include every changed, removed or dependent beat.")
        if approval {
            try require(unresolvedDecisions.isEmpty, "resolve the listed canon alternatives in a new proposal before approving Treatment.")
        }
    }

    public func affectedBeats(comparedWith prior: Self?) -> Set<String> {
        guard let prior else { return Set(beats.map(\.id)) }
        let old = Dictionary(prior.beats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(beats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var affected = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
        if mode != prior.mode || applicationReason != prior.applicationReason || chronology != prior.chronology {
            affected.formUnion(old.keys)
            affected.formUnion(new.keys)
        }
        for decision in prior.unresolvedDecisions + unresolvedDecisions where prior.unresolvedDecisions.contains(decision) != unresolvedDecisions.contains(decision) {
            affected.formUnion(decision.affectedBeatIDs)
        }
        for edge in prior.edges where !edges.contains(edge) { affected.formUnion([edge.cause, edge.consequence]) }
        for edge in edges where !prior.edges.contains(edge) { affected.formUnion([edge.cause, edge.consequence]) }
        for element in prior.elements + elements {
            if prior.elements.first(where: { $0.id == element.id }) != elements.first(where: { $0.id == element.id }) {
                affected.formUnion([element.introductionBeatID] + element.payoffBeatIDs)
            }
        }
        for change in prior.stateChanges + stateChanges where prior.stateChanges.contains(change) != stateChanges.contains(change) {
            affected.formUnion([change.beatID, change.causeBeatID])
        }
        var expanded = true
        while expanded {
            let count = affected.count
            for edge in prior.edges + edges where affected.contains(edge.cause) { affected.insert(edge.consequence) }
            expanded = affected.count != count
        }
        return affected
    }
}

public struct StoryCausalityPlanV1: Codable, Sendable, Equatable {
    public static let relativePath = "treatment/causality.json"
    public let schema: String
    public let project: String
    public let treatmentVersion: Int
    public let treatmentSHA256: String
    public let briefSHA256: String
    public let draft: StoryCausalityDraftV1
    public let affectedBeatIDs: [String]

    public var reviewMarkdown: String {
        var lines = ["### Story causality", "Concept: \(draft.mode.rawValue). \(draft.applicationReason)",
                     "Changed or dependent beats: " + affectedBeatIDs.joined(separator: ", ")]
        for beat in draft.beats { lines.append("- **\(beat.id)** · \(beat.sceneID): \(beat.excerpt)") }
        for edge in draft.edges { lines.append("- \(edge.cause) → \(edge.consequence) (\(edge.relation.rawValue)): \(edge.reason)") }
        for change in draft.stateChanges { lines.append("- \(change.elementID) at \(change.beatID): \(change.before) → \(change.after); caused by \(change.causeBeatID).") }
        lines += ["", "Review by \(draft.changeReview.reviewer):", draft.changeReview.upstreamCause, draft.changeReview.downstreamConsequence]
        for check in draft.changeReview.checks { lines.append("- \(check.question.rawValue): \(check.verdict.rawValue). \(check.explanation)") }
        if !draft.unresolvedDecisions.isEmpty {
            lines += ["", "**Decisions required before approval:**"]
            for decision in draft.unresolvedDecisions { lines.append("- \(decision.question) Options: " + decision.alternatives.joined(separator: "; ")) }
        }
        return lines.joined(separator: "\n")
    }
}
