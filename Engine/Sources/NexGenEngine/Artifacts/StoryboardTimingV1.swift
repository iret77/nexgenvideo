import Foundation

public typealias StoryboardSketchEvidenceVerifier = @Sendable (StoryboardSketchProofV1, URL) throws -> Void
public typealias StoryboardSketchEvidenceReferences = @Sendable (StoryboardSketchProofV1, URL) throws -> [CanonicalArtifactReferenceV1]

public struct SourceMediaTimebaseV1: Codable, Sendable, Equatable {
    public let ticksPerSecond: Int64

    public init(ticksPerSecond: Int64) { self.ticksPerSecond = ticksPerSecond }

    public func validate() throws {
        try PlanningValidation.require(ticksPerSecond > 0 && ticksPerSecond <= Int64(Int32.max), "sourceMedia.timebase")
    }

    public func seconds(for ticks: Int64) -> Double { Double(ticks) / Double(ticksPerSecond) }
}

public struct StoryboardSketchProofV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "storyboard-sketch-proof/v1"

    public enum Source: Codable, Sendable, Equatable {
        case uploaded(original: CanonicalArtifactReferenceV1, selectionReceiptID: String)
        case externalConfirmed(original: CanonicalArtifactReferenceV1, confirmationReceiptID: String)
        case generated(modelID: String, compiledPrompt: CanonicalArtifactReferenceV1, providerRequestID: String?, generationEventID: String, generationReceipt: CanonicalArtifactReferenceV1, inputs: [CanonicalArtifactReferenceV1] = [])
        case spatialDerived(proof: CanonicalArtifactReferenceV1)
        case sourceFrame(video: CanonicalArtifactReferenceV1, timebase: SourceMediaTimebaseV1, sourceTick: Int64, sourceDurationTicks: Int64, selectionReceiptID: String)
        case reassigned(originalImage: CanonicalArtifactReferenceV1, originalProof: CanonicalArtifactReferenceV1, selectionReceiptID: String)
    }

    public let schema: String
    public let projectID: String
    public let shotID: String
    public let momentID: String
    public let intentSHA256: String
    public let framingSHA256: String
    public let image: CanonicalArtifactReferenceV1
    public let source: Source

    public init(schema: String = schemaVersion, projectID: String, shotID: String, momentID: String,
                intentSHA256: String, framingSHA256: String, image: CanonicalArtifactReferenceV1, source: Source) {
        self.schema = schema
        self.projectID = projectID
        self.shotID = shotID
        self.momentID = momentID
        self.intentSHA256 = intentSHA256
        self.framingSHA256 = framingSHA256
        self.image = image
        self.source = source
    }

    public func validate() throws {
        try PlanningValidation.require(schema == Self.schemaVersion, "sketch.schema")
        try PlanningValidation.text(projectID, "sketch.projectID")
        try PlanningValidation.shotID(shotID)
        try PlanningValidation.identifier(momentID, "sketch.momentID")
        try PlanningValidation.hash(intentSHA256, "sketch.intentSHA256")
        try PlanningValidation.hash(framingSHA256, "sketch.framingSHA256")
        try PlanningValidation.reference(image)
        try PlanningValidation.require(image.path.hasPrefix("storyboard/sketches/"), "sketch.image.path")
        for reference in sourceReferences { try PlanningValidation.reference(reference) }
        switch source {
        case .uploaded(_, let receipt), .externalConfirmed(_, let receipt):
            try PlanningValidation.text(receipt, "sketch.selectionReceipt")
        case .generated(let model, _, let request, let event, _, _):
            try PlanningValidation.text(model, "sketch.modelID")
            if let request { try PlanningValidation.text(request, "sketch.providerRequestID") }
            try PlanningValidation.text(event, "sketch.generationEventID")
        case .sourceFrame(_, let timebase, let tick, let duration, let receipt):
            try timebase.validate()
            try PlanningValidation.require(tick >= 0 && tick < duration, "sketch.sourceTick")
            try PlanningValidation.text(receipt, "sketch.selectionReceipt")
        case .reassigned(let original, _, let receipt):
            try PlanningValidation.require(original == image, "sketch.reassignedImage")
            try PlanningValidation.text(receipt, "sketch.selectionReceipt")
        case .spatialDerived: break
        }
    }

    public var sourceReferences: [CanonicalArtifactReferenceV1] {
        switch source {
        case .uploaded(let source, _), .externalConfirmed(let source, _): [source]
        case .generated(_, let prompt, _, _, let receipt, let inputs): [prompt, receipt] + inputs
        case .spatialDerived(let proof): [proof]
        case .sourceFrame(let video, _, _, _, _): [video]
        case .reassigned(let image, let proof, _): [image, proof]
        }
    }

    public func requireCurrentBytes(dataRoot: URL) throws {
        _ = try currentByteReferences(dataRoot: dataRoot)
    }

    public func currentByteReferences(dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        var visited = Set<String>()
        let references = try byteReferences(dataRoot: dataRoot, visited: &visited, depth: 0)
        var paths: [String: CanonicalArtifactReferenceV1] = [:]
        for ref in references {
            if let prior = paths[ref.path] { try PlanningValidation.require(prior.sha256 == ref.sha256, "sketch.conflictingSourceBytes") }
            else { paths[ref.path] = ref }
        }
        return paths.values.sorted { $0.path < $1.path }
    }

    private func byteReferences(dataRoot: URL, visited: inout Set<String>, depth: Int) throws -> [CanonicalArtifactReferenceV1] {
        try PlanningValidation.require(depth < 64, "sketch.provenanceDepth")
        try validate()
        let imageURL = try ProjectLocalFile.requireHash(image.sha256, at: image.path, dataRoot: dataRoot)
        _ = try FrameRasterizer.loadImage(at: imageURL)
        for source in sourceReferences {
            _ = try ProjectLocalFile.requireHash(source.sha256, at: source.path, dataRoot: dataRoot)
        }
        if case .generated(_, let prompt, _, _, _, _) = source {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(prompt.path, dataRoot: dataRoot))
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw ProductionPlanningError.invalid("sketch.compiledPrompt.utf8")
            }
            try PlanningValidation.text(text, "sketch.compiledPrompt")
        }
        var references = [image] + sourceReferences
        if case .reassigned(let originalImage, let reference, _) = source {
            try PlanningValidation.require(visited.insert(reference.path).inserted, "sketch.provenanceCycle")
            let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot))
            let original = try JSONDecoder().decode(Self.self, from: bytes)
            try PlanningValidation.require(original.projectID == projectID && original.image == originalImage,
                                           "sketch.reassignedOrigin")
            references += try original.byteReferences(dataRoot: dataRoot, visited: &visited, depth: depth + 1)
        }
        return references
    }
}

