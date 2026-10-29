import Foundation

public struct ProductionPlanProjectionV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "shotlist/v5"

    public struct ChainBinding: Codable, Sendable, Equatable {
        public let shotID: String
        public let kind: ShotPlanningDraftV1.ShotIntent.ChainKind
        public let predecessorShotID: String

        public init(shotID: String, kind: ShotPlanningDraftV1.ShotIntent.ChainKind, predecessorShotID: String) {
            self.shotID = shotID
            self.kind = kind
            self.predecessorShotID = predecessorShotID
        }
    }

    public struct EditorialBinding: Codable, Sendable, Equatable {
        public let shotID: String
        public let sceneID: String
        public let narrativeBeat: NarrativeBeat?

        public init(shotID: String, sceneID: String, narrativeBeat: NarrativeBeat? = nil) {
            self.shotID = shotID
            self.sceneID = sceneID
            self.narrativeBeat = narrativeBeat
        }
    }

    public struct SourceInputRange: Codable, Sendable, Equatable {
        public let shotID: String
        public let source: CanonicalArtifactReferenceV1
        public let timebase: RationalTimebaseV1
        public let startTicks: Int64
        public let durationTicks: Int64

        public init(shotID: String, source: CanonicalArtifactReferenceV1, timebase: RationalTimebaseV1,
                    startTicks: Int64, durationTicks: Int64) {
            self.shotID = shotID
            self.source = source
            self.timebase = timebase
            self.startTicks = startTicks
            self.durationTicks = durationTicks
        }
    }

    public struct ShotTiming: Codable, Sendable, Equatable {
        public let shotID: String
        public let startTicks: Int64
        public let durationTicks: Int64
        public let nativeDurationTicks: Int64?
        public let sourceInTicks: Int64

        public init(shotID: String, startTicks: Int64, durationTicks: Int64,
                    nativeDurationTicks: Int64? = nil, sourceInTicks: Int64 = 0) {
            self.shotID = shotID
            self.startTicks = startTicks
            self.durationTicks = durationTicks
            self.nativeDurationTicks = nativeDurationTicks
            self.sourceInTicks = sourceInTicks
        }

        public func endTicks() throws -> Int64 { try PlanningValidation.end(start: startTicks, duration: durationTicks) }
    }

    public let schema: String
    public let header: PlanningArtifactHeaderV1
    public let timebase: RationalTimebaseV1
    public let mode: Mode
    public let executionPlan: ExecutionPlanV1
    public let timings: [ShotTiming]
    public let sourceBindings: [CanonicalArtifactReferenceV1]
    public let draftReference: CanonicalArtifactReferenceV1
    public let storyboardReference: CanonicalArtifactReferenceV1
    public let editorialBindings: [EditorialBinding]
    public let chains: [ChainBinding]
    public let sourceInputRanges: [SourceInputRange]

    public init(schema: String = schemaVersion, header: PlanningArtifactHeaderV1, timebase: RationalTimebaseV1,
                mode: Mode, executionPlan: ExecutionPlanV1, timings: [ShotTiming],
                sourceBindings: [CanonicalArtifactReferenceV1], draftReference: CanonicalArtifactReferenceV1,
                storyboardReference: CanonicalArtifactReferenceV1, editorialBindings: [EditorialBinding] = [],
                chains: [ChainBinding] = [], sourceInputRanges: [SourceInputRange] = []) {
        self.schema = schema
        self.header = header
        self.timebase = timebase
        self.mode = mode
        self.executionPlan = executionPlan
        self.timings = timings
        self.sourceBindings = sourceBindings
        self.draftReference = draftReference
        self.storyboardReference = storyboardReference
        self.editorialBindings = editorialBindings
        self.chains = chains
        self.sourceInputRanges = sourceInputRanges
    }

    public var shots: [ExecutionShotV1] { executionPlan.shots }
    public static func versionPath(_ revision: Int) -> String { "shotlist/v\(revision).v5.yaml" }
    public func timing(for shotID: String) -> ShotTiming? { timings.first { $0.shotID == shotID } }

    public func source(for shotID: String) -> CanonicalArtifactReferenceV1? {
        guard let assetID = shots.first(where: { $0.id == shotID })?.sourceAssetID else { return nil }
        return sourceBindings.first { $0.id == assetID }
    }

    public func requiredFrameRoles(for shotID: String) -> [String] {
        guard let shot = shots.first(where: { $0.id == shotID }), shot.sourceMode == .generated,
              let requirement = shot.generationRequirement else { return [] }
        if ShotDeliveryModeResolverV1.resolve(shot) == .timelineAnimatedStill { return ["start"] }
        if chains.contains(where: { $0.shotID == shotID }) { return [] }
        return (requirement.requiresFirstFrame ? ["start"] : []) + (requirement.requiresLastFrame ? ["end"] : [])
    }

    public func requireCurrentInputs(dataRoot: URL) throws {
        try ProductionPlanProjectionValidatorV1.validate(self)
        let ownPath = Self.versionPath(header.revision)
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(ownPath, dataRoot: dataRoot))
        guard let text = String(data: bytes, encoding: .utf8),
              try YAMLCoding.decode(Self.self, from: text) == self else {
            throw ProductionPlanningError.stale(ownPath)
        }
        try header.requireCurrentInputs(dataRoot: dataRoot)
        let planPath = ShotPlanningPromotionV1.executionPlanPath(revision: header.revision)
        guard let planRef = header.inputs.first(where: { $0.path == planPath }),
              try JSONDecoder().decode(ExecutionPlanV1.self, from: Data(contentsOf: ProjectLocalFile.requireHash(planRef.sha256,
                at: planRef.path, dataRoot: dataRoot))) == executionPlan else {
            throw ProductionPlanningError.stale(planPath)
        }
        for reference in sourceBindings + [draftReference, storyboardReference, executionPlan.creativeContext] {
            _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
        }
        for reference in executionPlan.extensionReferences {
            _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
        }
    }
}

