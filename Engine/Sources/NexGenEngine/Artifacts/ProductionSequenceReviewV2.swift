import Foundation

public struct ProductionSequenceEDLV2: Codable, Sendable, Equatable {
    public struct Clip: Codable, Sendable, Equatable {
        public let trackID: String
        public let clipID: String
        public let shotID: String?
        public let mediaID: String?
        public let source: CanonicalArtifactReferenceV1?
        public let startFrame: Int
        public let durationFrames: Int
        public let sourceStartFrame: Int
        public let speed: Double

        public init(trackID: String, clipID: String, shotID: String?, mediaID: String?, source: CanonicalArtifactReferenceV1?,
                    startFrame: Int, durationFrames: Int, sourceStartFrame: Int, speed: Double) {
            self.trackID = trackID; self.clipID = clipID; self.shotID = shotID; self.mediaID = mediaID; self.source = source
            self.startFrame = startFrame; self.durationFrames = durationFrames; self.sourceStartFrame = sourceStartFrame; self.speed = speed
        }
    }
    public let schema: String
    public let projectID: String
    public let timelineSHA256: String
    public let timebase: RationalTimebaseV1
    public let outputStartTicks: Int64
    public let outputDurationTicks: Int64
    public let clips: [Clip]
    public let cutFrames: [Int]

    public init(projectID: String, timelineSHA256: String, timebase: RationalTimebaseV1, outputStartTicks: Int64,
                outputDurationTicks: Int64, clips: [Clip], cutFrames: [Int]) {
        schema = "production-sequence-edl/v2"; self.projectID = projectID; self.timelineSHA256 = timelineSHA256
        self.timebase = timebase; self.outputStartTicks = outputStartTicks; self.outputDurationTicks = outputDurationTicks
        self.clips = clips; self.cutFrames = cutFrames
    }
}

public struct ProductionSequenceReviewV2: Codable, Sendable, Equatable {
    public struct FindingResolution: Codable, Sendable, Equatable {
        public let findingID: String
        public let reason: String
        public init(findingID: String, reason: String) { self.findingID = findingID; self.reason = reason }
    }
    public static let relativePath = "reviews/sequence/current.v2.json"
    public let schema: String
    public let projectID: String
    public let assembly: CanonicalArtifactReferenceV1
    public let projection: CanonicalArtifactReferenceV1
    public let inputFingerprint: String
    public let timeline: CanonicalArtifactReferenceV1
    public let edl: CanonicalArtifactReferenceV1
    public let reel: CanonicalArtifactReferenceV1
    public let reelByteCount: Int64
    public let durationFrames: Int
    public let cutFrames: [Int]
    public let inputs: [CanonicalArtifactReferenceV1]
    public let adjacentPairCompleted: Bool
    public let wholePlaybackCompleted: Bool
    public let findings: [SequenceReviewFindingV1]
    public let reviewedAt: String
    public let musicCoverage: [ProductionMusicCoverageObservationV2]
    public let findingResolutions: [FindingResolution]
    public let supersedes: CanonicalArtifactReferenceV1?

    public init(projectID: String, assembly: CanonicalArtifactReferenceV1, projection: CanonicalArtifactReferenceV1,
                inputFingerprint: String, timeline: CanonicalArtifactReferenceV1, edl: CanonicalArtifactReferenceV1,
                reel: CanonicalArtifactReferenceV1, reelByteCount: Int64, durationFrames: Int, cutFrames: [Int],
                inputs: [CanonicalArtifactReferenceV1], adjacentPairCompleted: Bool, wholePlaybackCompleted: Bool,
                findings: [SequenceReviewFindingV1], reviewedAt: String,
                musicCoverage: [ProductionMusicCoverageObservationV2] = [], findingResolutions: [FindingResolution] = [],
                supersedes: CanonicalArtifactReferenceV1? = nil) {
        schema = "production-sequence-review/v2"; self.projectID = projectID; self.assembly = assembly; self.projection = projection
        self.inputFingerprint = inputFingerprint; self.timeline = timeline; self.edl = edl; self.reel = reel
        self.reelByteCount = reelByteCount; self.durationFrames = durationFrames; self.cutFrames = cutFrames; self.inputs = inputs
        self.adjacentPairCompleted = adjacentPairCompleted; self.wholePlaybackCompleted = wholePlaybackCompleted
        self.findings = findings; self.reviewedAt = reviewedAt; self.musicCoverage = musicCoverage
        self.findingResolutions = findingResolutions; self.supersedes = supersedes
    }