public struct StoryboardTimingV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "storyboard-timing/v1"
    public static let currentPath = "storyboard/timing-current.v1.json"

    public struct FramingIntent: Codable, Sendable, Equatable {
        public let scale: String
        public let composition: String
        public let cameraView: String

        public init(scale: String, composition: String, cameraView: String) {
            self.scale = scale
            self.composition = composition
            self.cameraView = cameraView
        }

        public func fingerprint() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return FileDigest.sha256(of: try encoder.encode(self))
        }
    }

    public struct SketchAsset: Codable, Sendable, Equatable {
        public let image: CanonicalArtifactReferenceV1
        public let proof: CanonicalArtifactReferenceV1

        public init(image: CanonicalArtifactReferenceV1, proof: CanonicalArtifactReferenceV1) {
            self.image = image
            self.proof = proof
        }
    }

    public struct Moment: Codable, Sendable, Equatable {
        public let id: String
        public let offsetTicks: Int64
        public let intent: String
        public let asset: SketchAsset?

        public init(id: String, offsetTicks: Int64, intent: String, asset: SketchAsset? = nil) {
            self.id = id
            self.offsetTicks = offsetTicks
            self.intent = intent
            self.asset = asset
        }
    }

    public struct PlannedShot: Codable, Sendable, Equatable {
        public let id: String
        public let primaryStepID: String
        public let additionalStepIDs: [String]
        public let startTicks: Int64
        public let durationTicks: Int64
        public let cameraID: String?
        public let framing: FramingIntent
        public let moments: [Moment]

        public init(id: String, primaryStepID: String, additionalStepIDs: [String] = [], startTicks: Int64,
                    durationTicks: Int64, cameraID: String? = nil, framing: FramingIntent, moments: [Moment]) {
            self.id = id
            self.primaryStepID = primaryStepID
            self.additionalStepIDs = additionalStepIDs
            self.startTicks = startTicks
            self.durationTicks = durationTicks
            self.cameraID = cameraID
            self.framing = framing
            self.moments = moments
        }

        public var stepIDs: [String] { [primaryStepID] + additionalStepIDs }
        public func endTicks() throws -> Int64 { try PlanningValidation.end(start: startTicks, duration: durationTicks) }
    }

    public struct AudioBinding: Codable, Sendable, Equatable {
        public let source: CanonicalArtifactReferenceV1
        // sourceTick = timelineTick - offsetTicks; positive offsets delay audio.
        public let offsetTicks: Int64
        public let durationTicks: Int64

        public init(source: CanonicalArtifactReferenceV1, offsetTicks: Int64 = 0, durationTicks: Int64) {
            self.source = source
            self.offsetTicks = offsetTicks
            self.durationTicks = durationTicks
        }

        public func sourceTick(atTimelineTick tick: Int64) -> Int64? {
            let result = tick.subtractingReportingOverflow(offsetTicks)
            guard !result.overflow, result.partialValue >= 0, result.partialValue < durationTicks else { return nil }
            return result.partialValue
        }
    }

    public let schema: String
    public let header: PlanningArtifactHeaderV1
    public let timebase: RationalTimebaseV1
    public let mode: Mode
    public let rangeStartTicks: Int64
    public let rangeDurationTicks: Int64
    public let audio: AudioBinding?
    public let shots: [PlannedShot]

    public init(schema: String = schemaVersion, header: PlanningArtifactHeaderV1, timebase: RationalTimebaseV1,
                mode: Mode, rangeStartTicks: Int64 = 0, rangeDurationTicks: Int64, audio: AudioBinding? = nil,
                shots: [PlannedShot]) {
        self.schema = schema
        self.header = header
        self.timebase = timebase
        self.mode = mode
        self.rangeStartTicks = rangeStartTicks
        self.rangeDurationTicks = rangeDurationTicks
        self.audio = audio
        self.shots = shots
    }

    public static func versionPath(_ revision: Int) -> String { "storyboard/timing-v\(revision).v1.json" }

    public func activeShot(at tick: Int64, cameraID: String? = nil) -> PlannedShot? {
        shots.last { shot in
            guard let end = try? shot.endTicks(), tick >= shot.startTicks, tick < end else { return false }
            return mode != .multicam || shot.cameraID == cameraID
        }
    }

    public func activeMoment(shotID: String, at tick: Int64) -> Moment? {
        guard let shot = shots.first(where: { $0.id == shotID }), let end = try? shot.endTicks(),
              tick >= shot.startTicks, tick < end else { return nil }
        return shot.moments.last { $0.offsetTicks <= tick - shot.startTicks }
    }
}

