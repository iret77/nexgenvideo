import Foundation

public typealias RenderReviewEvidenceVerifier = @Sendable (RenderReviewV1, URL) throws -> Void
public typealias RenderSubmissionEvidenceVerifier = @Sendable (RenderSubmissionBindingV1, URL) throws -> Void

public struct RenderReviewV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "render-review/v1"
    public static let currentPath = "render-review/current.v1.json"

    public struct Finding: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case structuralError, unresolved, semanticConcern, creativeAdvice, information }
        public let id: String
        public let kind: Kind
        public let category: SequenceReviewCategoryV1
        public let shotIDs: [String]
        public let message: String
        public let evidence: [CanonicalArtifactReferenceV1]
        public let acceptance: CanonicalArtifactReferenceV1?
        public let acceptanceReason: String?

        public init(id: String, kind: Kind, category: SequenceReviewCategoryV1, shotIDs: [String], message: String,
                    evidence: [CanonicalArtifactReferenceV1], acceptance: CanonicalArtifactReferenceV1? = nil,
                    acceptanceReason: String? = nil) {
            self.id = id
            self.kind = kind
            self.category = category
            self.shotIDs = shotIDs
            self.message = message
            self.evidence = evidence
            self.acceptance = acceptance
            self.acceptanceReason = acceptanceReason
        }
    }

    public struct PredecessorRecipe: Codable, Sendable, Equatable {
        public enum Strategy: String, Codable, Sendable { case frameContinuation, nativeExtension }
        public let strategy: Strategy
        public let predecessorShotID: String
        public let extensionModeID: String?
        public let permittedOriginalReferences: [CanonicalArtifactReferenceV1]

        public init(strategy: Strategy, predecessorShotID: String, extensionModeID: String? = nil,
                    permittedOriginalReferences: [CanonicalArtifactReferenceV1] = []) {
            self.strategy = strategy
            self.predecessorShotID = predecessorShotID
            self.extensionModeID = extensionModeID
            self.permittedOriginalReferences = permittedOriginalReferences
        }
    }

    public struct ShotReview: Codable, Sendable, Equatable {
        public let shotID: String
        public let evidence: [CanonicalArtifactReferenceV1]
        public let compiledPrompt: CanonicalArtifactReferenceV1?
        public let promptIRSHA256: String?
        public let route: CanonicalArtifactReferenceV1?
        public let conditioning: [CanonicalArtifactReferenceV1]
        public let predecessor: PredecessorRecipe?

        public init(shotID: String, evidence: [CanonicalArtifactReferenceV1], compiledPrompt: CanonicalArtifactReferenceV1? = nil,
                    promptIRSHA256: String? = nil, route: CanonicalArtifactReferenceV1? = nil,
                    conditioning: [CanonicalArtifactReferenceV1] = [], predecessor: PredecessorRecipe? = nil) {
            self.shotID = shotID
            self.evidence = evidence
            self.compiledPrompt = compiledPrompt
            self.promptIRSHA256 = promptIRSHA256
            self.route = route
            self.conditioning = conditioning
            self.predecessor = predecessor
        }
    }

    public let schema: String
    public let header: PlanningArtifactHeaderV1
    public let productionPlan: CanonicalArtifactReferenceV1
    public let reviewer: SequenceReviewerProvenanceV1
    public let reviewEvidence: CanonicalArtifactReferenceV1
    public let shots: [ShotReview]
    public let findings: [Finding]

    public init(schema: String = schemaVersion, header: PlanningArtifactHeaderV1,
                productionPlan: CanonicalArtifactReferenceV1, reviewer: SequenceReviewerProvenanceV1,
                reviewEvidence: CanonicalArtifactReferenceV1, shots: [ShotReview], findings: [Finding]) {
        self.schema = schema
        self.header = header
        self.productionPlan = productionPlan
        self.reviewer = reviewer
        self.reviewEvidence = reviewEvidence
        self.shots = shots
        self.findings = findings
    }

    public static func versionPath(_ revision: Int) -> String { "render-review/v\(revision).v1.json" }

    public var references: [CanonicalArtifactReferenceV1] {
        let reviewerPrompt: [CanonicalArtifactReferenceV1]
        if let path = reviewer.promptPath, let hash = reviewer.promptSHA256 {
            reviewerPrompt = [.init(id: "render-review.model-prompt", role: "core.review-prompt", path: path, sha256: hash)]
        } else { reviewerPrompt = [] }
        return header.inputs + [productionPlan, reviewEvidence] + reviewerPrompt + shots.flatMap {
            $0.evidence + $0.conditioning + [$0.compiledPrompt, $0.route].compactMap { $0 }
                + ($0.predecessor?.permittedOriginalReferences ?? [])
        } + findings.flatMap { $0.evidence + [$0.acceptance].compactMap { $0 } }
    }

    public func requireCurrentEvidence(dataRoot: URL, projection: ProductionPlanProjectionV1,
                                       verifier: RenderReviewEvidenceVerifier? = nil) throws {
        try RenderReviewValidatorV1.validate(self, projection: projection, approval: true)
        guard let verifier else { throw ProductionPlanningError.invalid("renderReview.hostEvidenceVerifier") }
        let planning = try ProductionPlanFilesV1.planningInputs(projection, dataRoot: dataRoot)
        try RenderReviewValidatorV1.validate(self, projection: projection, draft: planning.draft, approval: true)
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(Self.currentPath, dataRoot: dataRoot))
        let archive = try Data(contentsOf: ProjectLocalFile.resolve(Self.versionPath(header.revision), dataRoot: dataRoot))
        try PlanningValidation.require(bytes == archive && JSONDecoder().decode(Self.self, from: bytes) == self,
                                       "renderReview.currentBytes")
        let own = CanonicalArtifactReferenceV1(id: "render-review.current", role: "core.render-review",
            path: Self.currentPath, sha256: FileDigest.sha256(of: bytes))
        let archived = CanonicalArtifactReferenceV1(id: "render-review.version", role: "core.render-review",
            path: Self.versionPath(header.revision), sha256: FileDigest.sha256(of: archive))
        let refs = try ProductionPlanFilesV1.unique(references + planning.references + [own, archived])
        try ProductionPlanFilesV1.require(refs, dataRoot: dataRoot)
        try verifier(self, dataRoot)
        try ProductionPlanFilesV1.require(refs, dataRoot: dataRoot)
    }
}

