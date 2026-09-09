import Foundation

public enum MusicPerformancePurposeV1: String, Codable, Sendable, Equatable, CaseIterable {
    case timingOnly = "timing_only"
    case performedSong = "performed_song"
    case dialogueDiegetic = "dialogue_diegetic"
}

public struct MusicMouthOwnershipV1: Codable, Sendable, Equatable {
    public let performerID: String
    public let voiceID: String
    public let timelineStartSeconds: Double
    public let timelineEndSeconds: Double

    private enum CodingKeys: String, CodingKey {
        case performerID = "performer_id"
        case voiceID = "voice_id"
        case timelineStartSeconds = "timeline_start_seconds"
        case timelineEndSeconds = "timeline_end_seconds"
    }

    public init(
        performerID: String,
        voiceID: String,
        timelineStartSeconds: Double,
        timelineEndSeconds: Double
    ) {
        self.performerID = performerID
        self.voiceID = voiceID
        self.timelineStartSeconds = timelineStartSeconds
        self.timelineEndSeconds = timelineEndSeconds
    }
}

public struct MusicPerformanceSegmentDraftV1: Codable, Sendable, Equatable {
    public let id: String
    public let shotIDs: [String]
    public let sourceStartSample: Int64
    public let sourceEndSample: Int64
    public let sampleRate: Int
    public let timelineStartSeconds: Double
    public let purpose: MusicPerformancePurposeV1
    public let performerIDs: [String]
    public let audibleVoiceIDs: [String]
    public let mouthOwnership: [MusicMouthOwnershipV1]
    public let lyricsAlignmentPath: String?
    public let lyricsAlignmentSHA256: String?
    public let routeInputRoleID: String
    public let phraseBoundaryEvidence: String

    private enum CodingKeys: String, CodingKey {
        case id
        case shotIDs = "shot_ids"
        case sourceStartSample = "source_start_sample"
        case sourceEndSample = "source_end_sample"
        case sampleRate = "sample_rate"
        case timelineStartSeconds = "timeline_start_seconds"
        case purpose
        case performerIDs = "performer_ids"
        case audibleVoiceIDs = "audible_voice_ids"
        case mouthOwnership = "mouth_ownership"
        case lyricsAlignmentPath = "lyrics_alignment_path"
        case lyricsAlignmentSHA256 = "lyrics_alignment_sha256"
        case routeInputRoleID = "route_input_role_id"
        case phraseBoundaryEvidence = "phrase_boundary_evidence"
    }

    public init(
        id: String,
        shotIDs: [String],
        sourceStartSample: Int64,
        sourceEndSample: Int64,
        sampleRate: Int,
        timelineStartSeconds: Double,
        purpose: MusicPerformancePurposeV1,
        performerIDs: [String],
        audibleVoiceIDs: [String],
        mouthOwnership: [MusicMouthOwnershipV1],
        lyricsAlignmentPath: String? = nil,
        lyricsAlignmentSHA256: String? = nil,
        routeInputRoleID: String,
        phraseBoundaryEvidence: String
    ) {
        self.id = id
        self.shotIDs = shotIDs
        self.sourceStartSample = sourceStartSample
        self.sourceEndSample = sourceEndSample
        self.sampleRate = sampleRate
        self.timelineStartSeconds = timelineStartSeconds
        self.purpose = purpose
        self.performerIDs = performerIDs
        self.audibleVoiceIDs = audibleVoiceIDs
        self.mouthOwnership = mouthOwnership
        self.lyricsAlignmentPath = lyricsAlignmentPath
        self.lyricsAlignmentSHA256 = lyricsAlignmentSHA256
        self.routeInputRoleID = routeInputRoleID
        self.phraseBoundaryEvidence = phraseBoundaryEvidence
    }
}

