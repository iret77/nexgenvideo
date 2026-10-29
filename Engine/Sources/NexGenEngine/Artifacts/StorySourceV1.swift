import Foundation

public struct StorySourceV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "story-source/v1"
    public static let currentPath = "brief/story-source.v1.json"

    public struct Decision: Codable, Sendable, Equatable {
        public enum Disposition: String, Codable, Sendable { case preserve, nonFactual, ownerSuperseded }
        public let id: String
        public let startByte: Int
        public let endByte: Int
        public let excerptSHA256: String
        public let disposition: Disposition
        public let reason: String
        public let confirmationReceipt: CanonicalArtifactReferenceV1

        public init(id: String, startByte: Int, endByte: Int, excerptSHA256: String,
                    disposition: Disposition, reason: String, confirmationReceipt: CanonicalArtifactReferenceV1) {
            self.id = id
            self.startByte = startByte
            self.endByte = endByte
            self.excerptSHA256 = excerptSHA256
            self.disposition = disposition
            self.reason = reason
            self.confirmationReceipt = confirmationReceipt
        }
    }

    public let schema: String
    public let header: PlanningArtifactHeaderV1
    public let source: CanonicalArtifactReferenceV1?
    public let declineReceipt: CanonicalArtifactReferenceV1?
    public let sourceDecisions: [Decision]

    public init(schema: String = schemaVersion, header: PlanningArtifactHeaderV1,
                source: CanonicalArtifactReferenceV1? = nil, declineReceipt: CanonicalArtifactReferenceV1? = nil,
                sourceDecisions: [Decision] = []) {
        self.schema = schema
        self.header = header
        self.source = source
        self.declineReceipt = declineReceipt
        self.sourceDecisions = sourceDecisions
    }

    public func validate(sourceBytes: Data? = nil) throws {
        try PlanningValidation.require(schema == Self.schemaVersion, "storySource.schema")
        try header.validate()
        try PlanningValidation.require((source == nil) != (declineReceipt == nil), "storySource.sourceChoice")
        if let declineReceipt {
            try PlanningValidation.reference(declineReceipt)
            try PlanningValidation.require(sourceDecisions.isEmpty && sourceBytes == nil, "storySource.greenfield")
        }
        if let source {
            try PlanningValidation.reference(source)
            try PlanningValidation.require(source.path == "import/script.md", "storySource.sourcePath")
            guard let sourceBytes, FileDigest.sha256(of: sourceBytes) == source.sha256,
                  String(data: sourceBytes, encoding: .utf8) != nil else {
                throw ProductionPlanningError.invalid("storySource.sourceBytes")
            }
            try PlanningValidation.unique(sourceDecisions.map(\.id), "storySource.decisionIDs")
            for decision in sourceDecisions {
                try PlanningValidation.identifier(decision.id, "storySource.decision.id")
                try PlanningValidation.require(decision.startByte >= 0 && decision.endByte > decision.startByte
                    && decision.endByte <= sourceBytes.count, "storySource.decision.range")
                let excerpt = sourceBytes.subdata(in: decision.startByte..<decision.endByte)
                try PlanningValidation.require(String(data: excerpt, encoding: .utf8) != nil
                    && FileDigest.sha256(of: excerpt) == decision.excerptSHA256, "storySource.decision.excerpt")
                try PlanningValidation.reference(decision.confirmationReceipt)
                try PlanningValidation.text(decision.reason, "storySource.decision.reason")
            }
        }
    }

    public func requireCurrentBytes(dataRoot: URL) throws {
        let bytes = try source.map { try Data(contentsOf: ProjectLocalFile.requireHash($0.sha256, at: $0.path, dataRoot: dataRoot)) }
        try validate(sourceBytes: bytes)
        try header.requireCurrentInputs(dataRoot: dataRoot)
        for receipt in [declineReceipt].compactMap({ $0 }) + sourceDecisions.map(\.confirmationReceipt) {
            _ = try ProjectLocalFile.requireHash(receipt.sha256, at: receipt.path, dataRoot: dataRoot)
        }
    }
}

public struct PlaybackRangeV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "playback-range/v1"
    public static let currentPath = "brief/playback-range.v1.json"
    public enum Kind: String, Codable, Sendable { case fullSong, excerpt }

    public let schema: String
    public let header: PlanningArtifactHeaderV1
    public let kind: Kind
    public let analysis: CanonicalArtifactReferenceV1
    public let timebase: RationalTimebaseV1
    public let audioDurationTicks: Int64
    public let startTicks: Int64
    public let durationTicks: Int64
    public let selectionReceipt: CanonicalArtifactReferenceV1?

    public init(schema: String = schemaVersion, header: PlanningArtifactHeaderV1, kind: Kind,
                analysis: CanonicalArtifactReferenceV1, timebase: RationalTimebaseV1,
                audioDurationTicks: Int64, startTicks: Int64, durationTicks: Int64,
                selectionReceipt: CanonicalArtifactReferenceV1? = nil) {
        self.schema = schema
        self.header = header
        self.kind = kind
        self.analysis = analysis
        self.timebase = timebase
        self.audioDurationTicks = audioDurationTicks
        self.startTicks = startTicks
        self.durationTicks = durationTicks
        self.selectionReceipt = selectionReceipt
    }

    public func validate() throws {
        try PlanningValidation.require(schema == Self.schemaVersion, "playbackRange.schema")
        try header.validate()
        try timebase.validate()
        try PlanningValidation.reference(analysis)
        let end = try PlanningValidation.end(start: startTicks, duration: durationTicks)
        try PlanningValidation.require(audioDurationTicks > 0 && end <= audioDurationTicks, "playbackRange.interval")
        if kind == .fullSong {
            try PlanningValidation.require(startTicks == 0 && durationTicks == audioDurationTicks
                && selectionReceipt == nil, "playbackRange.fullSong")
        } else {
            guard let selectionReceipt else { throw ProductionPlanningError.invalid("playbackRange.selectionReceipt") }
            try PlanningValidation.reference(selectionReceipt)
        }
    }
}