public enum ProductionPlanProjectionValidatorV1 {
    public static func validate(_ value: ProductionPlanProjectionV1) throws {
        try PlanningValidation.require(value.schema == ProductionPlanProjectionV1.schemaVersion, "productionPlan.schema")
        try value.header.validate()
        try value.timebase.validate()
        try ExecutionPlanValidator.validate(value.executionPlan,
            creativeContextPath: ShotPlanningPromotionV1.creativeContextPath(revision: value.header.revision))
        try PlanningValidation.require(value.header.projectID == value.executionPlan.projectID && value.mode != .phrase, "productionPlan.project")
        try PlanningValidation.reference(value.draftReference)
        try PlanningValidation.reference(value.storyboardReference)
        try PlanningValidation.require(value.draftReference.path.hasPrefix("shot-planning/")
            && value.storyboardReference.path.hasPrefix("storyboard/"), "productionPlan.references")
        for reference in [value.draftReference, value.storyboardReference] {
            try PlanningValidation.require(value.header.inputs.contains { $0.path == reference.path && $0.sha256 == reference.sha256 }, "productionPlan.inputBinding")
        }
        try PlanningValidation.unique(value.timings.map(\.shotID), "productionPlan.timingIDs")
        try PlanningValidation.require(value.timings.map(\.shotID) == value.shots.map(\.id), "productionPlan.timingCoverage")
        try PlanningValidation.require(value.editorialBindings.map(\.shotID) == value.shots.map(\.id), "productionPlan.editorialCoverage")
        for binding in value.editorialBindings { try PlanningValidation.identifier(binding.sceneID, "productionPlan.sceneID") }
        try PlanningValidation.unique(value.chains.map(\.shotID), "productionPlan.chainIDs")
        let chains = Dictionary(uniqueKeysWithValues: value.chains.map { ($0.shotID, $0) })
        for chain in value.chains {
            guard let shot = value.shots.first(where: { $0.id == chain.shotID }), shot.sourceMode == .generated,
                  let requirement = shot.generationRequirement,
                  let predecessor = value.shots.first(where: { $0.id == chain.predecessorShotID && $0.sourceMode == .generated }) else {
                throw ProductionPlanningError.invalid("productionPlan.chainShots")
            }
            try PlanningValidation.require(ShotDeliveryModeResolverV1.resolve(predecessor) == .providerVideo, "productionPlan.chainPredecessorVideo")
            try PlanningValidation.require(chain.kind != .none && chain.shotID != chain.predecessorShotID
                && ShotDeliveryModeResolverV1.resolve(shot) == .providerVideo, "productionPlan.chainKind")
            if chain.kind == .frameContinuation {
                try PlanningValidation.require(requirement.requiresFirstFrame && !requirement.requiresLastFrame
                    && requirement.referenceDemandIDs.isEmpty && requirement.sourceVideoAssetID == nil,
                                               "productionPlan.soleContinuationFrame")
            } else {
                try PlanningValidation.require(!requirement.requiresFirstFrame && !requirement.requiresLastFrame
                    && requirement.sourceVideoAssetID != nil, "productionPlan.nativeExtensionVideo")
            }
            var visited = Set<String>()
            var cursor: String? = chain.shotID
            while let id = cursor {
                try PlanningValidation.require(visited.insert(id).inserted, "productionPlan.chainCycle")
                cursor = chains[id]?.predecessorShotID
            }
        }
        try PlanningValidation.unique(value.sourceInputRanges.map(\.shotID), "productionPlan.inputRangeIDs")
        try PlanningValidation.require(Set(value.sourceInputRanges.map(\.shotID)) == Set(value.shots.filter { $0.sourceMode == .aiEnhanced }.map(\.id)),
                                       "productionPlan.inputRangeCoverage")
        for range in value.sourceInputRanges {
            try range.timebase.validate()
            _ = try PlanningValidation.end(start: range.startTicks, duration: range.durationTicks)
            try PlanningValidation.require(value.source(for: range.shotID) == range.source, "productionPlan.inputRangeSource")
        }
        try PlanningValidation.unique(value.sourceBindings.map(\.id), "productionPlan.sourceIDs")
        for source in value.sourceBindings { try PlanningValidation.reference(source) }
        var expectedSources = Set<String>()
        for (shot, timing) in zip(value.shots, value.timings) {
            try PlanningValidation.shotID(shot.id)
            _ = try timing.endTicks()
            try PlanningValidation.require(timing.sourceInTicks >= 0, "productionPlan.sourceInTicks")
            let requiredEnd = try PlanningValidation.end(start: timing.sourceInTicks, duration: timing.durationTicks)
            if let native = timing.nativeDurationTicks {
                try PlanningValidation.require(native >= requiredEnd, "productionPlan.nativeDurationTicks")
            } else {
                try PlanningValidation.require(timing.sourceInTicks == 0, "productionPlan.undeclaredTrim")
            }
            if shot.sourceMode == .generated {
                try PlanningValidation.require(shot.sourceAssetID == nil, "productionPlan.generatedSource")
            } else {
                guard let source = value.source(for: shot.id) else { throw ProductionPlanningError.invalid("productionPlan.sourceBinding") }
                expectedSources.insert(source.id)
            }
            if let preferred = shot.generationRequirement?.duration?.preferredSeconds {
                let nativeSeconds = value.timebase.seconds(for: timing.nativeDurationTicks ?? timing.durationTicks)
                try PlanningValidation.require(abs(preferred - nativeSeconds) <= shotlistDurationEpsilon, "productionPlan.nativeDurationProjection")
            }
        }
        try PlanningValidation.require(expectedSources == Set(value.sourceBindings.map(\.id)), "productionPlan.sourceCoverage")
    }

