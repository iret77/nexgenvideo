import Testing
@testable import NexGenEngine

@Suite("Musicvideo production contracts")
struct MusicvideoProductionExtensionsV1Tests {
    @Test("a nonnarrative visual arc does not require lyrics or performance")
    func acceptsNonnarrativeArc() throws {
        try MusicvideoProductionValidatorV1.validate(draft())
    }

    @Test("performed song segments bind audible voices to visible mouths")
    func performedSongBindsMouthOwnership() throws {
        let segment = MusicPerformanceSegmentDraftV1(
            id: "chorus-performance",
            shotIDs: ["s001"],
            sourceStartSample: 48_000,
            sourceEndSample: 144_000,
            sampleRate: 48_000,
            timelineStartSeconds: 4,
            purpose: .performedSong,
            performerIDs: ["lead"],
            audibleVoiceIDs: ["lead-voice"],
            mouthOwnership: [MusicMouthOwnershipV1(
                performerID: "lead",
                voiceID: "lead-voice",
                timelineStartSeconds: 4,
                timelineEndSeconds: 6
            )],
            routeInputRoleID: "source-song-segment",
            phraseBoundaryEvidence: "Chorus phrase spans source samples 48000...144000."
        )
        try MusicvideoProductionValidatorV1.validate(draft(performanceSegments: [segment]))

        let invalid = MusicPerformanceSegmentDraftV1(
            id: segment.id,
            shotIDs: segment.shotIDs,
            sourceStartSample: segment.sourceStartSample,
            sourceEndSample: segment.sourceEndSample,
            sampleRate: segment.sampleRate,
            timelineStartSeconds: segment.timelineStartSeconds,
            purpose: segment.purpose,
            performerIDs: segment.performerIDs,
            audibleVoiceIDs: segment.audibleVoiceIDs,
            mouthOwnership: [MusicMouthOwnershipV1(
                performerID: "lead",
                voiceID: "unheard-voice",
                timelineStartSeconds: 4,
                timelineEndSeconds: 6
            )],
            routeInputRoleID: segment.routeInputRoleID,
            phraseBoundaryEvidence: segment.phraseBoundaryEvidence
        )
        #expect(throws: MusicvideoProductionValidationErrorV1.self) {
            try MusicvideoProductionValidatorV1.validate(
                draft(performanceSegments: [invalid])
            )
        }
    }

    @Test("dance masters prove full-body floor contact while close-ups remain usable inserts")
    func danceMasterAndInsertHaveDistinctDuties() throws {
        let master = MusicCoverageEvidenceV1(
            roleID: "master",
            shotIDs: ["s001"],
            performerIDs: ["dancer"],
            setupIDs: ["wide"],
            showsFullBody: true,
            showsFloorContact: true,
            showsHandsAndOrientation: false,
            minimumContinuousSeconds: 4,
            assemblyRoleID: "dance-master"
        )
        let insert = MusicCoverageEvidenceV1(
            roleID: "face-insert",
            shotIDs: ["s002"],
            performerIDs: ["dancer"],
            setupIDs: ["close"],
            showsFullBody: false,
            showsFloorContact: false,
            showsHandsAndOrientation: false,
            minimumContinuousSeconds: 1,
            assemblyRoleID: "dance-insert"
        )
        let covered = MusicPerformanceCoverageItemV1(
            id: "dance-chorus",
            sectionIDs: ["chorus"],
            kind: .dance,
            requiredRoleIDs: ["master"],
            evidence: [master, insert],
            approvedExceptionRoleIDs: [],
            choreographyBeatIDs: ["chorus-hit"],
            risk: "The master may lose foot contact at the frame edge.",
            rescue: "Use the alternate wide setup for the complete phrase."
        )
        try MusicvideoProductionValidatorV1.validate(draft(coverage: [covered]))

        let missingMaster = MusicPerformanceCoverageItemV1(
            id: covered.id,
            sectionIDs: covered.sectionIDs,
            kind: covered.kind,
            requiredRoleIDs: covered.requiredRoleIDs,
            evidence: [insert],
            approvedExceptionRoleIDs: [],
            choreographyBeatIDs: covered.choreographyBeatIDs,
            risk: covered.risk,
            rescue: covered.rescue
        )
        #expect(throws: MusicvideoProductionValidationErrorV1.self) {
            try MusicvideoProductionValidatorV1.validate(draft(coverage: [missingMaster]))
        }
    }

    @Test("the final mix contains the original song once and suppresses provider song audio")
    func finalMixPolicyIsExact() {
        let duplicatedSong = MusicFinalMixPolicyV1(
            originalSongTimelineStartSeconds: 0,
            originalSongOccurrences: 2,
            providerSongAudioMuted: true,
            approvedAdditionalLayerIDs: []
        )
        #expect(throws: MusicvideoProductionValidationErrorV1.self) {
            try MusicvideoProductionValidatorV1.validate(draft(finalMix: duplicatedSong))
        }

        let audibleProviderSong = MusicFinalMixPolicyV1(
            originalSongTimelineStartSeconds: 0,
            originalSongOccurrences: 1,
            providerSongAudioMuted: false,
            approvedAdditionalLayerIDs: []
        )
        #expect(throws: MusicvideoProductionValidationErrorV1.self) {
            try MusicvideoProductionValidatorV1.validate(draft(finalMix: audibleProviderSong))
        }
    }

    @Test("visual arc sections cannot cite an unknown motif")
    func visualArcRejectsUnknownMotif() {
        let section = arcSection(motifIDs: ["unknown-motif"])
        let arc = MusicVisualArcDraftV1(
            concept: "A fixed room gains kinetic variations with each chorus.",
            motifs: [motif()],
            sections: [section]
        )
        #expect(throws: MusicvideoProductionValidationErrorV1.self) {
            try MusicvideoProductionValidatorV1.validate(draft(visualArc: arc))
        }
    }

    private func draft(
        performanceSegments: [MusicPerformanceSegmentDraftV1] = [],
        finalMix: MusicFinalMixPolicyV1 = MusicFinalMixPolicyV1(
            originalSongTimelineStartSeconds: 0,
            originalSongOccurrences: 1,
            providerSongAudioMuted: true,
            approvedAdditionalLayerIDs: []
        ),
        visualArc: MusicVisualArcDraftV1? = nil,
        coverage: [MusicPerformanceCoverageItemV1] = []
    ) -> MusicvideoProductionPlanDraftV1 {
        MusicvideoProductionPlanDraftV1(
            performanceSegments: performanceSegments,
            finalMix: finalMix,
            visualArc: visualArc ?? MusicVisualArcDraftV1(
                concept: "A fixed room gains kinetic variations with each chorus.",
                motifs: [motif()],
                sections: [arcSection()]
            ),
            coverage: coverage
        )
    }

    private func motif() -> MusicArcMotifV1 {
        MusicArcMotifV1(
            id: "window-light",
            description: "A diagonal light motif repeats through the song.",
            setupIDs: ["wide"]
        )
    }

    private func arcSection(motifIDs: [String] = ["window-light"]) -> MusicArcSectionV1 {
        MusicArcSectionV1(
            sectionID: "chorus",
            musicalFunction: "release",
            visualFunction: "expand movement",
            motifIDs: motifIDs,
            shotIDs: ["s001", "s002"],
            constants: [MusicArcParameterV1(
                kind: .lighting,
                targetID: "window-light",
                value: "diagonal amber key",
                rationale: "Preserve motif recognition."
            )],
            variations: [MusicArcParameterV1(
                kind: .camera,
                targetID: "wide",
                value: "increase lateral speed",
                rationale: "Express the chorus energy rise."
            )],
            lyricsRelation: .unused,
            changeExplanation: "The music drives motion while the lighting motif stays constant."
        )
    }
}
