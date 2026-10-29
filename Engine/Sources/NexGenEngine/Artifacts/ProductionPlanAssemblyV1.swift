import Foundation

public typealias ProductionPlanAssemblyEvidenceVerifierV1 = @Sendable (ProductionPlanAssemblyProofV1, URL) throws -> Void

public struct ProductionPlanAssemblyProofV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "production-plan-assembly/v1"
    public static let relativePath = "execution/extensions/production-plan-assembly.v1.json"

    public struct Placement: Codable, Sendable, Equatable {
        public let shotID: String
        public let trackID: String
        public let clipID: String
        public let output: CanonicalArtifactReferenceV1
        public let sourceKind: TimelineAssemblyProofV1.Placement.SourceKind
        public let startTicks: Int64
        public let durationTicks: Int64
        public let sourceInTicks: Int64
        public let decodedDurationTicks: Int64?
        public let motion: TimelineAssemblyProofV1.Placement.Motion?
        public let takeID: String?
        public let selectionReceipt: CanonicalArtifactReferenceV1?
        public let submissionBinding: CanonicalArtifactReferenceV1?
        public let deliveryProof: CanonicalArtifactReferenceV1?
        public let nativeRange: CanonicalArtifactReferenceV1?
        public let sourceTimebase: SourceMediaTimebaseV1?

        public init(shotID: String, trackID: String, clipID: String, output: CanonicalArtifactReferenceV1,
                    sourceKind: TimelineAssemblyProofV1.Placement.SourceKind, startTicks: Int64,
                    durationTicks: Int64, sourceInTicks: Int64 = 0, decodedDurationTicks: Int64? = nil,
                    motion: TimelineAssemblyProofV1.Placement.Motion? = nil, takeID: String? = nil,
                    selectionReceipt: CanonicalArtifactReferenceV1? = nil, submissionBinding: CanonicalArtifactReferenceV1? = nil,
                    deliveryProof: CanonicalArtifactReferenceV1? = nil, nativeRange: CanonicalArtifactReferenceV1? = nil,
                    sourceTimebase: SourceMediaTimebaseV1? = nil) {
            self.shotID = shotID
            self.trackID = trackID
            self.clipID = clipID
            self.output = output
            self.sourceKind = sourceKind
            self.startTicks = startTicks
            self.durationTicks = durationTicks
            self.sourceInTicks = sourceInTicks
            self.decodedDurationTicks = decodedDurationTicks
            self.motion = motion
            self.takeID = takeID
            self.selectionReceipt = selectionReceipt
            self.submissionBinding = submissionBinding
            self.deliveryProof = deliveryProof
            self.nativeRange = nativeRange
            self.sourceTimebase = sourceTimebase
        }
    }

    public struct AudioPlacement: Codable, Sendable, Equatable {
        public let trackID: String
        public let clipID: String
        public let source: CanonicalArtifactReferenceV1
        public let startTicks: Int64
        public let sourceInTicks: Int64
        public let durationTicks: Int64

        public init(trackID: String, clipID: String, source: CanonicalArtifactReferenceV1,
                    startTicks: Int64, sourceInTicks: Int64, durationTicks: Int64) {
            self.trackID = trackID
            self.clipID = clipID
            self.source = source
            self.startTicks = startTicks
            self.sourceInTicks = sourceInTicks
            self.durationTicks = durationTicks
        }
    }

    public let schema: String
    public let header: PlanningArtifactHeaderV1
    public let productionPlan: CanonicalArtifactReferenceV1
    public let renderReview: CanonicalArtifactReferenceV1
    public let timebase: RationalTimebaseV1
    public let placements: [Placement]
    public let audio: AudioPlacement?
    public let outputRange: PlaybackRangeV1?

    public init(schema: String = schemaVersion, header: PlanningArtifactHeaderV1,
                productionPlan: CanonicalArtifactReferenceV1, renderReview: CanonicalArtifactReferenceV1,
                timebase: RationalTimebaseV1, placements: [Placement], audio: AudioPlacement? = nil,
                outputRange: PlaybackRangeV1? = nil) {
        self.schema = schema
        self.header = header
        self.productionPlan = productionPlan
        self.renderReview = renderReview
        self.timebase = timebase
        self.placements = placements
        self.audio = audio
        self.outputRange = outputRange
    }

    public var artifactReferences: [CanonicalArtifactReferenceV1] {
        header.inputs + [productionPlan, renderReview] + placements.flatMap {
            [$0.output] + [$0.selectionReceipt, $0.submissionBinding, $0.deliveryProof, $0.nativeRange].compactMap { $0 }
        } + [audio?.source].compactMap { $0 }
            + (outputRange.map { $0.header.inputs + [$0.analysis] + [$0.selectionReceipt].compactMap { $0 } } ?? [])
    }
}

