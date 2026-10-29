import Foundation

public typealias ShotPlanningPromotionEvidenceVerifierV1 = @Sendable (ShotPlanningPromotionV1, URL) throws -> Void

public struct ShotPlanningPromotionV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "shot-planning-promotion/v1"
    public static let currentPath = "shot-planning/promotion-current.v1.json"

    public struct RouteBinding: Codable, Sendable, Equatable {
        public let shotID: String
        public let route: CanonicalArtifactReferenceV1

        public init(shotID: String, route: CanonicalArtifactReferenceV1) {
            self.shotID = shotID
            self.route = route
        }
    }

    public struct Resolution: Codable, Sendable, Equatable {
        public enum Outcome: Codable, Sendable, Equatable {
            case asset(assetID: String, evidence: CanonicalArtifactReferenceV1)
            case skipped(reason: String)
        }

        public let shotID: String
        public let obligationID: String
        public let outcome: Outcome
        public let confirmationReceipt: CanonicalArtifactReferenceV1

        public init(shotID: String, obligationID: String, outcome: Outcome,
                    confirmationReceipt: CanonicalArtifactReferenceV1) {
            self.shotID = shotID
            self.obligationID = obligationID
            self.outcome = outcome
            self.confirmationReceipt = confirmationReceipt
        }
    }

    public let schema: String
    public let header: PlanningArtifactHeaderV1
    public let draft: CanonicalArtifactReferenceV1
    public let timing: CanonicalArtifactReferenceV1
    public let bible: CanonicalArtifactReferenceV1
    public let assetGraph: CanonicalArtifactReferenceV1
    public let projection: CanonicalArtifactReferenceV1
    public let routes: [RouteBinding]
    public let resolutions: [Resolution]

    public init(schema: String = schemaVersion, header: PlanningArtifactHeaderV1,
                draft: CanonicalArtifactReferenceV1, timing: CanonicalArtifactReferenceV1,
                bible: CanonicalArtifactReferenceV1, assetGraph: CanonicalArtifactReferenceV1,
                projection: CanonicalArtifactReferenceV1, routes: [RouteBinding], resolutions: [Resolution]) {
        self.schema = schema
        self.header = header
        self.draft = draft
        self.timing = timing
        self.bible = bible
        self.assetGraph = assetGraph
        self.projection = projection
        self.routes = routes
        self.resolutions = resolutions
    }

    public static func versionPath(_ revision: Int) -> String { "shot-planning/promotion-v\(revision).v1.json" }

    public static func planningDirectory(revision: Int) -> String { "execution/planning/v\(revision)" }
    public static func creativeContextPath(revision: Int) -> String { planningDirectory(revision: revision) + "/creative-context.v1.json" }
    public static func executionPlanPath(revision: Int) -> String { planningDirectory(revision: revision) + "/execution-plan.v1.json" }
    public static func assetGraphPath(revision: Int) -> String { planningDirectory(revision: revision) + "/asset-graph.v1.json" }
    public static func routePath(shotID: String, revision: Int) -> String { planningDirectory(revision: revision) + "/routes/\(shotID).v1.json" }
    public static func inputTemplatePath(shotID: String, revision: Int) -> String { planningDirectory(revision: revision) + "/input-templates/\(shotID).v1.json" }
    public static func demandPath(shotID: String, revision: Int) -> String { planningDirectory(revision: revision) + "/demands/\(shotID).v1.json" }

    public var artifactReferences: [CanonicalArtifactReferenceV1] {
        header.inputs + [draft, timing, bible, assetGraph, projection] + routes.map(\.route)
            + resolutions.flatMap { resolution in
                switch resolution.outcome {
                case .asset(_, let evidence): [resolution.confirmationReceipt, evidence]
                case .skipped: [resolution.confirmationReceipt]
                }
            }
    }

    public func requireCurrentEvidence(draft: ShotPlanningDraftV1, timing: StoryboardTimingV1,
                                       bible: Bible, assetGraph: AssetGraphV1, projection: ProductionPlanProjectionV1,
                                       dataRoot: URL, verifier: ShotPlanningPromotionEvidenceVerifierV1? = nil) throws {
        try ShotPlanningPromotionValidatorV1.validate(self, draft: draft, timing: timing, bible: bible,
                                                     assetGraph: assetGraph, projection: projection)
        guard let verifier else { throw ProductionPlanningError.invalid("promotion.hostEvidenceVerifier") }
        let refs = try ProductionPlanFilesV1.unique(artifactReferences)
        try ProductionPlanFilesV1.require(refs, dataRoot: dataRoot)
        let storedDraft = try JSONDecoder().decode(ShotPlanningDraftV1.self,
            from: Data(contentsOf: ProjectLocalFile.resolve(self.draft.path, dataRoot: dataRoot)))
        let storedTiming = try JSONDecoder().decode(StoryboardTimingV1.self,
            from: Data(contentsOf: ProjectLocalFile.resolve(self.timing.path, dataRoot: dataRoot)))
        let storedBible = try YAMLCoding.decode(Bible.self, from: ProjectLocalFile.resolve(self.bible.path, dataRoot: dataRoot))
        let storedGraph = try JSONDecoder().decode(AssetGraphV1.self,
            from: Data(contentsOf: ProjectLocalFile.resolve(self.assetGraph.path, dataRoot: dataRoot)))
        let storedPlan = try YAMLCoding.decode(ProductionPlanProjectionV1.self,
            from: ProjectLocalFile.resolve(self.projection.path, dataRoot: dataRoot))
        try PlanningValidation.require(storedDraft == draft && storedTiming == timing && storedBible == bible
            && storedGraph == assetGraph && storedPlan == projection, "promotion.exactInputBytes")
        try AssetGraphValidatorV1.validateProjectFiles(assetGraph, dataRoot: dataRoot)
        try verifier(self, dataRoot)
        try ProductionPlanFilesV1.require(refs, dataRoot: dataRoot)
    }
}

