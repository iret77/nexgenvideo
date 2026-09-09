import Foundation

public enum ShotDeliveryModeV1: String, Codable, Sendable, Equatable {
    case providerVideo = "provider_video"
    case timelineAnimatedStill = "timeline_animated_still"
}

public enum ShotDeliveryModeResolverV1 {
    public static let timelineAnimatedStillModeID = "timeline_animated_still"

    public static func resolve(_ shot: ExecutionShotV1) -> ShotDeliveryModeV1? {
        guard shot.sourceMode != .imported else { return nil }
        guard let requirement = shot.generationRequirement else { return nil }
        if requirement.modalityID == "video" {
            return .providerVideo
        }
        if shot.sourceMode == .generated,
           requirement.modalityID == "image",
           requirement.modeIDs == [timelineAnimatedStillModeID],
           !requirement.requiresOutputAudio,
           requirement.sourceVideoAssetID == nil {
            return .timelineAnimatedStill
        }
        return nil
    }

    public static func stillShotIDs(in plan: ExecutionPlanV1) -> Set<String> {
        Set(plan.shots.compactMap {
            resolve($0) == .timelineAnimatedStill ? $0.id : nil
        })
    }
}

public struct StillImageDeliveryProofV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "still-image-delivery-proof/v1"

    public let schema: String
    public let shotID: String
    public let outputPath: String
    public let outputSHA256: String

    private enum CodingKeys: String, CodingKey {
        case schema
        case shotID = "shot_id"
        case outputPath = "output_path"
        case outputSHA256 = "output_sha256"
    }

    public init(shotID: String, outputPath: String, outputSHA256: String) {
        schema = Self.schemaVersion
        self.shotID = shotID
        self.outputPath = outputPath
        self.outputSHA256 = outputSHA256
    }
}

public struct TimelineAssemblyProofV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "timeline-assembly-proof/v1"

    public struct Placement: Codable, Sendable, Equatable {
        public enum SourceKind: String, Codable, Sendable, Equatable {
            case video
            case stillImage = "still_image"
        }

        public struct Motion: Codable, Sendable, Equatable {
            public enum Kind: String, Codable, Sendable, Equatable {
                case kenBurnsZoom = "ken_burns_zoom"
            }

            public let kind: Kind
            public let startScale: Double
            public let endScale: Double

            private enum CodingKeys: String, CodingKey {
                case kind
                case startScale = "start_scale"
                case endScale = "end_scale"
            }

            public init(kind: Kind, startScale: Double, endScale: Double) {
                self.kind = kind
                self.startScale = startScale
                self.endScale = endScale
            }
        }

        public let shotID: String
        public let clipID: String
        public let sourcePath: String
        public let sourceSHA256: String
        public let sourceKind: SourceKind
        public let startFrame: Int
        public let durationFrames: Int
        public let motion: Motion?

        private enum CodingKeys: String, CodingKey {
            case shotID = "shot_id"
            case clipID = "clip_id"
            case sourcePath = "source_path"
            case sourceSHA256 = "source_sha256"
            case sourceKind = "source_kind"
            case startFrame = "start_frame"
            case durationFrames = "duration_frames"
            case motion
        }

        public init(
            shotID: String,
            clipID: String,
            sourcePath: String,
            sourceSHA256: String,
            sourceKind: SourceKind,
            startFrame: Int,
            durationFrames: Int,
            motion: Motion?
        ) {
            self.shotID = shotID
            self.clipID = clipID
            self.sourcePath = sourcePath
            self.sourceSHA256 = sourceSHA256
            self.sourceKind = sourceKind
            self.startFrame = startFrame
            self.durationFrames = durationFrames
            self.motion = motion
        }
    }

    public let schema: String
    public let project: String
    public let phase: String
    public let timelineFPS: Int
    public let videoTrackID: String
    public let audioTrackID: String?
    public let generatedAt: String
    public let placements: [Placement]

    private enum CodingKeys: String, CodingKey {
        case schema
        case project
        case phase
        case timelineFPS = "timeline_fps"
        case videoTrackID = "video_track_id"
        case audioTrackID = "audio_track_id"
        case generatedAt = "generated_at"
        case placements
    }

    public init(
        project: String,
        phase: String,
        timelineFPS: Int,
        videoTrackID: String,
        audioTrackID: String?,
        generatedAt: String,
        placements: [Placement]
    ) {
        schema = Self.schemaVersion
        self.project = project
        self.phase = phase
        self.timelineFPS = timelineFPS
        self.videoTrackID = videoTrackID
        self.audioTrackID = audioTrackID
        self.generatedAt = generatedAt
        self.placements = placements
    }
}

public enum TimelineAssemblyProofValidationErrorV1: Error, Sendable, Equatable {
    case invalidIdentity
    case invalidPlacement(String)
}

public enum TimelineAssemblyProofValidatorV1 {
    public static func validate(_ proof: TimelineAssemblyProofV1) throws {
        guard proof.schema == TimelineAssemblyProofV1.schemaVersion,
              !proof.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !proof.phase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              proof.timelineFPS > 0,
              !proof.videoTrackID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(proof.placements.map(\.shotID)).count == proof.placements.count,
              Set(proof.placements.map(\.clipID)).count == proof.placements.count else {
            throw TimelineAssemblyProofValidationErrorV1.invalidIdentity
        }
        for placement in proof.placements {
            let validMotion: Bool
            switch placement.sourceKind {
            case .video:
                validMotion = placement.motion == nil
            case .stillImage:
                validMotion = placement.motion.map {
                    $0.kind == .kenBurnsZoom
                        && $0.startScale == 1
                        && $0.endScale > $0.startScale
                } == true
            }
            guard !placement.shotID.isEmpty,
                  !placement.clipID.isEmpty,
                  !placement.sourcePath.isEmpty,
                  placement.sourceSHA256.count == 64,
                  placement.sourceSHA256.allSatisfy(\.isHexDigit),
                  placement.startFrame >= 0,
                  placement.durationFrames > 0,
                  validMotion else {
                throw TimelineAssemblyProofValidationErrorV1.invalidPlacement(
                    placement.shotID
                )
            }
        }
    }
}
