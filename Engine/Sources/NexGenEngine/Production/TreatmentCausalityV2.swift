import Foundation

public struct TreatmentCausalityV2: Codable, Sendable, Equatable {
    public static let schemaVersion = "story-causality/v2"
    public static let currentPath = "treatment/causality-current.v2.json"

    public struct Beat: Codable, Sendable, Equatable {
        public let id: String
        public let sceneID: String
        public let excerpt: String
        public let elementIDs: [String]
        public let causalException: String?

        public init(id: String, sceneID: String, excerpt: String, elementIDs: [String], causalException: String? = nil) {
            self.id = id
            self.sceneID = sceneID
            self.excerpt = excerpt
            self.elementIDs = elementIDs
            self.causalException = causalException
        }
    }

    public struct CausalEdge: Codable, Sendable, Equatable {
        public let cause: String
        public let consequence: String
        public let relation: StoryCausalityDraftV1.Relation
        public let reason: String

        public init(cause: String, consequence: String, relation: StoryCausalityDraftV1.Relation, reason: String) {
            self.cause = cause
            self.consequence = consequence
            self.relation = relation
            self.reason = reason
        }
    }

    public struct TemporalRelation: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case before, parallel, unknown }
        public let firstBeatID: String
        public let secondBeatID: String
        public let kind: Kind
        public let reason: String

        public init(firstBeatID: String, secondBeatID: String, kind: Kind, reason: String) {
            self.firstBeatID = firstBeatID
            self.secondBeatID = secondBeatID
            self.kind = kind
            self.reason = reason
        }
    }

    public let schema: String
    public let header: PlanningArtifactHeaderV1
    public let treatmentReference: CanonicalArtifactReferenceV1
    public let briefReference: CanonicalArtifactReferenceV1
    public let storySourceReference: CanonicalArtifactReferenceV1
    public let mode: StoryCausalityDraftV1.Mode
    public let applicationReason: String
    public let beats: [Beat]
    public let edges: [CausalEdge]
    public let temporalRelations: [TemporalRelation]
    public let elements: [StoryCausalityDraftV1.Element]
    public let stateChanges: [StoryCausalityDraftV1.StateChange]
    public let unresolvedDecisions: [StoryCausalityDraftV1.Decision]
    public let changeReview: StoryCausalityDraftV1.ChangeReview

    public init(schema: String = schemaVersion, header: PlanningArtifactHeaderV1,
                treatmentReference: CanonicalArtifactReferenceV1, briefReference: CanonicalArtifactReferenceV1,
                storySourceReference: CanonicalArtifactReferenceV1, mode: StoryCausalityDraftV1.Mode,
                applicationReason: String, beats: [Beat], edges: [CausalEdge], temporalRelations: [TemporalRelation],
                elements: [StoryCausalityDraftV1.Element], stateChanges: [StoryCausalityDraftV1.StateChange],
                unresolvedDecisions: [StoryCausalityDraftV1.Decision], changeReview: StoryCausalityDraftV1.ChangeReview) {
        self.schema = schema
        self.header = header
        self.treatmentReference = treatmentReference
        self.briefReference = briefReference
        self.storySourceReference = storySourceReference
        self.mode = mode
        self.applicationReason = applicationReason
        self.beats = beats
        self.edges = edges
        self.temporalRelations = temporalRelations
        self.elements = elements
        self.stateChanges = stateChanges
        self.unresolvedDecisions = unresolvedDecisions
        self.changeReview = changeReview
    }

    public static func versionPath(_ revision: Int) -> String { "treatment/causality/v\(revision).v2.json" }

    public func validate(treatmentBody: String, previous: Self? = nil, approval: Bool = false) throws {
        try PlanningValidation.require(schema == Self.schemaVersion, "treatmentCausality.schema")
        try header.validate()
        try PlanningValidation.text(applicationReason, "treatmentCausality.applicationReason")
        for reference in [treatmentReference, briefReference, storySourceReference] {
            try PlanningValidation.reference(reference)
            try PlanningValidation.require(header.inputs.contains { $0.path == reference.path && $0.sha256 == reference.sha256 },
                                           "treatmentCausality.inputBinding")
        }
        try PlanningValidation.require(treatmentReference.path == PipelineLayout.treatmentVersionFile(header.revision)
            && briefReference.path == PipelineLayout.briefFile && storySourceReference.path == StorySourceV1.currentPath,
                                       "treatmentCausality.inputPaths")
        if let previous {
            try PlanningValidation.require(previous.header.projectID == header.projectID
                && previous.header.revision + 1 == header.revision, "treatmentCausality.priorRevision")
        } else {
            try PlanningValidation.require(header.revision == 1, "treatmentCausality.priorRevisionMissing")
        }
        try PlanningValidation.require(!beats.isEmpty, "treatmentCausality.beats")
        try PlanningValidation.unique(beats.map(\.id), "treatmentCausality.beatIDs")
        try PlanningValidation.unique(elements.map(\.id), "treatmentCausality.elementIDs")
        let known = Set(beats.map(\.id))
        let elementIDs = Set(elements.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: beats.map { ($0.id, $0) })
        for beat in beats {
            try PlanningValidation.identifier(beat.id, "treatmentCausality.beat.id")
            try PlanningValidation.identifier(beat.sceneID, "treatmentCausality.beat.sceneID")
            try PlanningValidation.text(beat.excerpt, "treatmentCausality.beat.excerpt")
            try PlanningValidation.require(treatmentBody.contains(beat.excerpt), "treatmentCausality.beat.exactExcerpt")
            try PlanningValidation.unique(beat.elementIDs, "treatmentCausality.beat.elementIDs")
            try PlanningValidation.require(Set(beat.elementIDs).isSubset(of: elementIDs), "treatmentCausality.beat.elements")
            if let exception = beat.causalException { try PlanningValidation.text(exception, "treatmentCausality.beat.exception") }
        }
        try PlanningValidation.unique(edges.map { $0.cause + ":" + $0.consequence }, "treatmentCausality.edges")
        var before: [String: Set<String>] = [:]
        for edge in edges {
            try PlanningValidation.require(known.contains(edge.cause) && known.contains(edge.consequence)
                && edge.cause != edge.consequence, "treatmentCausality.edge.beats")
            try PlanningValidation.text(edge.reason, "treatmentCausality.edge.reason")
            before[edge.cause, default: []].insert(edge.consequence)
        }
        var pairs = Set<String>()
        for relation in temporalRelations {
            try PlanningValidation.require(known.contains(relation.firstBeatID) && known.contains(relation.secondBeatID)
                && relation.firstBeatID != relation.secondBeatID, "treatmentCausality.time.beats")
            try PlanningValidation.text(relation.reason, "treatmentCausality.time.reason")
            let key = [relation.firstBeatID, relation.secondBeatID].sorted().joined(separator: ":")
            try PlanningValidation.require(pairs.insert(key).inserted, "treatmentCausality.time.duplicatePair")
            if relation.kind == .before { before[relation.firstBeatID, default: []].insert(relation.secondBeatID) }
        }
        for id in known { try PlanningValidation.require(!reachable(id, from: id, graph: before), "treatmentCausality.time.cycle") }
        for relation in temporalRelations where relation.kind != .before {
            try PlanningValidation.require(!reachable(relation.secondBeatID, from: relation.firstBeatID, graph: before)
                && !reachable(relation.firstBeatID, from: relation.secondBeatID, graph: before), "treatmentCausality.time.conflict")
        }
        for element in elements {
            try PlanningValidation.text(element.label, "treatmentCausality.element.label")
            try PlanningValidation.require(byID[element.introductionBeatID]?.elementIDs.contains(element.id) == true,
                                           "treatmentCausality.element.introduction")
            try PlanningValidation.unique(element.payoffBeatIDs, "treatmentCausality.element.payoffs")
            try PlanningValidation.require(!element.payoffBeatIDs.isEmpty || element.noPayoffReason?.isEmpty == false,
                                           "treatmentCausality.element.payoffReason")
            for payoff in element.payoffBeatIDs {
                try PlanningValidation.require(byID[payoff]?.elementIDs.contains(element.id) == true, "treatmentCausality.element.payoff")
                if approval && payoff != element.introductionBeatID {
                    try PlanningValidation.require(reachable(payoff, from: element.introductionBeatID, graph: before),
                                                   "treatmentCausality.element.payoffOrder")
                }
            }
        }
        try PlanningValidation.unique(stateChanges.map { $0.elementID + ":" + $0.beatID }, "treatmentCausality.stateChanges")
        for change in stateChanges {
            try PlanningValidation.require(elementIDs.contains(change.elementID) && known.contains(change.beatID)
                && known.contains(change.causeBeatID) && byID[change.beatID]?.elementIDs.contains(change.elementID) == true,
                                           "treatmentCausality.state.beats")
            try PlanningValidation.text(change.before, "treatmentCausality.state.before")
            try PlanningValidation.text(change.after, "treatmentCausality.state.after")
            try PlanningValidation.text(change.excerpt, "treatmentCausality.state.excerpt")
            try PlanningValidation.require(change.before != change.after && byID[change.beatID]?.excerpt.contains(change.excerpt) == true,
                                           "treatmentCausality.state.excerpt")
            if approval && change.causeBeatID != change.beatID {
                try PlanningValidation.require(reachable(change.beatID, from: change.causeBeatID, graph: before),
                                               "treatmentCausality.state.causeOrder")
            }
        }
        if approval {
            try PlanningValidation.require(unresolvedDecisions.isEmpty, "treatmentCausality.unresolvedDecisions")
            for element in elements {
                let changes = stateChanges.filter { $0.elementID == element.id }
                for first in changes {
                    for second in changes where first.beatID != second.beatID {
                        let follows = reachable(second.beatID, from: first.beatID, graph: before)
                        let precedes = reachable(first.beatID, from: second.beatID, graph: before)
                        try PlanningValidation.require(follows || precedes, "treatmentCausality.state.unknownOrder")
                        let intervening = changes.contains { other in
                            other.beatID != first.beatID && other.beatID != second.beatID
                                && reachable(other.beatID, from: first.beatID, graph: before)
                                && reachable(second.beatID, from: other.beatID, graph: before)
                        }
                        if follows && !intervening {
                            try PlanningValidation.require(first.after == second.before, "treatmentCausality.state.discontinuity")
                        }
                    }
                }
            }
        }
        try PlanningValidation.unique(unresolvedDecisions.map(\.id), "treatmentCausality.decisionIDs")
        for decision in unresolvedDecisions {
            try PlanningValidation.text(decision.question, "treatmentCausality.decision.question")
            try PlanningValidation.require(!decision.affectedBeatIDs.isEmpty && Set(decision.affectedBeatIDs).isSubset(of: known)
                && decision.alternatives.count >= 2, "treatmentCausality.decision")
            try PlanningValidation.unique(decision.affectedBeatIDs, "treatmentCausality.decision.beats")
            try PlanningValidation.unique(decision.alternatives, "treatmentCausality.decision.alternatives")
        }
        try PlanningValidation.text(changeReview.reviewer, "treatmentCausality.review.reviewer")
        try PlanningValidation.text(changeReview.upstreamCause, "treatmentCausality.review.upstreamCause")
        try PlanningValidation.text(changeReview.downstreamConsequence, "treatmentCausality.review.downstreamConsequence")
        try PlanningValidation.require(changeReview.checks.count == StoryCausalityDraftV1.ReviewQuestion.allCases.count
            && Set(changeReview.checks.map(\.question)) == Set(StoryCausalityDraftV1.ReviewQuestion.allCases), "treatmentCausality.review.checks")
        for check in changeReview.checks { try PlanningValidation.text(check.explanation, "treatmentCausality.review.explanation") }
        try PlanningValidation.unique(changeReview.affectedBeatIDs, "treatmentCausality.review.affectedBeatIDs")
        let historicalIDs = known.union(previous.map { Set($0.beats.map(\.id)) } ?? [])
        try PlanningValidation.require(Set(changeReview.affectedBeatIDs).isSubset(of: historicalIDs)
            && affectedBeats(comparedWith: previous).isSubset(of: Set(changeReview.affectedBeatIDs)),
                                       "treatmentCausality.review.rippleCoverage")
    }

    public func affectedBeats(comparedWith prior: Self?) -> Set<String> {
        guard let prior else { return Set(beats.map(\.id)) }
        let old = Dictionary(prior.beats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(beats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var affected = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
        if mode != prior.mode || applicationReason != prior.applicationReason {
            affected.formUnion(old.keys)
            affected.formUnion(new.keys)
        }
        for decision in prior.unresolvedDecisions + unresolvedDecisions
        where prior.unresolvedDecisions.contains(decision) != unresolvedDecisions.contains(decision) {
            affected.formUnion(decision.affectedBeatIDs)
        }
        for edge in prior.edges + edges where prior.edges.contains(edge) != edges.contains(edge) {
            affected.formUnion([edge.cause, edge.consequence])
        }
        for relation in prior.temporalRelations + temporalRelations
        where prior.temporalRelations.contains(relation) != temporalRelations.contains(relation) {
            affected.formUnion([relation.firstBeatID, relation.secondBeatID])
        }
        for element in prior.elements + elements
        where prior.elements.first(where: { $0.id == element.id }) != elements.first(where: { $0.id == element.id }) {
            affected.formUnion([element.introductionBeatID] + element.payoffBeatIDs)
        }
        for change in prior.stateChanges + stateChanges
        where prior.stateChanges.contains(change) != stateChanges.contains(change) {
            affected.formUnion([change.beatID, change.causeBeatID])
        }
        var count = -1
        while count != affected.count {
            count = affected.count
            for edge in prior.edges + edges where affected.contains(edge.cause) { affected.insert(edge.consequence) }
        }
        return affected
    }

    private func reachable(_ target: String, from start: String, graph: [String: Set<String>]) -> Bool {
        var pending = Array(graph[start] ?? [])
        var visited = Set<String>()
        while let next = pending.popLast() {
            if next == target { return true }
            if visited.insert(next).inserted { pending.append(contentsOf: graph[next] ?? []) }
        }
        return false
    }
}