    public static func validate(_ value: ProductionPlanProjectionV1, timing: StoryboardTimingV1,
                                draft: ShotPlanningDraftV1, context: ProjectCreativeContextV1? = nil) throws {
        try validate(value)
        try ShotPlanningValidatorV1.validate(draft, timing: timing)
        try PlanningValidation.require(value.header.projectID == timing.header.projectID
            && value.timebase == timing.timebase && value.mode == timing.mode
            && value.shots.map(\.id) == timing.shots.map(\.id), "productionPlan.storyboardProjection")
        for (planned, actual) in zip(timing.shots, value.timings) {
            try PlanningValidation.require(planned.startTicks == actual.startTicks && planned.durationTicks == actual.durationTicks,
                                           "productionPlan.editorialTiming")
        }
        for (intent, shot) in zip(draft.shots, value.shots) {
            let chain = value.chains.first { $0.shotID == shot.id }
            try PlanningValidation.require((chain?.kind ?? .none) == intent.chainKind
                && chain?.predecessorShotID == intent.predecessorShotID, "productionPlan.chainSubstitution")
            try PlanningValidation.require(value.editorialBindings.first { $0.shotID == shot.id }?.narrativeBeat
                == intent.narrativeBeat, "productionPlan.narrativeSubstitution")
            let expectedMode: ExecutionSourceModeV1
            switch intent.sourceMode {
            case .generated: expectedMode = .generated
            case .imported: expectedMode = .imported
            case .aiEnhanced: expectedMode = .aiEnhanced
            }
            try PlanningValidation.require(shot.sourceMode == expectedMode, "productionPlan.sourceMode")
            if shot.sourceMode != .imported {
                try PlanningValidation.require(shot.camera.movementID == intent.camera.movement.rawValue
                    && shot.camera.movementDetail == intent.camera.movementDetail,
                                               "productionPlan.cameraSubstitution")
            }
            if ShotDeliveryModeResolverV1.resolve(shot) == .timelineAnimatedStill {
                try PlanningValidation.require(intent.chainKind == .none, "productionPlan.stillCannotChain")
            }
            if let selected = intent.source {
                try PlanningValidation.require(value.source(for: shot.id)?.path == selected.path
                    && value.source(for: shot.id)?.sha256 == selected.sha256, "productionPlan.sourceSubstitution")
            }
        }
        if let context { try ExecutionPlanValidator.validate(value.executionPlan, against: context,
            creativeContextPath: ShotPlanningPromotionV1.creativeContextPath(revision: value.header.revision)) }
    }