public enum ProductionPlanAssemblyV1 {
    public struct OutputInterval: Sendable, Equatable {
        public let startTicks: Int64
        public let durationTicks: Int64
    }

    public static func outputInterval(proof: ProductionPlanAssemblyProofV1, timing: StoryboardTimingV1) throws -> OutputInterval {
        if let range = proof.outputRange {
            try range.validate()
            try PlanningValidation.require(range.header.projectID == proof.header.projectID
                && range.header.projectID == timing.header.projectID && range.timebase == proof.timebase
                && range.timebase == timing.timebase
                && proof.header.inputs.contains { $0.path == PlaybackRangeV1.currentPath }, "assembly.outputRangeBinding")
            try PlanningValidation.require(range.header.inputs.contains(range.analysis)
                && (range.selectionReceipt == nil || range.header.inputs.contains(range.selectionReceipt!)), "assembly.outputRangeInputs")
            if timing.mode == .multicam {
                try PlanningValidation.require(timing.rangeStartTicks == 0 && timing.rangeDurationTicks == range.audioDurationTicks
                    && timing.audio?.offsetTicks == 0 && timing.audio?.durationTicks == range.audioDurationTicks,
                                               "assembly.multicamFullSong")
                if let audio = timing.audio {
                    try PlanningValidation.require(range.header.inputs.contains(audio.source), "assembly.outputRangeAudio")
                }
            } else {
                try PlanningValidation.require(range.startTicks == timing.rangeStartTicks
                    && range.durationTicks == timing.rangeDurationTicks, "assembly.outputRangeMatchesPlanning")
            }
            return OutputInterval(startTicks: range.startTicks, durationTicks: range.durationTicks)
        }
        try PlanningValidation.require(timing.mode != .multicam, "assembly.multicamOutputRange")
        _ = try PlanningValidation.end(start: timing.rangeStartTicks, duration: timing.rangeDurationTicks)
        return OutputInterval(startTicks: timing.rangeStartTicks, durationTicks: timing.rangeDurationTicks)
    }