public enum StoryboardBundleValidator {
    public static func validate(storyboard: StoryboardV2, causality: StoryboardCausalityV2, timing: StoryboardTimingV1,
                                identity: StoryboardIdentityV1, script: ScriptV1,
                                priorIdentity: StoryboardIdentityV1? = nil, requireVisuals: Bool = true) throws {
        try StoryboardValidatorV2.validate(storyboard, causality: causality, script: script)
        try timing.header.validate()
        try identity.header.validate()
        try timing.timebase.validate()
        try PlanningValidation.require(timing.schema == StoryboardTimingV1.schemaVersion
            && identity.schema == StoryboardIdentityV1.schemaVersion, "storyboard.bundle.schema")
        for header in [timing.header, identity.header] {
            try PlanningValidation.require(header.projectID == storyboard.header.projectID
                && header.revision == storyboard.header.revision, "storyboard.bundle.header")
        }
        try PlanningValidation.require(timing.mode != .phrase && !timing.shots.isEmpty, "storyboard.timing.mode")
        let rangeEnd = try PlanningValidation.end(start: timing.rangeStartTicks, duration: timing.rangeDurationTicks)
        try PlanningValidation.unique(timing.shots.map(\.id), "storyboard.shotIDs")
        try PlanningValidation.unique(timing.shots.flatMap(\.moments).map(\.id), "storyboard.momentIDs")
        let knownSteps = Set(storyboard.steps.map(\.id))
        var covered = Set<String>()
        var lastStart: Int64 = -1
        var cameras = Set<String>()
        for shot in timing.shots {
            try PlanningValidation.shotID(shot.id)
            try PlanningValidation.unique(shot.stepIDs, "storyboard.shot.stepIDs")
            try PlanningValidation.require(Set(shot.stepIDs).isSubset(of: knownSteps), "storyboard.shot.steps")
            covered.formUnion(shot.stepIDs)
            let end = try shot.endTicks()
            try PlanningValidation.text(shot.framing.scale, "storyboard.framing.scale")
            try PlanningValidation.text(shot.framing.composition, "storyboard.framing.composition")
            try PlanningValidation.text(shot.framing.cameraView, "storyboard.framing.cameraView")
            if timing.mode == .multicam {
                guard let camera = shot.cameraID else { throw ProductionPlanningError.invalid("storyboard.cameraID") }
                try PlanningValidation.identifier(camera, "storyboard.cameraID")
                try PlanningValidation.require(cameras.insert(camera).inserted && shot.startTicks == 0
                    && end == rangeEnd && timing.rangeStartTicks == 0, "storyboard.multicam.interval")
            } else {
                try PlanningValidation.require(shot.startTicks >= timing.rangeStartTicks && end <= rangeEnd
                    && shot.startTicks >= lastStart && shot.cameraID == nil, "storyboard.interval")
                lastStart = shot.startTicks
            }
            if requireVisuals { try PlanningValidation.require(!shot.moments.isEmpty, "storyboard.moments") }
            if let first = shot.moments.first { try PlanningValidation.require(first.offsetTicks == 0, "storyboard.moments.first") }
            var lastOffset: Int64 = -1
            for moment in shot.moments {
                try PlanningValidation.identifier(moment.id, "storyboard.moment.id")
                try PlanningValidation.text(moment.intent, "storyboard.moment.intent")
                try PlanningValidation.require(moment.offsetTicks > lastOffset && moment.offsetTicks >= 0
                    && moment.offsetTicks < shot.durationTicks, "storyboard.moment.offset")
                lastOffset = moment.offsetTicks
                if requireVisuals { try PlanningValidation.require(moment.asset != nil, "storyboard.moment.image") }
                if let asset = moment.asset {
                    try PlanningValidation.reference(asset.image)
                    try PlanningValidation.reference(asset.proof)
                    try PlanningValidation.require(asset.image.path.hasPrefix("storyboard/sketches/")
                        && asset.proof.path.hasPrefix("storyboard/sketch-proofs/"), "storyboard.moment.assetPaths")
                }
            }
        }
        try PlanningValidation.require(covered == knownSteps, "storyboard.timing.stepCoverage")
        if let audio = timing.audio {
            try PlanningValidation.reference(audio.source)
            try PlanningValidation.require(timing.header.inputs.contains {
                $0.path == audio.source.path && $0.sha256 == audio.source.sha256
            }, "storyboard.audio.inputBinding")
            try PlanningValidation.require(audio.durationTicks > 0
                && !audio.offsetTicks.addingReportingOverflow(audio.durationTicks).overflow, "storyboard.audio")
        }
        if timing.mode == .multicam {
            try PlanningValidation.require(timing.audio?.durationTicks == timing.rangeDurationTicks
                && timing.audio?.offsetTicks == 0, "storyboard.multicam.audio")
        }
        try validateIdentity(identity, storyboard: storyboard, timing: timing, prior: priorIdentity)
    }

