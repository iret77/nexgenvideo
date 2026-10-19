import Foundation

public struct MusicvideoProductionExtensionV2: Codable, Sendable, Equatable {
    public static let schemaVersion = "musicvideo-production/v2"
    public static let artifactID = "musicvideo.production.v2"
    public static func path(revision: Int) -> String { ShotPlanningPromotionV1.planningDirectory(revision: revision) + "/musicvideo-production.v2.json" }

    public let schema: String
    public let header: PlanningArtifactHeaderV1
    public let track: CanonicalArtifactReferenceV1
    public let analysis: CanonicalArtifactReferenceV1
    public let treatment: CanonicalArtifactReferenceV1
    public let storyboardTiming: CanonicalArtifactReferenceV1
    public let performanceSegments: [MaterializedMusicPerformanceSegmentV1]
    public let performanceReceipts: [CanonicalArtifactReferenceV1]
    public let finalMix: MusicFinalMixPolicyV1
    public let visualArc: MusicVisualArcDraftV1
    public let coverage: [MusicPerformanceCoverageItemV1]

    public init(header: PlanningArtifactHeaderV1, track: CanonicalArtifactReferenceV1, analysis: CanonicalArtifactReferenceV1,
                treatment: CanonicalArtifactReferenceV1, storyboardTiming: CanonicalArtifactReferenceV1,
                performanceSegments: [MaterializedMusicPerformanceSegmentV1], performanceReceipts: [CanonicalArtifactReferenceV1],
                finalMix: MusicFinalMixPolicyV1, visualArc: MusicVisualArcDraftV1, coverage: [MusicPerformanceCoverageItemV1]) {
        schema = Self.schemaVersion
        self.header = header; self.track = track; self.analysis = analysis; self.treatment = treatment
        self.storyboardTiming = storyboardTiming; self.performanceSegments = performanceSegments
        self.performanceReceipts = performanceReceipts; self.finalMix = finalMix; self.visualArc = visualArc; self.coverage = coverage
    }

    public var draft: MusicvideoProductionPlanDraftV1 {
        .init(performanceSegments: performanceSegments.map(\.draft), finalMix: finalMix, visualArc: visualArc, coverage: coverage)
    }

    public var artifactReferences: [CanonicalArtifactReferenceV1] {
        header.inputs + [track, analysis, treatment, storyboardTiming] + performanceReceipts + performanceSegments.map {
            .init(id: "music-audio-" + $0.draft.id, role: "musicvideo.performance-audio", path: $0.segmentPath, sha256: $0.segmentSHA256)
        }
    }
}

public struct MusicPerformanceAudioReceiptV2: Codable, Sendable, Equatable {
    public static let schemaVersion = "native-music-performance-audio/v2"
    public let schema: String
    public let projectID: String
    public let revision: Int
    public let segmentID: String
    public let source: CanonicalArtifactReferenceV1
    public let output: CanonicalArtifactReferenceV1
    public let startSample: Int64
    public let endSample: Int64
    public let sourceFrameCount: Int64
    public let exportedSampleCount: Int64
    public let sampleRate: Int
    public let channels: Int
    public let byteCount: Int64
    public let recordedAt: String

    public init(projectID: String, revision: Int, segmentID: String, source: CanonicalArtifactReferenceV1,
                output: CanonicalArtifactReferenceV1, startSample: Int64, endSample: Int64, sourceFrameCount: Int64,
                exportedSampleCount: Int64, sampleRate: Int, channels: Int, byteCount: Int64, recordedAt: String) {
        schema = Self.schemaVersion; self.projectID = projectID; self.revision = revision; self.segmentID = segmentID
        self.source = source; self.output = output; self.startSample = startSample; self.endSample = endSample
        self.sourceFrameCount = sourceFrameCount; self.exportedSampleCount = exportedSampleCount
        self.sampleRate = sampleRate; self.channels = channels; self.byteCount = byteCount; self.recordedAt = recordedAt
    }
}

public struct MusicvideoSongSectionV2: Sendable, Equatable {
    public let id: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let shotIDs: [String]
}

public enum MusicvideoProductionExtensionStoreV2 {
    private struct Analysis: Decodable {
        struct Section: Decodable { let index: Int; let start: Double; let end: Double }
        struct Alignment: Decodable {
            struct Word: Decodable { let start: Double; let end: Double; let text: String }
            let words: [Word]
        }
        let schema: String
        let project: String
        let song_path: String
        let sample_rate: Int
        let duration_s: Double
        let sections: [Section]
        let alignment: [Alignment]?
    }