    public static func validate(_ proof: ProductionPlanAssemblyProofV1, projection: ProductionPlanProjectionV1,
                                timing: StoryboardTimingV1) throws {
        try ProductionPlanProjectionValidatorV1.validate(projection)
        try proof.header.validate()
        try proof.timebase.validate()
        try PlanningValidation.require(proof.schema == ProductionPlanAssemblyProofV1.schemaVersion
            && proof.header.projectID == projection.header.projectID && proof.timebase == projection.timebase
            && proof.timebase == timing.timebase && timing.header.projectID == proof.header.projectID,
                                       "assembly.header")
        try PlanningValidation.require(proof.productionPlan.path == ProductionPlanProjectionV1.versionPath(projection.header.revision)
            && proof.placements.map(\.shotID) == projection.shots.map(\.id)
            && projection.timings.map(\.shotID) == timing.shots.map(\.id), "assembly.shotCoverage")
        for ref in [proof.productionPlan, proof.renderReview] {
            try PlanningValidation.reference(ref)
            try PlanningValidation.require(proof.header.inputs.contains(ref), "assembly.approvedInputBinding")
        }
        try PlanningValidation.unique(proof.placements.map(\.clipID) + [proof.audio?.clipID].compactMap { $0 }, "assembly.clipIDs")
        for ((placement, shot), planned) in zip(zip(proof.placements, projection.shots), timing.shots) {
            guard let editorial = projection.timing(for: shot.id) else { throw ProductionPlanningError.invalid("assembly.timing") }
            try PlanningValidation.text(placement.trackID, "assembly.trackID")
            try PlanningValidation.reference(placement.output)
            try PlanningValidation.require(placement.startTicks == editorial.startTicks && placement.durationTicks == editorial.durationTicks
                && editorial.startTicks == planned.startTicks && editorial.durationTicks == planned.durationTicks, "assembly.exactTiming")
            if let nativeRange = placement.nativeRange {
                try PlanningValidation.reference(nativeRange)
                try PlanningValidation.require(shot.sourceMode != .imported && ShotDeliveryModeResolverV1.resolve(shot) == .providerVideo
                    && placement.sourceTimebase != nil && placement.takeID != nil && placement.selectionReceipt != nil
                    && proof.header.inputs.contains { $0.path == nativeRange.path && $0.sha256 == nativeRange.sha256 }, "assembly.nativeRangeBinding")
            } else {
                try PlanningValidation.require(placement.sourceTimebase == nil && placement.sourceInTicks == editorial.sourceInTicks, "assembly.exactSourceRange")
            }
            _ = try frameIndex(for: placement.startTicks, timebase: proof.timebase)
            let placementEnd = try PlanningValidation.end(start: placement.startTicks, duration: placement.durationTicks)
            let rangeEnd = try PlanningValidation.end(start: timing.rangeStartTicks, duration: timing.rangeDurationTicks)
            if placementEnd == rangeEnd { _ = try coveringFrameCount(for: placement.durationTicks, timebase: proof.timebase) }
            else { _ = try frameIndex(for: placement.durationTicks, timebase: proof.timebase) }
            if placement.nativeRange == nil { _ = try frameIndex(for: placement.sourceInTicks, timebase: proof.timebase) }
            let still = ShotDeliveryModeResolverV1.resolve(shot) == .timelineAnimatedStill
            try PlanningValidation.require((placement.sourceKind == .stillImage) == still, "assembly.deliveryMode")
            if still {
                guard let motion = placement.motion else { throw ProductionPlanningError.invalid("assembly.stillMotion") }
                try PlanningValidation.require(motion.kind == .kenBurnsZoom && motion.startScale == 1
                    && motion.endScale.isFinite && motion.endScale > motion.startScale
                    && placement.sourceInTicks == 0 && placement.decodedDurationTicks == nil, "assembly.stillMotion")
            } else {
                guard let duration = placement.decodedDurationTicks else { throw ProductionPlanningError.invalid("assembly.decodedDuration") }
                if let sourceClock = placement.sourceTimebase {
                    try sourceClock.validate()
                    try PlanningValidation.require(placement.sourceInTicks >= 0 && duration > placement.sourceInTicks
                        && placement.motion == nil, "assembly.nativeSourceRange")
                    let remaining = duration - placement.sourceInTicks
                    try PlanningValidation.require(atLeast(remaining, scale: sourceClock.ticksPerSecond,
                        placement.durationTicks, scale: proof.timebase.ticksPerSecond), "assembly.nativeSourceCoverage")
                } else {
                    let end = try PlanningValidation.end(start: placement.sourceInTicks, duration: placement.durationTicks)
                    try PlanningValidation.require(placement.motion == nil && duration >= end
                        && duration >= (editorial.nativeDurationTicks ?? end), "assembly.sourceRange")
                }
            }
            if shot.sourceMode == .imported {
                try PlanningValidation.require(projection.source(for: shot.id) == placement.output && placement.takeID == nil
                    && placement.selectionReceipt == nil && placement.submissionBinding == nil && placement.deliveryProof == nil,
                                               "assembly.importedSource")
            } else {
                try PlanningValidation.hash(placement.takeID ?? "", "assembly.selectedTakeID")
                guard let receipt = placement.selectionReceipt else {
                    throw ProductionPlanningError.invalid("assembly.hostTakeEvidence")
                }
                try PlanningValidation.reference(receipt)
                if still {
                    guard let original = placement.deliveryProof else { throw ProductionPlanningError.invalid("assembly.stillDeliveryProof") }
                    try PlanningValidation.reference(original)
                    try PlanningValidation.require(placement.submissionBinding == nil, "assembly.noStillRegeneration")
                } else {
                    guard let binding = placement.submissionBinding else { throw ProductionPlanningError.invalid("assembly.submissionBinding") }
                    try PlanningValidation.reference(binding)
                    if let delivery = placement.deliveryProof { try PlanningValidation.reference(delivery) }
                }
            }
        }
        if projection.mode == .multicam {
            try PlanningValidation.unique(proof.placements.map(\.trackID), "assembly.multicamTracks")
        }
        _ = try outputInterval(proof: proof, timing: timing)
        try validateAudio(proof, timing: timing)
    }

    private static func atLeast(_ left: Int64, scale leftScale: Int64, _ right: Int64, scale rightScale: Int64) -> Bool {
        guard left >= 0, right >= 0, leftScale > 0, rightScale > 0 else { return false }
        let leftWhole = left / leftScale, rightWhole = right / rightScale
        if leftWhole != rightWhole { return leftWhole > rightWhole }
        return (left % leftScale) * rightScale >= (right % rightScale) * leftScale
    }

    public static func frameIndex(for ticks: Int64, timebase: RationalTimebaseV1) throws -> Int64 {
        try timebase.validate()
        let frameTicks = timebase.ticksPerSecond * timebase.fpsDenominator / timebase.fpsNumerator
        try PlanningValidation.require(ticks >= 0 && frameTicks > 0 && ticks % frameTicks == 0, "assembly.frameBoundary")
        return ticks / frameTicks
    }

