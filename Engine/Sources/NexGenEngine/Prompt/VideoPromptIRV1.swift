import Foundation

public let videoPromptIRV1Schema = "video-prompt-ir/v1"

public enum VideoPromptReferenceModalityV1: String, Codable, Sendable, Equatable {
    case image
    case video
    case audio
    case geometry
}

public enum VideoPromptReferenceRoleV1: String, Codable, Sendable, Equatable {
    case character
    case location
    case prop
    case style
    case lighting
    case motion
    case audioTiming = "audio_timing"
    case voice
    case startFrame = "start_frame"
    case endFrame = "end_frame"
    case sourceVideo = "source_video"
    case other
}

public struct VideoPromptReferenceV1: Codable, Sendable, Equatable {
    public let planIndex: Int
    public let modalityIndex: Int
    public let modality: VideoPromptReferenceModalityV1
    public let role: VideoPromptReferenceRoleV1
    public let semanticJobID: String
    public let assetID: String
    public let entityID: String?
    public let stateID: String?
    public let viewID: String?
    public let preservationScopeIDs: [String]

    public init(
        planIndex: Int,
        modalityIndex: Int,
        modality: VideoPromptReferenceModalityV1,
        role: VideoPromptReferenceRoleV1,
        semanticJobID: String,
        assetID: String,
        entityID: String? = nil,
        stateID: String? = nil,
        viewID: String? = nil,
        preservationScopeIDs: [String] = []
    ) {
        self.planIndex = planIndex
        self.modalityIndex = modalityIndex
        self.modality = modality
        self.role = role
        self.semanticJobID = semanticJobID
        self.assetID = assetID
        self.entityID = entityID
        self.stateID = stateID
        self.viewID = viewID
        self.preservationScopeIDs = preservationScopeIDs
    }

    public var providerLabel: String {
        switch modality {
        case .image: "@Image\(modalityIndex)"
        case .video: "@Video\(modalityIndex)"
        case .audio: "@Audio\(modalityIndex)"
        case .geometry: "@Clay Render\(modalityIndex)"
        }
    }

    public var identityLabel: String {
        var parts = [entityID, stateID, viewID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.isEmpty { parts = [semanticJobID] }
        return parts.joined(separator: " / ")
    }
}

public struct VideoPromptIRV1: Codable, Sendable, Equatable {
    public let schema: String
    public let subject: String
    public let startState: String
    public let endState: String
    public let setting: String
    public let composition: String
    public let camera: String
    public let style: String
    public let light: String
    public let exclusions: [String]
    public let durationSeconds: Double?
    public let aspectRatio: String
    public let shotCount: Int
    public let directives: [String]
    public let temporalStructure: String
    public let blocking: [String]
    public let timedActionBeats: [TimedActionBeatV1]
    public let continuityLocks: [String]
    public let transitionIntent: String?
    public let modeID: String
    public let references: [VideoPromptReferenceV1]

    public init(
        schema: String = videoPromptIRV1Schema,
        payload: PromptPayload,
        modeID: String,
        references: [VideoPromptReferenceV1],
        startState: String = "",
        endState: String = "",
        blocking: [String] = [],
        timedActionBeats: [TimedActionBeatV1] = [],
        continuityLocks: [String] = [],
        transitionIntent: String? = nil
    ) {
        self.schema = schema
        subject = payload.subject
        self.startState = startState
        self.endState = endState
        setting = payload.setting
        composition = payload.composition
        camera = payload.camera
        style = payload.style
        light = payload.light
        exclusions = payload.negatives
        durationSeconds = payload.durationS
        aspectRatio = payload.aspectRatio
        shotCount = payload.nShots
        directives = payload.directives
        temporalStructure = payload.temporalStructure
        self.blocking = blocking
        self.timedActionBeats = timedActionBeats
        self.continuityLocks = continuityLocks
        self.transitionIntent = transitionIntent
        self.modeID = modeID
        self.references = references
    }

    public var payload: PromptPayload {
        PromptPayload(
            subject: subject,
            setting: setting,
            composition: composition,
            camera: camera,
            style: style,
            light: light,
            negatives: exclusions,
            durationS: durationSeconds,
            aspectRatio: aspectRatio,
            nShots: shotCount,
            directives: directives,
            temporalStructure: temporalStructure
        )
    }
}

public enum VideoPromptDialectFamilyV1: String, Codable, Sendable, Equatable {
    case seedance
    case h3
    case cameraFirst = "camera_first"
    case styleFirst = "style_first"
    case generic
}

public struct VideoPromptDialectV1: Codable, Sendable, Equatable {
    public let id: String
    public let version: Int
    public let family: VideoPromptDialectFamilyV1
    public let evidence: String

    public init(id: String, version: Int, family: VideoPromptDialectFamilyV1, evidence: String) {
        self.id = id
        self.version = version
        self.family = family
        self.evidence = evidence
    }
}