public struct RenderSubmissionBindingV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "render-submission-binding/v1"

    public struct SelectedPredecessor: Codable, Sendable, Equatable {
        public let shotID: String
        public let takeID: String
        public let selectionReceipt: CanonicalArtifactReferenceV1
        public let outputVideo: CanonicalArtifactReferenceV1
        public let lastFrame: CanonicalArtifactReferenceV1?
        // Source ranges use sourceTimebase independently of the output frame grid.
        public let fullDurationTicks: Int64
        public let selectedStartTicks: Int64
        public let selectedEndTicks: Int64
        public let sourceTimebase: SourceMediaTimebaseV1

        public init(shotID: String, takeID: String, selectionReceipt: CanonicalArtifactReferenceV1,
                    outputVideo: CanonicalArtifactReferenceV1, lastFrame: CanonicalArtifactReferenceV1? = nil,
                    fullDurationTicks: Int64, selectedStartTicks: Int64, selectedEndTicks: Int64,
                    sourceTimebase: SourceMediaTimebaseV1) {
            self.shotID = shotID
            self.takeID = takeID
            self.selectionReceipt = selectionReceipt
            self.outputVideo = outputVideo
            self.lastFrame = lastFrame
            self.fullDurationTicks = fullDurationTicks
            self.selectedStartTicks = selectedStartTicks
            self.selectedEndTicks = selectedEndTicks
            self.sourceTimebase = sourceTimebase
        }
    }

    public let schema: String
    public let projectID: String
    public let requestID: String
    public let shotID: String
    public let review: CanonicalArtifactReferenceV1
    public let compiledPrompt: CanonicalArtifactReferenceV1
    public let route: CanonicalArtifactReferenceV1
    public let promptIRSHA256: String
    public let inputs: [CanonicalArtifactReferenceV1]
    public let predecessor: SelectedPredecessor?

    public init(schema: String = schemaVersion, projectID: String, requestID: String, shotID: String,
                review: CanonicalArtifactReferenceV1, compiledPrompt: CanonicalArtifactReferenceV1,
                route: CanonicalArtifactReferenceV1, promptIRSHA256: String,
                inputs: [CanonicalArtifactReferenceV1], predecessor: SelectedPredecessor? = nil) {
        self.schema = schema
        self.projectID = projectID
        self.requestID = requestID
        self.shotID = shotID
        self.review = review
        self.compiledPrompt = compiledPrompt
        self.route = route
        self.promptIRSHA256 = promptIRSHA256
        self.inputs = inputs
        self.predecessor = predecessor
    }

    public func validate(review reviewed: RenderReviewV1, projection: ProductionPlanProjectionV1) throws {
        try RenderReviewValidatorV1.validate(reviewed, projection: projection, approval: true)
        try PlanningValidation.require(schema == Self.schemaVersion && projectID == reviewed.header.projectID,
                                       "renderSubmission.header")
        try PlanningValidation.text(requestID, "renderSubmission.requestID")
        try PlanningValidation.shotID(shotID)
        try PlanningValidation.reference(review)
        try PlanningValidation.require(review.path == RenderReviewV1.versionPath(reviewed.header.revision), "renderSubmission.reviewPath")
        guard let planned = reviewed.shots.first(where: { $0.shotID == shotID }),
              planned.compiledPrompt == compiledPrompt, planned.route == route, planned.promptIRSHA256 == promptIRSHA256 else {
            throw ProductionPlanningError.stale("renderSubmission.compiledRequest")
        }
        for input in inputs { try PlanningValidation.reference(input) }
        if let recipe = planned.predecessor {
            guard let predecessor, predecessor.shotID == recipe.predecessorShotID else {
                throw ProductionPlanningError.invalid("renderSubmission.predecessor")
            }
            try PlanningValidation.hash(predecessor.takeID, "renderSubmission.takeID")
            try PlanningValidation.reference(predecessor.selectionReceipt)
            try PlanningValidation.reference(predecessor.outputVideo)
            try predecessor.sourceTimebase.validate()
            try PlanningValidation.require(predecessor.fullDurationTicks > 0 && predecessor.selectedStartTicks >= 0
                && predecessor.selectedStartTicks < predecessor.selectedEndTicks
                && predecessor.selectedEndTicks == predecessor.fullDurationTicks, "renderSubmission.predecessorEnd")
            if recipe.strategy == .frameContinuation {
                guard let frame = predecessor.lastFrame else { throw ProductionPlanningError.invalid("renderSubmission.lastFrame") }
                try PlanningValidation.reference(frame)
                try PlanningValidation.require(inputs == [frame], "renderSubmission.soleContinuationInput")
            } else {
                try PlanningValidation.require(predecessor.lastFrame == nil && inputs.contains(predecessor.outputVideo),
                                               "renderSubmission.extensionInput")
                try PlanningValidation.require(Set(inputs.map(\.path)) == Set(([predecessor.outputVideo]
                    + recipe.permittedOriginalReferences).map(\.path)), "renderSubmission.extensionReferences")
                for original in recipe.permittedOriginalReferences {
                    try PlanningValidation.require(inputs.contains(original), "renderSubmission.extensionReferenceBytes")
                }
            }
        } else {
            try PlanningValidation.require(predecessor == nil && inputs == planned.conditioning,
                                           "renderSubmission.conditioning")
        }
    }

    public func requireCurrentEvidence(review reviewed: RenderReviewV1, projection: ProductionPlanProjectionV1,
                                       dataRoot: URL, reviewVerifier: RenderReviewEvidenceVerifier? = nil,
                                       submissionVerifier: RenderSubmissionEvidenceVerifier? = nil) throws {
        try validate(review: reviewed, projection: projection)
        guard let submissionVerifier else { throw ProductionPlanningError.invalid("renderSubmission.hostEvidenceVerifier") }
        try reviewed.requireCurrentEvidence(dataRoot: dataRoot, projection: projection, verifier: reviewVerifier)
        let reviewURL = try ProjectLocalFile.requireHash(review.sha256, at: review.path, dataRoot: dataRoot)
        let storedReview = try JSONDecoder().decode(RenderReviewV1.self, from: Data(contentsOf: reviewURL))
        try PlanningValidation.require(storedReview == reviewed, "renderSubmission.reviewBytes")
        var references = inputs + [compiledPrompt, route]
        if let predecessor {
            references += [predecessor.selectionReceipt, predecessor.outputVideo] + [predecessor.lastFrame].compactMap { $0 }
        }
        for reference in references {
            _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
        }
        try submissionVerifier(self, dataRoot)
    }
}