public enum ShotPlanningPromotionValidatorV1 {
    public static func validate(_ value: ShotPlanningPromotionV1, draft: ShotPlanningDraftV1,
                                timing: StoryboardTimingV1, bible: Bible, assetGraph: AssetGraphV1,
                                projection: ProductionPlanProjectionV1) throws {
        try ProductionPlanProjectionValidatorV1.validate(projection, timing: timing, draft: draft)
        try AssetGraphValidatorV1.validate(assetGraph)
        try bible.validate()
        try value.header.validate()
        try PlanningValidation.require(value.schema == ShotPlanningPromotionV1.schemaVersion
            && value.header.projectID == projection.header.projectID && bible.project == value.header.projectID
            && assetGraph.projectID == value.header.projectID, "promotion.identity")
        try PlanningValidation.require(value.draft == projection.draftReference && value.timing == projection.storyboardReference
            && value.projection.path == ProductionPlanProjectionV1.versionPath(projection.header.revision)
            && value.bible.path == PipelineLayout.bibleFile
            && value.header.revision == projection.header.revision
            && value.assetGraph.path == ShotPlanningPromotionV1.assetGraphPath(revision: projection.header.revision),
                                       "promotion.canonicalInputs")
        for ref in [value.draft, value.timing, value.bible, value.assetGraph, value.projection] {
            try PlanningValidation.reference(ref)
            try PlanningValidation.require(value.header.inputs.contains(ref), "promotion.inputBinding")
        }
        let generated = projection.shots.filter { $0.generationRequirement != nil }.map(\.id)
        let providerVideo = projection.shots.filter { ShotDeliveryModeResolverV1.resolve($0) == .providerVideo }.map(\.id)
        try PlanningValidation.require(value.routes.map(\.shotID) == providerVideo, "promotion.routeCoverage")
        for route in value.routes {
            try PlanningValidation.reference(route.route)
            try PlanningValidation.require(route.route.path == ShotPlanningPromotionV1.routePath(shotID: route.shotID, revision: projection.header.revision)
                && value.header.inputs.contains(route.route), "promotion.routeBinding")
        }
        for shotID in generated {
            for path in [ShotPlanningPromotionV1.inputTemplatePath(shotID: shotID, revision: projection.header.revision),
                         ShotPlanningPromotionV1.demandPath(shotID: shotID, revision: projection.header.revision)] {
                try PlanningValidation.require(value.header.inputs.contains { $0.path == path }
                    && projection.header.inputs.contains { $0.path == path }, "promotion.immutablePlannedInput")
            }
        }
        let expected = draft.shots.flatMap { shot in shot.obligations.map { shot.shotID + ":" + $0.id } }
        let actual = value.resolutions.map { $0.shotID + ":" + $0.obligationID }
        try PlanningValidation.unique(actual, "promotion.obligationIDs")
        try PlanningValidation.require(Set(actual) == Set(expected), "promotion.obligationCoverage")
        let assets = Dictionary(uniqueKeysWithValues: assetGraph.assets.map { ($0.id, $0) })
        for resolution in value.resolutions {
            guard let shot = draft.shots.first(where: { $0.shotID == resolution.shotID }),
                  let obligation = shot.obligations.first(where: { $0.id == resolution.obligationID }) else {
                throw ProductionPlanningError.invalid("promotion.unknownObligation")
            }
            try PlanningValidation.reference(resolution.confirmationReceipt)
            switch resolution.outcome {
            case .skipped(let reason):
                try PlanningValidation.require(!obligation.required && obligation.allowedSkipReason == reason,
                                               "promotion.unapprovedSkip")
                try PlanningValidation.text(reason, "promotion.skipReason")
            case .asset(let assetID, let evidence):
                try PlanningValidation.reference(evidence)
                guard let asset = assets[assetID], asset.approval == .approved,
                      asset.path == evidence.path, asset.sha256 == evidence.sha256 else {
                    throw ProductionPlanningError.invalid("promotion.actualApprovedAsset")
                }
                try PlanningSpatialAssetV1.requireObligationPurpose(obligation, asset: asset)
                switch obligation.kind {
                case .sourceFootage:
                    try PlanningValidation.require(asset.modality == .video && evidence.path == projection.source(for: shot.shotID)?.path
                        && evidence.sha256 == projection.source(for: shot.shotID)?.sha256, "promotion.sourceFootage")
                case .geometry:
                    guard asset.modality == .geometry, let id = asset.entityID, case .location? = bible.lookupId(id) else {
                        throw ProductionPlanningError.invalid("promotion.geometryAsset")
                    }
                case .stateVariant:
                    try PlanningValidation.require(asset.modality == .image && asset.stateID != nil
                        && asset.entityID.flatMap(bible.lookupId) != nil, "promotion.stateAsset")
                case .characterIdentity, .locationAppearance, .prop:
                    guard asset.modality == .image, let id = asset.entityID, let entity = bible.lookupId(id) else {
                        throw ProductionPlanningError.invalid("promotion.bibleEntity")
                    }
                    let paths: [String]
                    switch (obligation.kind, entity) {
                    case (.characterIdentity, .character(let item)): paths = item.referenceImages + Array(item.sheets.values)
                    case (.characterIdentity, .ensemble(let item)): paths = item.referenceImages + Array(item.sheets.values)
                    case (.locationAppearance, .location(let item)): paths = item.referenceImages + Array(item.sheets.values)
                    case (.prop, .prop(let item)): paths = item.referenceImages + Array(item.sheets.values)
                    default: throw ProductionPlanningError.invalid("promotion.entityKind")
                    }
                    try PlanningValidation.require(paths.contains(asset.path), "promotion.entityAnchor")
                case .look:
                    try PlanningValidation.require(asset.modality == .image, "promotion.lookAsset")
                }
            }
        }
    }
}