    public static func coveringFrameCount(for ticks: Int64, timebase: RationalTimebaseV1) throws -> Int64 {
        try timebase.validate()
        let frameTicks = timebase.ticksPerSecond * timebase.fpsDenominator / timebase.fpsNumerator
        try PlanningValidation.require(ticks > 0 && frameTicks > 0, "assembly.frameCoverage")
        let count = ticks / frameTicks
        return count + (ticks % frameTicks == 0 ? 0 : 1)
    }

    @discardableResult
    public static func requireCurrent(projection: ProductionPlanProjectionV1, dataRoot: URL,
                                      evidenceVerifier: ProductionPlanAssemblyEvidenceVerifierV1? = nil) throws -> ProductionPlanAssemblyProofV1 {
        guard let evidenceVerifier else { throw ProductionPlanningError.invalid("assembly.hostEvidenceVerifier") }
        let planning = try ProductionPlanFilesV1.planningInputs(projection, dataRoot: dataRoot)
        let ownRef = try ProductionPlanFilesV1.reference(ProductionPlanAssemblyProofV1.relativePath, dataRoot: dataRoot)
        let proof = try JSONDecoder().decode(ProductionPlanAssemblyProofV1.self,
            from: Data(contentsOf: ProjectLocalFile.resolve(ownRef.path, dataRoot: dataRoot)))
        try validate(proof, projection: projection, timing: planning.timing)
        try requireOutputRangeBytes(proof, dataRoot: dataRoot)
        let refs = try ProductionPlanFilesV1.unique(planning.references + proof.artifactReferences + [ownRef])
        try ProductionPlanFilesV1.require(refs, dataRoot: dataRoot)
        try evidenceVerifier(proof, dataRoot)
        try ProductionPlanFilesV1.require(refs, dataRoot: dataRoot)
        return proof
    }

    public static func artifactReferences(projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        let planning = try ProductionPlanFilesV1.planningInputs(projection, dataRoot: dataRoot)
        let ownRef = try ProductionPlanFilesV1.reference(ProductionPlanAssemblyProofV1.relativePath, dataRoot: dataRoot)
        let proof = try JSONDecoder().decode(ProductionPlanAssemblyProofV1.self,
            from: Data(contentsOf: ProjectLocalFile.resolve(ownRef.path, dataRoot: dataRoot)))
        try validate(proof, projection: projection, timing: planning.timing)
        try requireOutputRangeBytes(proof, dataRoot: dataRoot)
        let refs = try ProductionPlanFilesV1.unique(planning.references + proof.artifactReferences + [ownRef])
        try ProductionPlanFilesV1.require(refs, dataRoot: dataRoot)
        return refs
    }

    private static func requireOutputRangeBytes(_ proof: ProductionPlanAssemblyProofV1, dataRoot: URL) throws {
        let path = PlaybackRangeV1.currentPath
        if let range = proof.outputRange {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
            let stored = try JSONDecoder().decode(PlaybackRangeV1.self, from: bytes)
            try PlanningValidation.require(stored == range && proof.header.inputs.contains {
                $0.path == path && $0.sha256 == FileDigest.sha256(of: bytes)
            }, "assembly.currentOutputRange")
            try range.header.requireCurrentInputs(dataRoot: dataRoot)
        } else {
            let candidate = dataRoot.appendingPathComponent(path)
            try PlanningValidation.require(!FileManager.default.fileExists(atPath: candidate.path)
                && (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) == nil,
                                           "assembly.missingNativeOutputRange")
        }
    }

    private static func validateAudio(_ proof: ProductionPlanAssemblyProofV1, timing: StoryboardTimingV1) throws {
        guard let source = timing.audio else {
            try PlanningValidation.require(proof.audio == nil, "assembly.unplannedAudio")
            return
        }
        let rangeEnd = try PlanningValidation.end(start: timing.rangeStartTicks, duration: timing.rangeDurationTicks)
        let audioEnd = source.offsetTicks.addingReportingOverflow(source.durationTicks)
        try PlanningValidation.require(!audioEnd.overflow, "assembly.audioOverflow")
        let start = max(timing.rangeStartTicks, source.offsetTicks), end = min(rangeEnd, audioEnd.partialValue)
        if start >= end {
            try PlanningValidation.require(proof.audio == nil, "assembly.silentRange")
            return
        }
        guard let audio = proof.audio, let sourceIn = source.sourceTick(atTimelineTick: start) else {
            throw ProductionPlanningError.invalid("assembly.missingAudio")
        }
        try PlanningValidation.text(audio.trackID, "assembly.audioTrack")
        try PlanningValidation.require(!proof.placements.contains { $0.trackID == audio.trackID }
            && audio.source == source.source && audio.startTicks == start && audio.sourceInTicks == sourceIn
            && audio.durationTicks == end - start, "assembly.exactAudioRange")
    }
}