public enum RenderReviewValidatorV1 {
    public static func validate(_ value: RenderReviewV1, projection: ProductionPlanProjectionV1,
                                draft: ShotPlanningDraftV1, approval: Bool = false) throws {
        try validate(value, projection: projection, approval: approval)
        try PlanningValidation.require(draft.shots.map(\.shotID) == value.shots.map(\.shotID), "renderReview.draftCoverage")
        for (planned, reviewed) in zip(draft.shots, value.shots) {
            let expected: RenderReviewV1.PredecessorRecipe.Strategy?
            switch planned.chainKind {
            case .none: expected = nil
            case .frameContinuation: expected = .frameContinuation
            case .nativeExtension: expected = .nativeExtension
            }
            try PlanningValidation.require(reviewed.predecessor?.strategy == expected
                && reviewed.predecessor?.predecessorShotID == planned.predecessorShotID,
                                           "renderReview.chainSubstitution")
        }
    }

    public static func validate(_ value: RenderReviewV1, projection: ProductionPlanProjectionV1, approval: Bool = false) throws {
        try ProductionPlanProjectionValidatorV1.validate(projection)
        try value.header.validate()
        try PlanningValidation.require(value.schema == RenderReviewV1.schemaVersion
            && value.header.projectID == projection.header.projectID, "renderReview.header")
        try PlanningValidation.reference(value.productionPlan)
        try PlanningValidation.reference(value.reviewEvidence)
        try PlanningValidation.require(value.header.inputs.contains {
            $0.path == value.productionPlan.path && $0.sha256 == value.productionPlan.sha256
        }, "renderReview.planBinding")
        try PlanningValidation.require(value.productionPlan.path == ProductionPlanProjectionV1.versionPath(projection.header.revision), "renderReview.planPath")
        try PlanningValidation.text(value.reviewer.reviewerID, "renderReview.reviewer")
        if value.reviewer.kind == .model {
            try PlanningValidation.text(value.reviewer.modelID ?? "", "renderReview.reviewer.model")
            try PlanningValidation.path(value.reviewer.promptPath ?? "")
            try PlanningValidation.hash(value.reviewer.promptSHA256 ?? "", "renderReview.reviewer.prompt")
            try PlanningValidation.require(value.reviewer.responsePath == value.reviewEvidence.path
                && value.reviewer.responseSHA256 == value.reviewEvidence.sha256, "renderReview.reviewer.response")
        }
        try PlanningValidation.unique(value.shots.map(\.shotID), "renderReview.shotIDs")
        try PlanningValidation.require(value.shots.map(\.shotID) == projection.shots.map(\.id), "renderReview.shotCoverage")
        try PlanningValidation.unique(value.findings.map(\.id), "renderReview.findingIDs")
        let known = Set(projection.shots.map(\.id))
        for (review, shot) in zip(value.shots, projection.shots) {
            let chain = projection.chains.first { $0.shotID == shot.id }
            let expectedStrategy: RenderReviewV1.PredecessorRecipe.Strategy?
            switch chain?.kind {
            case .some(.frameContinuation): expectedStrategy = .frameContinuation
            case .some(.nativeExtension): expectedStrategy = .nativeExtension
            default: expectedStrategy = nil
            }
            try PlanningValidation.require(review.predecessor?.strategy == expectedStrategy
                && review.predecessor?.predecessorShotID == chain?.predecessorShotID,
                                           "renderReview.projectedPredecessor")
            try PlanningValidation.require(!review.evidence.isEmpty, "renderReview.shot.evidence")
            if shot.sourceMode == .imported {
                try PlanningValidation.require(review.compiledPrompt == nil && review.route == nil
                    && review.promptIRSHA256 == nil && review.conditioning.isEmpty && review.predecessor == nil,
                                               "renderReview.importedNoGeneration")
                guard let source = projection.source(for: shot.id), review.evidence.contains(source) else {
                    throw ProductionPlanningError.invalid("renderReview.importedSource")
                }
            } else {
                let still = ShotDeliveryModeResolverV1.resolve(shot) == .timelineAnimatedStill
                guard review.compiledPrompt != nil, (still ? review.route == nil : review.route != nil), let ir = review.promptIRSHA256 else {
                    throw ProductionPlanningError.invalid("renderReview.compilation")
                }
                try PlanningValidation.hash(ir, "renderReview.promptIR")
            }
            if let predecessor = review.predecessor {
                try PlanningValidation.require(shot.sourceMode == .generated && predecessor.predecessorShotID != shot.id
                    && projection.shots.contains { $0.id == predecessor.predecessorShotID && $0.sourceMode == .generated }
                    && ShotDeliveryModeResolverV1.resolve(shot) != .timelineAnimatedStill,
                                               "renderReview.predecessor")
                if predecessor.strategy == .frameContinuation {
                    try PlanningValidation.require(predecessor.extensionModeID == nil
                        && predecessor.permittedOriginalReferences.isEmpty && review.conditioning.isEmpty
                        && projection.requiredFrameRoles(for: shot.id).isEmpty, "renderReview.continuationInput")
                } else {
                    try PlanningValidation.text(predecessor.extensionModeID ?? "", "renderReview.extensionMode")
                    try PlanningValidation.require(shot.generationRequirement?.modeIDs.contains(predecessor.extensionModeID ?? "") == true,
                                                   "renderReview.extensionModeBinding")
                }
            }
        }
        let chains = Dictionary(uniqueKeysWithValues: value.shots.map { ($0.shotID, $0.predecessor?.predecessorShotID) })
        for shot in value.shots {
            var visited = Set<String>()
            var cursor: String? = shot.shotID
            while let id = cursor {
                try PlanningValidation.require(visited.insert(id).inserted, "renderReview.chainCycle")
                cursor = chains[id] ?? nil
            }
        }
        for finding in value.findings {
            try PlanningValidation.identifier(finding.id, "renderReview.finding.id")
            try PlanningValidation.text(finding.message, "renderReview.finding.message")
            try PlanningValidation.unique(finding.shotIDs, "renderReview.finding.shotIDs")
            try PlanningValidation.require(!finding.shotIDs.isEmpty && Set(finding.shotIDs).isSubset(of: known)
                && !finding.evidence.isEmpty, "renderReview.finding.evidence")
            if let acceptance = finding.acceptance {
                try PlanningValidation.reference(acceptance)
                try PlanningValidation.require(finding.kind == .creativeAdvice || finding.kind == .semanticConcern,
                                               "renderReview.nonWaivableFinding")
                try PlanningValidation.text(finding.acceptanceReason ?? "", "renderReview.acceptanceReason")
            } else {
                try PlanningValidation.require(finding.acceptanceReason == nil, "renderReview.orphanAcceptanceReason")
            }
            if approval {
                try PlanningValidation.require(finding.kind != .structuralError && finding.kind != .unresolved,
                                               "renderReview.unresolvedBlocker")
                if finding.kind == .semanticConcern {
                    try PlanningValidation.require(finding.acceptance != nil, "renderReview.semanticConcern")
                }
            }
        }
        var hashes: [String: String] = [:]
        for reference in value.references {
            try PlanningValidation.reference(reference)
            try PlanningValidation.require(hashes[reference.path] == nil || hashes[reference.path] == reference.sha256,
                                           "renderReview.conflictingEvidence")
            hashes[reference.path] = reference.sha256
        }
    }
}