    public static func validate(_ value: ProductionPlanProjectionV1, storyboard: StoryboardBundleSnapshot,
                                draft: ShotPlanningDraftV1, context: ProjectCreativeContextV1? = nil) throws {
        try validate(value, timing: storyboard.timing, draft: draft, context: context)
        try PlanningValidation.require(value.storyboardReference.path == StoryboardTimingV1.versionPath(storyboard.timing.header.revision),
                                       "productionPlan.storyboardTimingPath")
        try PlanningValidation.require(storyboard.references.contains {
            $0.path == value.storyboardReference.path && $0.sha256 == value.storyboardReference.sha256
        }, "productionPlan.storyboardTimingBytes")
        let steps = Dictionary(uniqueKeysWithValues: storyboard.storyboard.steps.map { ($0.id, $0) })
        for ((planned, binding), shot) in zip(zip(storyboard.timing.shots, value.editorialBindings), value.shots) {
            try PlanningValidation.require(steps[planned.primaryStepID]?.sceneID == binding.sceneID,
                                           "productionPlan.primarySceneSubstitution")
            let actions = planned.stepIDs.compactMap { steps[$0]?.action }
            try PlanningValidation.require(actions.count == planned.stepIDs.count && shot.primaryAction == actions.joined(separator: "\n"),
                                           "productionPlan.primaryActionSubstitution")
        }
    }
}