    private struct MeasurementProof: Decodable {
        struct Lyrics: Decodable { let alignment_sha256: String; let source_path: String; let source_sha256: String }
        let schema: String
        let project: String
        let song_sha256: String
        let lyrics_alignment: Lyrics?
    }

    public static func requireCurrent(projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> MusicvideoProductionExtensionV2 {
        let matches = projection.executionPlan.extensionReferences.filter { $0.id == MusicvideoProductionExtensionV2.artifactID }
        guard matches.count == 1, let reference = matches.first,
              reference.schema == MusicvideoProductionExtensionV2.schemaVersion,
              reference.path == MusicvideoProductionExtensionV2.path(revision: projection.header.revision) else {
            throw ProductionPlanningError.invalid("musicvideo.extension")
        }
        let url = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
        let value = try JSONDecoder().decode(MusicvideoProductionExtensionV2.self, from: Data(contentsOf: url))
        let timing = try JSONDecoder().decode(StoryboardTimingV1.self, from: Data(contentsOf:
            ProjectLocalFile.requireHash(value.storyboardTiming.sha256, at: value.storyboardTiming.path, dataRoot: dataRoot)))
        guard value.header.revision == projection.header.revision, value.header.projectID == projection.header.projectID,
              value.storyboardTiming == projection.storyboardReference else { throw ProductionPlanningError.stale("musicvideo.projection") }
        let draft = try JSONDecoder().decode(ShotPlanningDraftV1.self, from: Data(contentsOf:
            ProjectLocalFile.requireHash(projection.draftReference.sha256, at: projection.draftReference.path, dataRoot: dataRoot)))
        let graph: AssetGraphV1 = try readBound(ShotPlanningPromotionV1.assetGraphPath(revision: projection.header.revision),
                                               header: value.header, dataRoot: dataRoot)
        guard let bible = try loadBible(dataRoot: dataRoot) else { throw ProductionPlanningError.invalid("musicvideo.bible") }
        try validate(value, shots: projection.shots, timing: timing, draft: draft, graph: graph, bible: bible, dataRoot: dataRoot)
        return value
    }

    public static func sections(analysis reference: CanonicalArtifactReferenceV1, timing: StoryboardTimingV1,
                                dataRoot: URL) throws -> [MusicvideoSongSectionV2] {
        let analysis = try loadAnalysis(reference, timing: timing, dataRoot: dataRoot)
        return try sectionBindings(analysis, timing: timing)
    }

    public static func validate(_ value: MusicvideoProductionExtensionV2, shots: [ExecutionShotV1], timing: StoryboardTimingV1,
                                draft: ShotPlanningDraftV1, graph: AssetGraphV1, bible: Bible, dataRoot: URL) throws {
        try PlanningValidation.require(value.schema == MusicvideoProductionExtensionV2.schemaVersion
            && value.header.projectID == timing.header.projectID && value.header.projectID == bible.project
            && shots.map(\.id) == timing.shots.map(\.id) && shots.map(\.id) == draft.shots.map(\.shotID), "musicvideo.project")
        try value.header.requireCurrentInputs(dataRoot: dataRoot)
        try MusicvideoProductionValidatorV1.validate(value.draft)
        for reference in value.artifactReferences {
            try PlanningValidation.reference(reference)
            _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
            try PlanningValidation.require(value.header.inputs.contains { $0.path == reference.path && $0.sha256 == reference.sha256 }, "musicvideo.inputBinding")
        }
        try PlanningValidation.require(value.track == timing.audio?.source && timing.audio?.offsetTicks == 0,
                                       "musicvideo.originalSong")
        let sections = try self.sections(analysis: value.analysis, timing: timing, dataRoot: dataRoot)
        let bySection = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
        try PlanningValidation.require(Set(value.visualArc.sections.map(\.sectionID)) == Set(bySection.keys), "musicvideo.arcSections")
        let setupIDs = Set(timing.shots.compactMap(\.cameraID) + draft.shots.compactMap(\.camera.spatialCameraID))
        for motif in value.visualArc.motifs {
            try PlanningValidation.require(Set(motif.setupIDs).isSubset(of: setupIDs), "musicvideo.motifSetups")
        }
        for section in value.visualArc.sections {
            try PlanningValidation.require(Set(section.shotIDs) == Set(bySection[section.sectionID]?.shotIDs ?? []), "musicvideo.arcShotTiming")
        }
        let analysis = try loadAnalysis(value.analysis, timing: timing, dataRoot: dataRoot)
        try PlanningValidation.require(value.performanceReceipts.count == value.performanceSegments.count, "musicvideo.audioReceipts")
        let byID = Dictionary(uniqueKeysWithValues: timing.shots.map { ($0.id, $0) })
        let execution = Dictionary(uniqueKeysWithValues: shots.map { ($0.id, $0) })
        for (segment, receiptRef) in zip(value.performanceSegments, value.performanceReceipts) {
            let input = segment.draft
            try PlanningValidation.identifier(input.id, "musicvideo.segmentID")
            let bound = try input.shotIDs.map { id -> StoryboardTimingV1.PlannedShot in
                guard let shot = byID[id] else { throw ProductionPlanningError.invalid("musicvideo.performanceShot") }
                return shot
            }
            let first = bound.map(\.startTicks).min() ?? -1
            let end = try bound.map { try $0.endTicks() }.max() ?? -1
            let sourceStart = Double(input.sourceStartSample) / Double(input.sampleRate)
            let sourceEnd = Double(input.sourceEndSample) / Double(input.sampleRate)
            try PlanningValidation.require(input.sampleRate == analysis.sample_rate
                && abs(sourceStart - input.timelineStartSeconds) <= 0.5 / Double(input.sampleRate)
                && abs(timing.timebase.seconds(for: first) - input.timelineStartSeconds) <= 0.5 / Double(input.sampleRate)
                && timing.timebase.seconds(for: end) <= sourceEnd + 0.5 / Double(input.sampleRate), "musicvideo.performanceRange")
            try PlanningValidation.require(input.performerIDs.allSatisfy { id in
                switch bible.lookupId(id) { case .character?, .ensemble?: true; default: false }
            }, "musicvideo.performer")
            if input.purpose == .performedSong {
                try PlanningValidation.require(input.lyricsAlignmentPath == value.analysis.path
                    && input.lyricsAlignmentSHA256 == value.analysis.sha256, "musicvideo.verifiedLyricsAlignment")
                let proofPath = (value.analysis.path as NSString).deletingPathExtension + ".measurement-proof.json"
                let proof: MeasurementProof = try readBound(proofPath, header: value.header, dataRoot: dataRoot)
                guard proof.schema == "analysis_measurement_proof/v1", proof.project == value.header.projectID,
                      proof.song_sha256 == value.track.sha256, let alignment = proof.lyrics_alignment,
                      value.header.inputs.contains(where: { $0.path == alignment.source_path && $0.sha256 == alignment.source_sha256 }) else {
                    throw ProductionPlanningError.invalid("musicvideo.nativeLyricsProof")
                }
                try PlanningValidation.hash(alignment.alignment_sha256, "musicvideo.lyricsHash")
                let words = analysis.alignment?.flatMap(\.words) ?? []
                try PlanningValidation.require(!words.isEmpty && words.contains {
                    $0.start.isFinite && $0.end.isFinite && $0.start < sourceEnd && $0.end > sourceStart && !$0.text.isEmpty
                }, "musicvideo.performedLyricsRange")
            } else if let path = input.lyricsAlignmentPath {
                try PlanningValidation.require(path == value.analysis.path && input.lyricsAlignmentSHA256 == value.analysis.sha256, "musicvideo.alignmentSource")
            }
            for id in input.shotIDs where execution[id]?.sourceMode != .imported {
                guard let shot = execution[id], ShotDeliveryModeResolverV1.resolve(shot) == .providerVideo else {
                    throw ProductionPlanningError.invalid("musicvideo.performanceVideo")
                }
                let path = ShotPlanningPromotionV1.inputTemplatePath(shotID: id, revision: value.header.revision)
                let template: ProductionInputTemplateV1 = try readBound(path, header: value.header, dataRoot: dataRoot)
                try PlanningValidation.require(template.coreInputs.audioTimingModeID != nil
                    && ProductionIdentifierNormalizerV1.matches(input.routeInputRoleID, CoreReferenceInputSlotIDV1.audioTiming), "musicvideo.performanceAudioMode")
            }
            try validateReceipt(segment, receiptRef: receiptRef, value: value, dataRoot: dataRoot)
        }
        let causality = try TreatmentCausalityStoreV2.requireCurrent(dataRoot: dataRoot)
        try PlanningValidation.require(causality.treatmentReference.path == value.treatment.path
            && causality.treatmentReference.sha256 == value.treatment.sha256, "musicvideo.treatmentBinding")
        let beatIDs = Set(causality.beats.map(\.id))
        let audioAssets = Set(graph.assets.filter { $0.modality == .audio && $0.approval == .approved }.map(\.id))
        try PlanningValidation.require(Set(value.finalMix.approvedAdditionalLayerIDs).isSubset(of: audioAssets), "musicvideo.additionalAudio")
        for item in value.coverage {
            try PlanningValidation.require(Set(item.choreographyBeatIDs).isSubset(of: beatIDs), "musicvideo.choreographyBeats")
            for evidence in item.evidence {
                try PlanningValidation.require(Set(evidence.setupIDs).isSubset(of: setupIDs)
                    && evidence.performerIDs.allSatisfy { bible.lookupId($0) != nil }, "musicvideo.coverageIdentity")
                if let instrument = evidence.instrumentID {
                    guard case .prop? = bible.lookupId(instrument) else { throw ProductionPlanningError.invalid("musicvideo.instrument") }
                }
                var selected: [ReferenceDemandV1] = []
                var covered: [StoryboardTimingV1.PlannedShot] = []
                var generated = 0
                for id in evidence.shotIDs {
                    guard let shot = execution[id], let planned = byID[id] else { throw ProductionPlanningError.invalid("musicvideo.coverageShot") }
                    let musicalSections = Set(sections.filter { $0.shotIDs.contains(id) }.map(\.id))
                    try PlanningValidation.require(!musicalSections.isDisjoint(with: item.sectionIDs), "musicvideo.coverageSection")
                    covered.append(planned)
                    guard shot.sourceMode != .imported else { continue }
                    generated += 1
                    let path = ShotPlanningPromotionV1.demandPath(shotID: id, revision: value.header.revision)
                    let demands: ReferenceDemandSetV1 = try readBound(path, header: value.header, dataRoot: dataRoot)
                    let bound = demands.demands.filter { evidence.referenceDemandIDs.contains($0.id) }
                    try PlanningValidation.require(!bound.isEmpty, "musicvideo.coverageReferences")
                    selected += bound
                }
                try PlanningValidation.require(try longestContinuousSeconds(covered, timebase: timing.timebase) >= evidence.minimumContinuousSeconds,
                                               "musicvideo.coverageTiming")
                try PlanningValidation.require(Set(selected.map(\.id)) == Set(evidence.referenceDemandIDs), "musicvideo.coverageDemands")
                if generated > 0, item.kind == .instrument, let instrument = evidence.instrumentID {
                    try PlanningValidation.require(selected.contains { demand in graph.assets.contains { $0.id == demand.assetID && $0.entityID == instrument } }, "musicvideo.instrumentReference")
                }
                if generated > 0, item.kind == .dance, !selected.contains(where: { $0.modality == .video }) {
                    try PlanningValidation.require(Set(evidence.performerIDs).isSubset(of: Set(selected.compactMap { demand in graph.assets.first { $0.id == demand.assetID }?.entityID })), "musicvideo.danceReference")
                }
            }
        }
    }

    private static func validateReceipt(_ segment: MaterializedMusicPerformanceSegmentV1, receiptRef: CanonicalArtifactReferenceV1,
                                        value: MusicvideoProductionExtensionV2, dataRoot: URL) throws {
        let receipt = try JSONDecoder().decode(MusicPerformanceAudioReceiptV2.self, from: Data(contentsOf:
            ProjectLocalFile.requireHash(receiptRef.sha256, at: receiptRef.path, dataRoot: dataRoot)))
        try PlanningValidation.text(receipt.recordedAt, "musicvideo.audioRecordedAt")
        let expected = ShotPlanningPromotionV1.planningDirectory(revision: value.header.revision) + "/performance-audio/"
        try PlanningValidation.require(receiptRef.path.hasPrefix(expected) && segment.segmentPath.hasPrefix(expected)
            && receipt.schema == MusicPerformanceAudioReceiptV2.schemaVersion && receipt.projectID == value.header.projectID
            && receipt.revision == value.header.revision && receipt.segmentID == segment.draft.id
            && receipt.source == value.track && receipt.output.path == segment.segmentPath && receipt.output.sha256 == segment.segmentSHA256
            && receipt.startSample == segment.draft.sourceStartSample && receipt.endSample == segment.draft.sourceEndSample
            && receipt.startSample >= 0 && receipt.endSample <= receipt.sourceFrameCount
            && receipt.exportedSampleCount == receipt.endSample - receipt.startSample
            && receipt.exportedSampleCount == segment.exportedSampleCount && receipt.sampleRate == segment.draft.sampleRate
            && receipt.channels > 0 && receipt.channels <= 2 && receipt.byteCount == segment.segmentByteCount
            && segment.sourceTrackPath == value.track.path && segment.sourceTrackSHA256 == value.track.sha256,
                                       "musicvideo.nativeAudioReceipt")
        let url = try ProjectLocalFile.requireHash(segment.segmentSHA256, at: segment.segmentPath, dataRoot: dataRoot)
        let bytes = try Data(contentsOf: url)
        try PlanningValidation.require(Int64(bytes.count) == receipt.byteCount && bytes.count > 44
            && bytes.prefix(4) == Data("RIFF".utf8) && bytes.dropFirst(8).prefix(4) == Data("WAVE".utf8), "musicvideo.audioWave")
    }

    private static func longestContinuousSeconds(_ shots: [StoryboardTimingV1.PlannedShot], timebase: RationalTimebaseV1) throws -> Double {
        var start: Int64?, end: Int64 = 0, longest: Int64 = 0
        for shot in shots.sorted(by: { $0.startTicks < $1.startTicks }) {
            let next = try shot.endTicks()
            if let current = start, shot.startTicks <= end { end = max(end, next); longest = max(longest, end - current) }
            else { start = shot.startTicks; end = next; longest = max(longest, shot.durationTicks) }
        }
        return timebase.seconds(for: longest)
    }

    private static func readBound<Value: Decodable>(_ path: String, header: PlanningArtifactHeaderV1, dataRoot: URL) throws -> Value {
        guard let reference = header.inputs.first(where: { $0.path == path }) else { throw ProductionPlanningError.invalid("musicvideo.plannedInput") }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf:
            ProjectLocalFile.requireHash(reference.sha256, at: path, dataRoot: dataRoot)))
    }

    private static func loadAnalysis(_ reference: CanonicalArtifactReferenceV1, timing: StoryboardTimingV1, dataRoot: URL) throws -> Analysis {
        let value = try JSONDecoder().decode(Analysis.self, from: Data(contentsOf:
            ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)))
        try PlanningValidation.require(value.schema == "analysis/v3" && value.project == timing.header.projectID
            && value.song_path == timing.audio?.source.path && value.sample_rate > 0
            && value.duration_s.isFinite && value.duration_s > 0, "musicvideo.analysis")
        try PlanningValidation.unique(value.sections.map { String($0.index) }, "musicvideo.analysisSections")
        return value
    }

    private static func sectionBindings(_ analysis: Analysis, timing: StoryboardTimingV1) throws -> [MusicvideoSongSectionV2] {
        let planEnd = try PlanningValidation.end(start: timing.rangeStartTicks, duration: timing.rangeDurationTicks)
        return try analysis.sections.compactMap { section in
            try PlanningValidation.require(section.index >= 0 && section.start.isFinite && section.end.isFinite
                && section.start >= 0 && section.end > section.start && section.end <= analysis.duration_s + 0.001, "musicvideo.analysisSectionRange")
            guard section.end > timing.timebase.seconds(for: timing.rangeStartTicks),
                  section.start < timing.timebase.seconds(for: planEnd) else { return nil }
            let shotIDs = try timing.shots.filter { shot in
                shot.startTicks < planEnd && timing.timebase.seconds(for: try shot.endTicks()) > section.start
                    && timing.timebase.seconds(for: shot.startTicks) < section.end
            }.map(\.id)
            return MusicvideoSongSectionV2(id: "section-" + String(section.index), startSeconds: section.start,
                endSeconds: section.end, shotIDs: shotIDs)
        }
    }
}