public struct MaterializedMusicPerformanceSegmentV1: Codable, Sendable, Equatable {
    public let draft: MusicPerformanceSegmentDraftV1
    public let sourceTrackPath: String
    public let sourceTrackSHA256: String
    public let segmentPath: String
    public let segmentSHA256: String
    public let segmentByteCount: Int64
    public let exportedSampleCount: Int64

    private enum CodingKeys: String, CodingKey {
        case draft
        case sourceTrackPath = "source_track_path"
        case sourceTrackSHA256 = "source_track_sha256"
        case segmentPath = "segment_path"
        case segmentSHA256 = "segment_sha256"
        case segmentByteCount = "segment_byte_count"
        case exportedSampleCount = "exported_sample_count"
    }

    public init(
        draft: MusicPerformanceSegmentDraftV1,
        sourceTrackPath: String,
        sourceTrackSHA256: String,
        segmentPath: String,
        segmentSHA256: String,
        segmentByteCount: Int64,
        exportedSampleCount: Int64
    ) {
        self.draft = draft
        self.sourceTrackPath = sourceTrackPath
        self.sourceTrackSHA256 = sourceTrackSHA256
        self.segmentPath = segmentPath
        self.segmentSHA256 = segmentSHA256
        self.segmentByteCount = segmentByteCount
        self.exportedSampleCount = exportedSampleCount
    }
}

public struct MusicFinalMixPolicyV1: Codable, Sendable, Equatable {
    public let originalSongTimelineStartSeconds: Double
    public let originalSongOccurrences: Int
    public let providerSongAudioMuted: Bool
    public let approvedAdditionalLayerIDs: [String]
    public let creditAndUsageNote: String?

    private enum CodingKeys: String, CodingKey {
        case originalSongTimelineStartSeconds = "original_song_timeline_start_seconds"
        case originalSongOccurrences = "original_song_occurrences"
        case providerSongAudioMuted = "provider_song_audio_muted"
        case approvedAdditionalLayerIDs = "approved_additional_layer_ids"
        case creditAndUsageNote = "credit_and_usage_note"
    }

    public init(
        originalSongTimelineStartSeconds: Double,
        originalSongOccurrences: Int,
        providerSongAudioMuted: Bool,
        approvedAdditionalLayerIDs: [String],
        creditAndUsageNote: String? = nil
    ) {
        self.originalSongTimelineStartSeconds = originalSongTimelineStartSeconds
        self.originalSongOccurrences = originalSongOccurrences
        self.providerSongAudioMuted = providerSongAudioMuted
        self.approvedAdditionalLayerIDs = approvedAdditionalLayerIDs
        self.creditAndUsageNote = creditAndUsageNote
    }
}

public struct MusicPerformanceBindingV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "music-performance-binding/v1"
    public static let relativePath = PipelineLayout.musicPerformanceBindingFile
    public let schema: String
    public let projectID: String
    public let shotlistSHA256: String
    public let trackPath: String
    public let trackSHA256: String
    public let segments: [MaterializedMusicPerformanceSegmentV1]
    public let finalMix: MusicFinalMixPolicyV1

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case shotlistSHA256 = "shotlist_sha256"
        case trackPath = "track_path"
        case trackSHA256 = "track_sha256"
        case segments
        case finalMix = "final_mix"
    }

    public init(
        projectID: String,
        shotlistSHA256: String,
        trackPath: String,
        trackSHA256: String,
        segments: [MaterializedMusicPerformanceSegmentV1],
        finalMix: MusicFinalMixPolicyV1
    ) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.shotlistSHA256 = shotlistSHA256
        self.trackPath = trackPath
        self.trackSHA256 = trackSHA256
        self.segments = segments
        self.finalMix = finalMix
    }
}

public enum MusicArcRelationV1: String, Codable, Sendable, Equatable, CaseIterable {
    case literal
    case metaphorical
    case contrapuntal
    case unused
}

public enum MusicArcParameterKindV1: String, Codable, Sendable, Equatable, CaseIterable {
    case camera
    case state
    case lighting
    case performance
    case guidance
}

