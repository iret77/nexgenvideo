import Foundation
import NexGenEngine

enum PipelineMusicvideoProductionWriter {
    static let requiredPackVersion = SemanticVersion(major: 0, minor: 5, patch: 8)
    static let extensionIDs: [(String, String, String)] = [
        ("musicvideo.performance-binding.v1", MusicPerformanceBindingV1.schemaVersion, MusicPerformanceBindingV1.relativePath),
        ("musicvideo.visual-arc.v1", MusicVisualArcV1.schemaVersion, MusicVisualArcV1.relativePath),
        ("musicvideo.performance-coverage.v1", MusicPerformanceCoverageV1.schemaVersion, MusicPerformanceCoverageV1.relativePath),
    ]

    struct Snapshot {
        let files: [String: Data]
        let segmentPaths: Set<String>
    }

    static func write(
        _ draft: MusicvideoProductionPlanDraftV1?,
        shotlist: Shotlist,
        shotlistData: Data,
        executionInputs: [PipelineExecutionShotInput],
        dataRoot: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding?
    ) throws {
        guard declaredPack == "musicvideo" else {
            guard draft == nil else {
                throw ToolError("musicvideo_plan is available only in a Music Video project.")
            }
            try clear(dataRoot: dataRoot)
            return
        }
        guard let draft else {
            guard requiresPlan(declaredBinding: declaredBinding) else {
                try clear(dataRoot: dataRoot)
                return
            }
            throw ToolError(
                "Music Video Shot Lists require musicvideo_plan with the song-bound visual arc."
            )
        }
        try MusicvideoProductionValidatorV1.validate(draft)
        let shotIDs = Set(shotlist.shots.map(\.id))
        let sectionIDs = Set(shotlist.shots.compactMap(\.section))
        let inputs = Dictionary(uniqueKeysWithValues: executionInputs.map { ($0.id, $0) })
        let setupIDs = try currentSetupIDs(dataRoot: dataRoot)
        guard Set(draft.visualArc.sections.map(\.sectionID)) == sectionIDs,
              Set(draft.visualArc.sections.flatMap(\.shotIDs)) == shotIDs,
              draft.visualArc.sections.flatMap(\.shotIDs).count == shotIDs.count else {
            throw MusicvideoProductionValidationErrorV1.unknownReference("visual_arc.sections")
        }
        for section in draft.visualArc.sections {
            guard sectionIDs.contains(section.sectionID),
                  Set(section.shotIDs).isSubset(of: shotIDs) else {
                throw MusicvideoProductionValidationErrorV1.unknownReference(section.sectionID)
            }
        }
        for motif in draft.visualArc.motifs where
            !Set(motif.setupIDs).isSubset(of: setupIDs) {
            throw MusicvideoProductionValidationErrorV1.unknownReference(motif.id)
        }
        for segment in draft.performanceSegments {
            let boundShots = shotlist.shots.filter { segment.shotIDs.contains($0.id) }
            let segmentDuration = Double(segment.sourceEndSample - segment.sourceStartSample)
                / Double(segment.sampleRate)
            guard Set(segment.shotIDs).isSubset(of: shotIDs),
                  let firstStart = boundShots.map(\.timeStart).min(),
                  let lastEnd = boundShots.map(\.timeEnd).max(),
                  abs(firstStart - segment.timelineStartSeconds)
                    <= max(0.001, 1.0 / Double(segment.sampleRate)),
                  lastEnd <= segment.timelineStartSeconds + segmentDuration + 0.05,
                  segment.shotIDs.allSatisfy({ shotID in
                      guard let input = inputs[shotID] else { return false }
                      return input.coreInputs?.audioTimingModeID != nil
                  }),
                  ProductionIdentifierNormalizerV1.matches(
                      segment.routeInputRoleID,
                      CoreReferenceInputSlotIDV1.audioTiming
                  ) else {
                throw MusicvideoProductionValidationErrorV1.unknownReference(segment.id)
            }
            if let path = segment.lyricsAlignmentPath,
               let hash = segment.lyricsAlignmentSHA256 {
                _ = try ProjectLocalFile.requireHash(hash, at: path, dataRoot: dataRoot)
            }
        }
        for item in draft.coverage {
            guard Set(item.sectionIDs).isSubset(of: sectionIDs) else {
                throw MusicvideoProductionValidationErrorV1.unknownReference(item.id)
            }
            for evidence in item.evidence {
                guard Set(evidence.shotIDs).isSubset(of: shotIDs),
                      Set(evidence.setupIDs).isSubset(of: setupIDs) else {
                    throw MusicvideoProductionValidationErrorV1.unknownReference(evidence.roleID)
                }
            }
        }

        let trackURL = try ProjectLocalFile.resolve(shotlist.song.audioPath, dataRoot: dataRoot)
        let trackSHA256 = try FileDigest.sha256(of: trackURL)
        let materialized = try draft.performanceSegments.map { segment in
            let exported = try MusicPerformanceSegmentExporter.export(
                sourceURL: trackURL,
                draft: segment,
                dataRoot: dataRoot
            )
            return MaterializedMusicPerformanceSegmentV1(
                draft: segment,
                sourceTrackPath: shotlist.song.audioPath,
                sourceTrackSHA256: trackSHA256,
                segmentPath: exported.path,
                segmentSHA256: exported.sha256,
                segmentByteCount: exported.byteCount,
                exportedSampleCount: exported.sampleCount
            )
        }
        let shotlistSHA256 = FileDigest.sha256(of: shotlistData)
        let performance = MusicPerformanceBindingV1(
            projectID: shotlist.project,
            shotlistSHA256: shotlistSHA256,
            trackPath: shotlist.song.audioPath,
            trackSHA256: trackSHA256,
            segments: materialized,
            finalMix: draft.finalMix
        )
        let treatmentURL = try ProjectLocalFile.resolve(
            PipelineLayout.treatmentCurrentFile,
            dataRoot: dataRoot
        )
        let analysisURL = try ProjectLocalFile.resolve(
            shotlist.song.analysisPath,
            dataRoot: dataRoot
        )
        let storyboardURL = try ProjectLocalFile.resolve(
            PipelineLayout.storyboardCurrentFile,
            dataRoot: dataRoot
        )
        let visualArc = MusicVisualArcV1(
            projectID: shotlist.project,
            shotlistSHA256: shotlistSHA256,
            treatmentPath: PipelineLayout.treatmentCurrentFile,
            treatmentSHA256: try FileDigest.sha256(of: treatmentURL),
            trackSHA256: trackSHA256,
            analysisPath: shotlist.song.analysisPath,
            analysisSHA256: try FileDigest.sha256(of: analysisURL),
            concept: draft.visualArc.concept,
            motifs: draft.visualArc.motifs,
            sections: draft.visualArc.sections,
            storyboardPath: PipelineLayout.storyboardCurrentFile,
            storyboardSHA256: try FileDigest.sha256(of: storyboardURL)
        )
        let coverage = MusicPerformanceCoverageV1(
            projectID: shotlist.project,
            shotlistSHA256: shotlistSHA256,
            items: draft.coverage
        )
        try write(canonicalData(performance), path: MusicPerformanceBindingV1.relativePath, dataRoot: dataRoot)
        try write(canonicalData(visualArc), path: MusicVisualArcV1.relativePath, dataRoot: dataRoot)
        try write(canonicalData(coverage), path: MusicPerformanceCoverageV1.relativePath, dataRoot: dataRoot)
        _ = try requireCurrent(dataRoot: dataRoot)
    }