    public var artifactReferences: [CanonicalArtifactReferenceV1] { inputs + [assembly, projection, timeline, edl, reel] + [supersedes].compactMap { $0 } }

    public func validate(edl actual: ProductionSequenceEDLV2, shotIDs: Set<String>, rejectBlocking: Bool,
                         musicRequirements: [ProductionMusicCoverageRequirementV2] = []) throws {
        try actual.timebase.validate()
        try PlanningValidation.require(schema == "production-sequence-review/v2" && actual.schema == "production-sequence-edl/v2"
            && projectID == actual.projectID && !projectID.isEmpty && !reviewedAt.isEmpty && reelByteCount > 0, "sequenceReview.identity")
        try PlanningValidation.hash(inputFingerprint, "sequenceReview.inputs")
        try PlanningValidation.hash(actual.timelineSHA256, "sequenceReview.timeline")
        try PlanningValidation.require(timeline.sha256 == actual.timelineSHA256 && durationFrames > 0
            && Int64(durationFrames) == ProductionPlanAssemblyV1.coveringFrameCount(for: actual.outputDurationTicks, timebase: actual.timebase)
            && actual.outputStartTicks >= 0 && cutFrames == actual.cutFrames
            && cutFrames == Array(Set(cutFrames)).sorted() && cutFrames.allSatisfy { $0 > 0 && $0 < durationFrames }, "sequenceReview.range")
        for ref in artifactReferences { try PlanningValidation.reference(ref) }
        try PlanningValidation.require(reel.path.hasPrefix("reviews/sequence/reels/") && timeline.path.hasPrefix("reviews/sequence/reels/")
            && edl.path.hasPrefix("reviews/sequence/reels/"), "sequenceReview.paths")
        try PlanningValidation.unique(actual.clips.map(\.clipID), "sequenceReview.clips")
        for clip in actual.clips {
            try PlanningValidation.require(clip.startFrame >= 0 && clip.durationFrames > 0 && clip.sourceStartFrame >= 0
                && clip.speed.isFinite && clip.speed > 0 && (clip.shotID.map { shotIDs.contains($0) } ?? true)
                && ((clip.source == nil) == (clip.mediaID == nil)), "sequenceReview.clip")
            if let source = clip.source {
                try PlanningValidation.reference(source)
                try PlanningValidation.require(inputs.contains { $0.path == source.path && $0.sha256 == source.sha256 }, "sequenceReview.sourceBinding")
            }
        }
        try PlanningValidation.require(wholePlaybackCompleted && (cutFrames.isEmpty || adjacentPairCompleted), "sequenceReview.incomplete")
        try PlanningValidation.unique(findings.map(\.id), "sequenceReview.findings")
        for finding in findings {
            try PlanningValidation.identifier(finding.id, "sequenceReview.findingID")
            try PlanningValidation.text(finding.evidence, "sequenceReview.observation")
            try PlanningValidation.require(Set(finding.shotIDs).isSubset(of: shotIDs)
                && finding.startFrame >= 0 && finding.endFrame > finding.startFrame && finding.endFrame <= durationFrames
                && finding.provenance.kind == .nativeUser && finding.provenance.reviewerID == "native-sequence-review"
                && finding.provenance.modelID == nil && finding.provenance.promptPath == nil && finding.provenance.promptSHA256 == nil
                && finding.provenance.responsePath == nil && finding.provenance.responseSHA256 == nil
                && (finding.severity != .blocking || finding.recommendedAction != .accept), "sequenceReview.finding")
            if finding.scope == .adjacentPair {
                try PlanningValidation.require(cutFrames.contains { finding.startFrame <= $0 && finding.endFrame > $0 }, "sequenceReview.cutFinding")
            }
        }
        try ProductionMusicCoverageObservationV2.validate(musicCoverage, requirements: musicRequirements,
            edl: actual, durationFrames: durationFrames, rejectBlocking: rejectBlocking)
        try PlanningValidation.unique(findingResolutions.map(\.findingID), "sequenceReview.resolutions")
        for resolution in findingResolutions {
            try PlanningValidation.text(resolution.reason, "sequenceReview.resolutionReason")
            try PlanningValidation.require(findings.contains { $0.id == resolution.findingID && $0.severity == .blocking }, "sequenceReview.resolutionFinding")
        }
        if rejectBlocking {
            let resolved = Set(findingResolutions.map(\.findingID))
            try PlanningValidation.require(!findings.contains { $0.severity == .blocking && !resolved.contains($0.id) }, "sequenceReview.blocking")
        }
    }
}