public struct MusicArcParameterV1: Codable, Sendable, Equatable {
    public let kind: MusicArcParameterKindV1
    public let targetID: String
    public let value: String
    public let rationale: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case targetID = "target_id"
        case value
        case rationale
    }

    public init(kind: MusicArcParameterKindV1, targetID: String, value: String, rationale: String) {
        self.kind = kind
        self.targetID = targetID
        self.value = value
        self.rationale = rationale
    }
}

public struct MusicArcMotifV1: Codable, Sendable, Equatable {
    public let id: String
    public let description: String
    public let setupIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case description
        case setupIDs = "setup_ids"
    }

    public init(id: String, description: String, setupIDs: [String]) {
        self.id = id
        self.description = description
        self.setupIDs = setupIDs
    }
}

public struct MusicArcSectionV1: Codable, Sendable, Equatable {
    public let sectionID: String
    public let musicalFunction: String
    public let visualFunction: String
    public let motifIDs: [String]
    public let shotIDs: [String]
    public let constants: [MusicArcParameterV1]
    public let variations: [MusicArcParameterV1]
    public let lyricsRelation: MusicArcRelationV1
    public let changeExplanation: String

    private enum CodingKeys: String, CodingKey {
        case sectionID = "section_id"
        case musicalFunction = "musical_function"
        case visualFunction = "visual_function"
        case motifIDs = "motif_ids"
        case shotIDs = "shot_ids"
        case constants
        case variations
        case lyricsRelation = "lyrics_relation"
        case changeExplanation = "change_explanation"
    }

    public init(
        sectionID: String,
        musicalFunction: String,
        visualFunction: String,
        motifIDs: [String],
        shotIDs: [String],
        constants: [MusicArcParameterV1],
        variations: [MusicArcParameterV1],
        lyricsRelation: MusicArcRelationV1,
        changeExplanation: String
    ) {
        self.sectionID = sectionID
        self.musicalFunction = musicalFunction
        self.visualFunction = visualFunction
        self.motifIDs = motifIDs
        self.shotIDs = shotIDs
        self.constants = constants
        self.variations = variations
        self.lyricsRelation = lyricsRelation
        self.changeExplanation = changeExplanation
    }
}

public struct MusicVisualArcV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "music-visual-arc/v1"
    public static let relativePath = PipelineLayout.musicVisualArcFile
    public let schema: String
    public let projectID: String
    public let shotlistSHA256: String
    public let treatmentPath: String
    public let treatmentSHA256: String
    public let trackSHA256: String
    public let analysisPath: String
    public let analysisSHA256: String
    public let concept: String
    public let motifs: [MusicArcMotifV1]
    public let sections: [MusicArcSectionV1]
    public let storyboardPath: String
    public let storyboardSHA256: String

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case shotlistSHA256 = "shotlist_sha256"
        case treatmentPath = "treatment_path"
        case treatmentSHA256 = "treatment_sha256"
        case trackSHA256 = "track_sha256"
        case analysisPath = "analysis_path"
        case analysisSHA256 = "analysis_sha256"
        case concept
        case motifs
        case sections
        case storyboardPath = "storyboard_path"
        case storyboardSHA256 = "storyboard_sha256"
    }

    public init(
        projectID: String,
        shotlistSHA256: String,
        treatmentPath: String,
        treatmentSHA256: String,
        trackSHA256: String,
        analysisPath: String,
        analysisSHA256: String,
        concept: String,
        motifs: [MusicArcMotifV1],
        sections: [MusicArcSectionV1],
        storyboardPath: String,
        storyboardSHA256: String
    ) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.shotlistSHA256 = shotlistSHA256
        self.treatmentPath = treatmentPath
        self.treatmentSHA256 = treatmentSHA256
        self.trackSHA256 = trackSHA256
        self.analysisPath = analysisPath
        self.analysisSHA256 = analysisSHA256
        self.concept = concept
        self.motifs = motifs
        self.sections = sections
        self.storyboardPath = storyboardPath
        self.storyboardSHA256 = storyboardSHA256
    }
}