    private static func validateIdentity(_ identity: StoryboardIdentityV1, storyboard: StoryboardV2,
                                         timing: StoryboardTimingV1, prior: StoryboardIdentityV1?) throws {
        try PlanningValidation.unique(identity.entries.map(\.shotID), "storyboard.identity.shotIDs")
        let revision = identity.header.revision
        try PlanningValidation.require(revision == 1 || prior != nil, "storyboard.identity.history")
        let steps = Dictionary(uniqueKeysWithValues: storyboard.steps.map { ($0.id, $0) })
        let entries = Dictionary(uniqueKeysWithValues: identity.entries.map { ($0.shotID, $0) })
        for entry in identity.entries {
            try PlanningValidation.shotID(entry.shotID)
            try PlanningValidation.identifier(entry.primaryStepID, "storyboard.identity.primaryStepID")
            try PlanningValidation.hash(entry.actionSHA256, "storyboard.identity.actionSHA256")
            try PlanningValidation.require(entry.introducedRevision > 0 && entry.introducedRevision <= revision, "storyboard.identity.introduced")
            if let retired = entry.retiredRevision {
                try PlanningValidation.require(retired >= entry.introducedRevision && retired <= revision, "storyboard.identity.retired")
            }
        }
        try PlanningValidation.require(Set(identity.entries.filter { $0.retiredRevision == nil }.map(\.shotID))
            == Set(timing.shots.map(\.id)), "storyboard.identity.activeSet")
        for shot in timing.shots {
            guard let entry = entries[shot.id], let step = steps[shot.primaryStepID] else {
                throw ProductionPlanningError.invalid("storyboard.identity.shot")
            }
            try PlanningValidation.require(entry.primaryStepID == shot.primaryStepID
                && entry.actionSHA256 == FileDigest.sha256(of: Data(step.action.utf8)), "storyboard.identity.action")
        }
        if let prior {
            try PlanningValidation.require(prior.header.projectID == identity.header.projectID
                && prior.header.revision == revision - 1, "storyboard.identity.priorRevision")
            try PlanningValidation.unique(prior.entries.map(\.shotID), "storyboard.identity.priorIDs")
            let priorIDs = Set(prior.entries.map(\.shotID))
            for old in prior.entries {
                guard let current = entries[old.shotID] else { throw ProductionPlanningError.invalid("storyboard.identity.lostHistory") }
                try PlanningValidation.require(current.primaryStepID == old.primaryStepID
                    && current.actionSHA256 == old.actionSHA256 && current.introducedRevision == old.introducedRevision
                    && (old.retiredRevision == nil || current.retiredRevision == old.retiredRevision), "storyboard.identity.reassigned")
                if old.retiredRevision == nil, let retired = current.retiredRevision {
                    try PlanningValidation.require(retired == revision, "storyboard.identity.retiredRevision")
                }
            }
            for added in identity.entries where !priorIDs.contains(added.shotID) {
                try PlanningValidation.require(added.introducedRevision == revision, "storyboard.identity.newRevision")
            }
        } else {
            try PlanningValidation.require(identity.entries.allSatisfy { $0.introducedRevision == 1 }, "storyboard.identity.firstRevision")
        }
    }
}