    static func requireCurrent(dataRoot: URL) throws -> [PackArtifactExtensionReferenceV1] {
        let performanceData = try read(MusicPerformanceBindingV1.relativePath, dataRoot: dataRoot)
        let arcData = try read(MusicVisualArcV1.relativePath, dataRoot: dataRoot)
        let coverageData = try read(MusicPerformanceCoverageV1.relativePath, dataRoot: dataRoot)
        let performance = try JSONDecoder().decode(MusicPerformanceBindingV1.self, from: performanceData)
        let arc = try JSONDecoder().decode(MusicVisualArcV1.self, from: arcData)
        let coverage = try JSONDecoder().decode(MusicPerformanceCoverageV1.self, from: coverageData)
        guard let shotlist = try loadShotlist(dataRoot: dataRoot),
              let version = latestShotlistVersion(dataRoot: dataRoot) else {
            throw MusicvideoProductionValidationErrorV1.sourceMismatch("shotlist")
        }
        let shotlistData = try Data(contentsOf: PipelineLayout.url(
            PipelineLayout.shotlistVersionFile(version),
            in: dataRoot
        ))
        let shotlistSHA256 = FileDigest.sha256(of: shotlistData)
        let trackURL = try ProjectLocalFile.requireHash(
            performance.trackSHA256,
            at: performance.trackPath,
            dataRoot: dataRoot
        )
        guard performance.schema == MusicPerformanceBindingV1.schemaVersion,
              arc.schema == MusicVisualArcV1.schemaVersion,
              coverage.schema == MusicPerformanceCoverageV1.schemaVersion,
              performance.projectID == shotlist.project,
              arc.projectID == shotlist.project,
              coverage.projectID == shotlist.project,
              performance.shotlistSHA256 == shotlistSHA256,
              arc.shotlistSHA256 == shotlistSHA256,
              coverage.shotlistSHA256 == shotlistSHA256,
              arc.trackSHA256 == performance.trackSHA256,
              arc.treatmentSHA256 == (try FileDigest.sha256(of: ProjectLocalFile.resolve(
                  arc.treatmentPath,
                  dataRoot: dataRoot
              ))),
              arc.analysisSHA256 == (try FileDigest.sha256(of: ProjectLocalFile.resolve(
                  arc.analysisPath,
                  dataRoot: dataRoot
              ))),
              arc.storyboardSHA256 == (try FileDigest.sha256(of: ProjectLocalFile.resolve(
                  arc.storyboardPath,
                  dataRoot: dataRoot
              ))),
              try FileDigest.sha256(of: trackURL) == performance.trackSHA256 else {
            throw MusicvideoProductionValidationErrorV1.sourceMismatch("lineage")
        }
        let draft = MusicvideoProductionPlanDraftV1(
            performanceSegments: performance.segments.map(\.draft),
            finalMix: performance.finalMix,
            visualArc: MusicVisualArcDraftV1(
                concept: arc.concept,
                motifs: arc.motifs,
                sections: arc.sections
            ),
            coverage: coverage.items
        )
        try MusicvideoProductionValidatorV1.validate(draft)
        for segment in performance.segments {
            let url = try ProjectLocalFile.requireHash(
                segment.segmentSHA256,
                at: segment.segmentPath,
                dataRoot: dataRoot
            )
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size]
                as? NSNumber)?.int64Value
            guard segment.sourceTrackPath == performance.trackPath,
                  segment.sourceTrackSHA256 == performance.trackSHA256,
                  size == segment.segmentByteCount,
                  segment.exportedSampleCount
                    == segment.draft.sourceEndSample - segment.draft.sourceStartSample else {
                throw MusicvideoProductionValidationErrorV1.sourceMismatch(segment.draft.id)
            }
        }
        return try extensionIDs.map { entry in
            let data = try read(entry.2, dataRoot: dataRoot)
            return PackArtifactExtensionReferenceV1(
                id: entry.0,
                schema: entry.1,
                path: entry.2,
                sha256: FileDigest.sha256(of: data)
            )
        }
    }

    static func snapshot(dataRoot: URL) throws -> Snapshot {
        var files: [String: Data] = [:]
        for (_, _, path) in extensionIDs {
            let url = PipelineLayout.url(path, in: dataRoot)
            if FileManager.default.fileExists(atPath: url.path) {
                files[path] = try Data(contentsOf: url)
            }
        }
        let dir = PipelineLayout.url(PipelineLayout.musicPerformanceSegmentsDir, in: dataRoot)
        let paths = Set((try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ).map(\.path)) ?? [])
        return Snapshot(files: files, segmentPaths: paths)
    }

    static func loadDraftIfPresent(
        dataRoot: URL
    ) throws -> MusicvideoProductionPlanDraftV1? {
        let url = PipelineLayout.url(MusicPerformanceBindingV1.relativePath, in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        _ = try requireCurrent(dataRoot: dataRoot)
        let performance = try JSONDecoder().decode(
            MusicPerformanceBindingV1.self,
            from: read(MusicPerformanceBindingV1.relativePath, dataRoot: dataRoot)
        )
        let arc = try JSONDecoder().decode(
            MusicVisualArcV1.self,
            from: read(MusicVisualArcV1.relativePath, dataRoot: dataRoot)
        )
        let coverage = try JSONDecoder().decode(
            MusicPerformanceCoverageV1.self,
            from: read(MusicPerformanceCoverageV1.relativePath, dataRoot: dataRoot)
        )
        return MusicvideoProductionPlanDraftV1(
            performanceSegments: performance.segments.map(\.draft),
            finalMix: performance.finalMix,
            visualArc: MusicVisualArcDraftV1(
                concept: arc.concept,
                motifs: arc.motifs,
                sections: arc.sections
            ),
            coverage: coverage.items
        )
    }

    static func referencesShot(
        _ shotID: String,
        dataRoot: URL
    ) throws -> Bool {
        guard let draft = try loadDraftIfPresent(dataRoot: dataRoot) else { return false }
        return draft.performanceSegments.contains { $0.shotIDs.contains(shotID) }
    }

    static func materializedSegment(
        for shotID: String,
        dataRoot: URL
    ) throws -> MaterializedMusicPerformanceSegmentV1? {
        let url = PipelineLayout.url(MusicPerformanceBindingV1.relativePath, in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        _ = try requireCurrent(dataRoot: dataRoot)
        let performance = try JSONDecoder().decode(
            MusicPerformanceBindingV1.self,
            from: read(MusicPerformanceBindingV1.relativePath, dataRoot: dataRoot)
        )
        return performance.segments.first { $0.draft.shotIDs.contains(shotID) }
    }

    static func promptDirectives(
        for shotID: String,
        audioLabel: String?,
        dataRoot: URL
    ) throws -> [String] {
        guard let draft = try loadDraftIfPresent(dataRoot: dataRoot) else { return [] }
        var directives = visualArcDirectives(
            visualArc: draft.visualArc,
            shotID: shotID
        )
        guard let segment = try materializedSegment(for: shotID, dataRoot: dataRoot) else {
            return directives
        }
        guard let audioLabel else {
            throw ToolError(
                "The exact approved song segment is missing from the generation inputs."
            )
        }
        let segmentDraft = segment.draft
        directives.append(
            "\(audioLabel) is the exact approved original-song segment for this performance; use it only for \(segmentDraft.purpose.rawValue.replacingOccurrences(of: "_", with: " "))."
        )
        if segmentDraft.purpose == .performedSong {
            for ownership in segmentDraft.mouthOwnership {
                directives.append(
                    "From \(format(ownership.timelineStartSeconds))s to \(format(ownership.timelineEndSeconds))s, only performer \(ownership.performerID) mouths voice \(ownership.voiceID)."
                )
            }
            let owners = Set(segmentDraft.mouthOwnership.map(\.performerID))
            let silent = segmentDraft.performerIDs.filter { !owners.contains($0) }
            if !silent.isEmpty {
                directives.append(
                    "These visible performers do not sing in this segment: \(silent.joined(separator: ", "))."
                )
            }
        }
        directives.append("Do not generate replacement music or an additional song bed.")
        return directives
    }

    static func visualArcDirectives(
        visualArc: MusicVisualArcDraftV1,
        shotID: String
    ) -> [String] {
        visualArc.sections.filter { $0.shotIDs.contains(shotID) }.flatMap { section in
            [
                "Song section \(section.sectionID) has musical function \(section.musicalFunction) and visual function \(section.visualFunction).",
                "Its approved motif IDs are \(section.motifIDs.joined(separator: ", ")). \(section.changeExplanation)",
            ] + (section.constants + section.variations).map { parameter in
                "Approved song-arc \(parameter.kind.rawValue) for \(parameter.targetID): \(parameter.value). Purpose: \(parameter.rationale)"
            }
        }
    }

    static func restore(_ snapshot: Snapshot, dataRoot: URL) throws {
        for (_, _, path) in extensionIDs {
            if let data = snapshot.files[path] {
                try write(data, path: path, dataRoot: dataRoot)
            } else {
                try remove(path: path, dataRoot: dataRoot)
            }
        }
        let dir = PipelineLayout.url(PipelineLayout.musicPerformanceSegmentsDir, in: dataRoot)
        for url in (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )) ?? [] where !snapshot.segmentPaths.contains(url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func currentSetupIDs(dataRoot: URL) throws -> Set<String> {
        let url = PipelineLayout.url(CameraSetupPlanV1.relativePath, in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return Set(try JSONDecoder().decode(CameraSetupPlanV1.self, from: data).setups.map(\.id))
    }

    static func requiresPlan(declaredBinding: ProjectPackBinding?) -> Bool {
        guard let declaredBinding,
              declaredBinding.id == "musicvideo",
              let version = SemanticVersion(declaredBinding.version) else {
            return false
        }
        return version >= requiredPackVersion
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func clear(dataRoot: URL) throws {
        for (_, _, path) in extensionIDs { try remove(path: path, dataRoot: dataRoot) }
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func read(_ path: String, dataRoot: URL) throws -> Data {
        try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
    }

    private static func write(_ data: Data, path: String, dataRoot: URL) throws {
        let url = PipelineLayout.url(path, in: dataRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func remove(path: String, dataRoot: URL) throws {
        let url = PipelineLayout.url(path, in: dataRoot)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