public struct MusicVisualArcDraftV1: Codable, Sendable, Equatable {
    public let concept: String
    public let motifs: [MusicArcMotifV1]
    public let sections: [MusicArcSectionV1]

    public init(concept: String, motifs: [MusicArcMotifV1], sections: [MusicArcSectionV1]) {
        self.concept = concept
        self.motifs = motifs
        self.sections = sections
    }
}

public enum MusicCoverageKindV1: String, Codable, Sendable, Equatable, CaseIterable {
    case dance
    case concert
    case instrument
    case stagedVocal = "staged_vocal"
}

public struct MusicCoverageEvidenceV1: Codable, Sendable, Equatable {
    public let roleID: String
    public let shotIDs: [String]
    public let performerIDs: [String]
    public let setupIDs: [String]
    public let showsFullBody: Bool
    public let showsFloorContact: Bool
    public let instrumentID: String?
    public let showsHandsAndOrientation: Bool
    public let minimumContinuousSeconds: Double
    public let assemblyRoleID: String

    private enum CodingKeys: String, CodingKey {
        case roleID = "role_id"
        case shotIDs = "shot_ids"
        case performerIDs = "performer_ids"
        case setupIDs = "setup_ids"
        case showsFullBody = "shows_full_body"
        case showsFloorContact = "shows_floor_contact"
        case instrumentID = "instrument_id"
        case showsHandsAndOrientation = "shows_hands_and_orientation"
        case minimumContinuousSeconds = "minimum_continuous_seconds"
        case assemblyRoleID = "assembly_role_id"
    }

    public init(
        roleID: String,
        shotIDs: [String],
        performerIDs: [String],
        setupIDs: [String],
        showsFullBody: Bool,
        showsFloorContact: Bool,
        instrumentID: String? = nil,
        showsHandsAndOrientation: Bool,
        minimumContinuousSeconds: Double,
        assemblyRoleID: String
    ) {
        self.roleID = roleID
        self.shotIDs = shotIDs
        self.performerIDs = performerIDs
        self.setupIDs = setupIDs
        self.showsFullBody = showsFullBody
        self.showsFloorContact = showsFloorContact
        self.instrumentID = instrumentID
        self.showsHandsAndOrientation = showsHandsAndOrientation
        self.minimumContinuousSeconds = minimumContinuousSeconds
        self.assemblyRoleID = assemblyRoleID
    }
}

public struct MusicPerformanceCoverageItemV1: Codable, Sendable, Equatable {
    public let id: String
    public let sectionIDs: [String]
    public let kind: MusicCoverageKindV1
    public let requiredRoleIDs: [String]
    public let evidence: [MusicCoverageEvidenceV1]
    public let approvedExceptionRoleIDs: [String]
    public let choreographyBeatIDs: [String]
    public let risk: String?
    public let rescue: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case sectionIDs = "section_ids"
        case kind
        case requiredRoleIDs = "required_role_ids"
        case evidence
        case approvedExceptionRoleIDs = "approved_exception_role_ids"
        case choreographyBeatIDs = "choreography_beat_ids"
        case risk
        case rescue
    }

    public init(
        id: String,
        sectionIDs: [String],
        kind: MusicCoverageKindV1,
        requiredRoleIDs: [String],
        evidence: [MusicCoverageEvidenceV1],
        approvedExceptionRoleIDs: [String],
        choreographyBeatIDs: [String],
        risk: String? = nil,
        rescue: String? = nil
    ) {
        self.id = id
        self.sectionIDs = sectionIDs
        self.kind = kind
        self.requiredRoleIDs = requiredRoleIDs
        self.evidence = evidence
        self.approvedExceptionRoleIDs = approvedExceptionRoleIDs
        self.choreographyBeatIDs = choreographyBeatIDs
        self.risk = risk
        self.rescue = rescue
    }
}

public struct MusicPerformanceCoverageV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "music-performance-coverage/v1"
    public static let relativePath = PipelineLayout.musicPerformanceCoverageFile
    public let schema: String
    public let projectID: String
    public let shotlistSHA256: String
    public let items: [MusicPerformanceCoverageItemV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case shotlistSHA256 = "shotlist_sha256"
        case items
    }

    public init(projectID: String, shotlistSHA256: String, items: [MusicPerformanceCoverageItemV1]) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.shotlistSHA256 = shotlistSHA256
        self.items = items
    }
}

public struct MusicvideoProductionPlanDraftV1: Codable, Sendable, Equatable {
    public let performanceSegments: [MusicPerformanceSegmentDraftV1]
    public let finalMix: MusicFinalMixPolicyV1
    public let visualArc: MusicVisualArcDraftV1
    public let coverage: [MusicPerformanceCoverageItemV1]

    private enum CodingKeys: String, CodingKey {
        case performanceSegments = "performance_segments"
        case finalMix = "final_mix"
        case visualArc = "visual_arc"
        case coverage
    }

    public init(
        performanceSegments: [MusicPerformanceSegmentDraftV1],
        finalMix: MusicFinalMixPolicyV1,
        visualArc: MusicVisualArcDraftV1,
        coverage: [MusicPerformanceCoverageItemV1]
    ) {
        self.performanceSegments = performanceSegments
        self.finalMix = finalMix
        self.visualArc = visualArc
        self.coverage = coverage
    }
}

public struct MusicAssemblyCoverageRoleV1: Codable, Sendable, Equatable {
    public let coverageID: String
    public let roleID: String
    public let assemblyRoleID: String
    public let shotIDs: [String]
    public let clipIDs: [String]
    public let minimumContinuousSeconds: Double
    public let provedContinuousSeconds: Double

    private enum CodingKeys: String, CodingKey {
        case coverageID = "coverage_id"
        case roleID = "role_id"
        case assemblyRoleID = "assembly_role_id"
        case shotIDs = "shot_ids"
        case clipIDs = "clip_ids"
        case minimumContinuousSeconds = "minimum_continuous_seconds"
        case provedContinuousSeconds = "proved_continuous_seconds"
    }

    public init(
        coverageID: String,
        roleID: String,
        assemblyRoleID: String,
        shotIDs: [String],
        clipIDs: [String],
        minimumContinuousSeconds: Double,
        provedContinuousSeconds: Double
    ) {
        self.coverageID = coverageID
        self.roleID = roleID
        self.assemblyRoleID = assemblyRoleID
        self.shotIDs = shotIDs
        self.clipIDs = clipIDs
        self.minimumContinuousSeconds = minimumContinuousSeconds
        self.provedContinuousSeconds = provedContinuousSeconds
    }
}

public struct MusicAssemblyAudioLayerV1: Codable, Sendable, Equatable {
    public let mediaID: String
    public let clipID: String
    public let path: String
    public let sha256: String
    public let startFrame: Int
    public let durationFrames: Int

    private enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
        case clipID = "clip_id"
        case path
        case sha256
        case startFrame = "start_frame"
        case durationFrames = "duration_frames"
    }

    public init(
        mediaID: String,
        clipID: String,
        path: String,
        sha256: String,
        startFrame: Int,
        durationFrames: Int
    ) {
        self.mediaID = mediaID
        self.clipID = clipID
        self.path = path
        self.sha256 = sha256
        self.startFrame = startFrame
        self.durationFrames = durationFrames
    }
}

public struct MusicAssemblyProofV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "music-assembly-proof/v1"
    public static let relativePath = PipelineLayout.musicAssemblyProofFile
    public let schema: String
    public let projectID: String
    public let performanceBindingSHA256: String
    public let coveragePlanSHA256: String
    public let timelineAssemblySHA256: String
    public let originalSong: MusicAssemblyAudioLayerV1
    public let providerAudioSuppressed: Bool
    public let additionalAudioLayers: [MusicAssemblyAudioLayerV1]
    public let roles: [MusicAssemblyCoverageRoleV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case performanceBindingSHA256 = "performance_binding_sha256"
        case coveragePlanSHA256 = "coverage_plan_sha256"
        case timelineAssemblySHA256 = "timeline_assembly_sha256"
        case originalSong = "original_song"
        case providerAudioSuppressed = "provider_audio_suppressed"
        case additionalAudioLayers = "additional_audio_layers"
        case roles
    }

    public init(
        projectID: String,
        performanceBindingSHA256: String,
        coveragePlanSHA256: String,
        timelineAssemblySHA256: String,
        originalSong: MusicAssemblyAudioLayerV1,
        providerAudioSuppressed: Bool,
        additionalAudioLayers: [MusicAssemblyAudioLayerV1],
        roles: [MusicAssemblyCoverageRoleV1]
    ) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.performanceBindingSHA256 = performanceBindingSHA256
        self.coveragePlanSHA256 = coveragePlanSHA256
        self.timelineAssemblySHA256 = timelineAssemblySHA256
        self.originalSong = originalSong
        self.providerAudioSuppressed = providerAudioSuppressed
        self.additionalAudioLayers = additionalAudioLayers
        self.roles = roles
    }
}

public enum MusicAssemblyProofValidatorV1 {
    public static func validate(_ proof: MusicAssemblyProofV1) throws {
        guard proof.schema == MusicAssemblyProofV1.schemaVersion,
              !proof.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              validHash(proof.performanceBindingSHA256),
              validHash(proof.coveragePlanSHA256),
              validHash(proof.timelineAssemblySHA256),
              proof.providerAudioSuppressed,
              valid(proof.originalSong),
              proof.originalSong.startFrame == 0,
              Set(proof.additionalAudioLayers.map(\.mediaID)).count
                == proof.additionalAudioLayers.count,
              Set(([proof.originalSong] + proof.additionalAudioLayers).map(\.clipID)).count
                == proof.additionalAudioLayers.count + 1 else {
            throw MusicvideoProductionValidationErrorV1.invalidField("assembly")
        }
        for layer in proof.additionalAudioLayers where !valid(layer) {
            throw MusicvideoProductionValidationErrorV1.invalidField("assembly.audio_layer")
        }
        let keys = proof.roles.map { $0.coverageID + ":" + $0.roleID }
        guard Set(keys).count == keys.count else {
            throw MusicvideoProductionValidationErrorV1.duplicateID("assembly.roles")
        }
        for role in proof.roles {
            guard !role.coverageID.isEmpty,
                  !role.roleID.isEmpty,
                  !role.assemblyRoleID.isEmpty,
                  !role.shotIDs.isEmpty,
                  role.shotIDs.count == role.clipIDs.count,
                  Set(role.shotIDs).count == role.shotIDs.count,
                  Set(role.clipIDs).count == role.clipIDs.count,
                  role.minimumContinuousSeconds.isFinite,
                  role.minimumContinuousSeconds > 0,
                  role.provedContinuousSeconds.isFinite,
                  role.provedContinuousSeconds >= role.minimumContinuousSeconds else {
                throw MusicvideoProductionValidationErrorV1.invalidField("assembly.role")
            }
        }
    }

    private static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func valid(_ layer: MusicAssemblyAudioLayerV1) -> Bool {
        !layer.mediaID.isEmpty
            && !layer.clipID.isEmpty
            && !layer.path.isEmpty
            && !layer.path.hasPrefix("/")
            && !layer.path.split(separator: "/").contains("..")
            && validHash(layer.sha256)
            && layer.startFrame >= 0
            && layer.durationFrames > 0
    }
}

public enum MusicvideoProductionValidationErrorV1: Error, Sendable, Equatable {
    case invalidField(String)
    case duplicateID(String)
    case unknownReference(String)
    case sourceMismatch(String)
    case mouthOwnershipMismatch(String)
    case coverageMissing(String)
}

public enum MusicvideoProductionValidatorV1 {
    public static func validate(_ draft: MusicvideoProductionPlanDraftV1) throws {
        try require(draft.visualArc.concept, "visual_arc.concept")
        let motifIDs = try unique(draft.visualArc.motifs.map(\.id), "visual_arc.motifs")
        let arcSectionIDs = try unique(
            draft.visualArc.sections.map(\.sectionID),
            "visual_arc.sections"
        )
        for motif in draft.visualArc.motifs {
            try require(motif.description, "visual_arc.motif.description")
            _ = try unique(motif.setupIDs, "visual_arc.motif.setup_ids")
        }
        for section in draft.visualArc.sections {
            try require(section.musicalFunction, "visual_arc.section.musical_function")
            try require(section.visualFunction, "visual_arc.section.visual_function")
            try require(section.changeExplanation, "visual_arc.section.change_explanation")
            guard Set(section.motifIDs).isSubset(of: motifIDs), !section.shotIDs.isEmpty else {
                throw MusicvideoProductionValidationErrorV1.unknownReference(section.sectionID)
            }
            _ = try unique(section.motifIDs, "visual_arc.section.motif_ids")
            _ = try unique(section.shotIDs, "visual_arc.section.shot_ids")
            guard !(section.constants + section.variations).isEmpty else {
                throw MusicvideoProductionValidationErrorV1.invalidField(
                    "visual_arc.section.parameters"
                )
            }
            for parameter in section.constants + section.variations {
                try require(parameter.targetID, "visual_arc.parameter.target_id")
                try require(parameter.value, "visual_arc.parameter.value")
                try require(parameter.rationale, "visual_arc.parameter.rationale")
            }
        }
        _ = try unique(draft.performanceSegments.map(\.id), "performance_segments")
        let performanceShotIDs = draft.performanceSegments.flatMap(\.shotIDs)
        guard Set(performanceShotIDs).count == performanceShotIDs.count else {
            throw MusicvideoProductionValidationErrorV1.duplicateID(
                "performance_segments.shot_ids"
            )
        }
        for segment in draft.performanceSegments {
            try require(segment.id, "performance_segment.id")
            guard !segment.shotIDs.isEmpty,
                  segment.sourceStartSample >= 0,
                  segment.sourceEndSample > segment.sourceStartSample,
                  (8_000...192_000).contains(segment.sampleRate),
                  segment.timelineStartSeconds.isFinite,
                  segment.timelineStartSeconds >= 0 else {
                throw MusicvideoProductionValidationErrorV1.invalidField(segment.id)
            }
            _ = try unique(segment.shotIDs, "performance_segment.shot_ids")
            let performers = try unique(segment.performerIDs, "performance_segment.performer_ids")
            let voices = try unique(segment.audibleVoiceIDs, "performance_segment.audible_voice_ids")
            try require(segment.routeInputRoleID, "performance_segment.route_input_role_id")
            try require(segment.phraseBoundaryEvidence, "performance_segment.phrase_boundary_evidence")
            guard (segment.lyricsAlignmentPath == nil) == (segment.lyricsAlignmentSHA256 == nil) else {
                throw MusicvideoProductionValidationErrorV1.invalidField(segment.id)
            }
            for ownership in segment.mouthOwnership {
                guard performers.contains(ownership.performerID),
                      voices.contains(ownership.voiceID),
                      ownership.timelineStartSeconds >= segment.timelineStartSeconds,
                      ownership.timelineEndSeconds > ownership.timelineStartSeconds,
                      ownership.timelineEndSeconds <= segment.timelineStartSeconds
                        + Double(segment.sourceEndSample - segment.sourceStartSample)
                            / Double(segment.sampleRate) + 0.001 else {
                    throw MusicvideoProductionValidationErrorV1.mouthOwnershipMismatch(segment.id)
                }
            }
            if segment.purpose == .performedSong {
                let ownershipVoices = Set(segment.mouthOwnership.map(\.voiceID))
                let oneMouthPerVoice = Dictionary(
                    grouping: segment.mouthOwnership,
                    by: \.voiceID
                ).values.allSatisfy { Set($0.map(\.performerID)).count == 1 }
                guard !segment.mouthOwnership.isEmpty,
                      !performers.isEmpty,
                      !voices.isEmpty,
                      ownershipVoices == voices,
                      oneMouthPerVoice else {
                    throw MusicvideoProductionValidationErrorV1.mouthOwnershipMismatch(segment.id)
                }
            }
        }
        guard draft.finalMix.originalSongTimelineStartSeconds == 0,
              draft.finalMix.originalSongOccurrences == 1,
              draft.finalMix.providerSongAudioMuted else {
            throw MusicvideoProductionValidationErrorV1.invalidField("final_mix")
        }
        _ = try unique(draft.finalMix.approvedAdditionalLayerIDs, "final_mix.additional_layers")

        _ = try unique(draft.coverage.map(\.id), "coverage")
        for item in draft.coverage {
            guard !item.sectionIDs.isEmpty,
                  Set(item.sectionIDs).isSubset(of: arcSectionIDs) else {
                throw MusicvideoProductionValidationErrorV1.unknownReference(item.id)
            }
            let required = try unique(item.requiredRoleIDs, "coverage.required_role_ids")
            let exceptions = try unique(
                item.approvedExceptionRoleIDs,
                "coverage.approved_exception_role_ids"
            )
            let evidenced = try unique(item.evidence.map(\.roleID), "coverage.evidence.role_id")
            guard required.isSubset(of: evidenced.union(exceptions)),
                  exceptions.isSubset(of: required),
                  evidenced.isDisjoint(with: exceptions) else {
                throw MusicvideoProductionValidationErrorV1.coverageMissing(item.id)
            }
            _ = try unique(
                item.evidence.map(\.assemblyRoleID),
                "coverage.evidence.assembly_role_id"
            )
            for evidence in item.evidence {
                guard !evidence.shotIDs.isEmpty,
                      evidence.minimumContinuousSeconds.isFinite,
                      evidence.minimumContinuousSeconds > 0 else {
                    throw MusicvideoProductionValidationErrorV1.invalidField(item.id)
                }
                try require(evidence.assemblyRoleID, "coverage.evidence.assembly_role_id")
                if item.kind == .dance,
                   required.contains(evidence.roleID),
                   !evidence.showsFullBody || !evidence.showsFloorContact {
                    throw MusicvideoProductionValidationErrorV1.coverageMissing(evidence.roleID)
                }
                if item.kind == .instrument,
                   required.contains(evidence.roleID),
                   (evidence.instrumentID == nil || !evidence.showsHandsAndOrientation) {
                    throw MusicvideoProductionValidationErrorV1.coverageMissing(evidence.roleID)
                }
            }
            if item.risk != nil || item.rescue != nil {
                guard nonEmpty(item.risk), nonEmpty(item.rescue) else {
                    throw MusicvideoProductionValidationErrorV1.invalidField("coverage.risk")
                }
            }
        }
    }

    private static func unique(_ values: [String], _ field: String) throws -> Set<String> {
        for value in values { try require(value, field) }
        let result = Set(values)
        guard result.count == values.count else {
            throw MusicvideoProductionValidationErrorV1.duplicateID(field)
        }
        return result
    }

    private static func require(_ value: String, _ field: String) throws {
        guard nonEmpty(value) else {
            throw MusicvideoProductionValidationErrorV1.invalidField(field)
        }
    }

    private static func nonEmpty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
