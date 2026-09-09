import Foundation
import NexGenEngine

enum PipelineMusicvideoAssemblyWriter {
    struct AudioPlacement {
        let mediaID: String
        let clipID: String
        let url: URL
        let isAudioOnlyAsset: Bool
        let startFrame: Int
        let durationFrames: Int
    }

    static func writeIfRequired(
        assembly: TimelineAssemblyProofV1,
        audioPlacements: [AudioPlacement],
        songMediaID: String?,
        dataRoot: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding?
    ) throws {
        guard declaredPack == "musicvideo",
              PipelineMusicvideoProductionWriter.requiresPlan(
                declaredBinding: declaredBinding
              ) else {
            try removeProof(dataRoot: dataRoot)
            return
        }
        guard let songMediaID else {
            throw ToolError("The Music Video assembly requires the approved original song.")
        }
        _ = try PipelineMusicvideoProductionWriter.requireCurrent(dataRoot: dataRoot)

        let performanceData = try read(
            MusicPerformanceBindingV1.relativePath,
            dataRoot: dataRoot
        )
        let coverageData = try read(
            MusicPerformanceCoverageV1.relativePath,
            dataRoot: dataRoot
        )
        let assemblyData = try read("assembly.json", dataRoot: dataRoot)
        let performance = try JSONDecoder().decode(
            MusicPerformanceBindingV1.self,
            from: performanceData
        )
        let coverage = try JSONDecoder().decode(
            MusicPerformanceCoverageV1.self,
            from: coverageData
        )
        guard performance.projectID == assembly.project,
              coverage.projectID == assembly.project else {
            throw ToolError("The Music Video plan does not belong to the current assembly.")
        }

        let songPlacements = audioPlacements.filter { $0.mediaID == songMediaID }
        guard songPlacements.count == performance.finalMix.originalSongOccurrences,
              let songPlacement = songPlacements.first,
              songPlacement.isAudioOnlyAsset,
              songPlacement.startFrame == 0 else {
            throw ToolError(
                "Place the approved original song exactly once at timeline frame 0."
            )
        }
        let originalSong = try materialize(
            songPlacement,
            expectedPath: performance.trackPath,
            expectedSHA256: performance.trackSHA256,
            dataRoot: dataRoot
        )

        let additionalPlacements = audioPlacements.filter { $0.mediaID != songMediaID }
        let additionalIDs = Set(additionalPlacements.map(\.mediaID))
        let approvedIDs = Set(performance.finalMix.approvedAdditionalLayerIDs)
        guard additionalIDs.isSubset(of: approvedIDs),
              additionalIDs.count == additionalPlacements.count,
              additionalPlacements.allSatisfy(\.isAudioOnlyAsset) else {
            throw ToolError(
                "The timeline contains duplicate or unapproved Music Video audio layers."
            )
        }
        let additionalLayers = try additionalPlacements.map {
            try materialize($0, expectedPath: nil, expectedSHA256: nil, dataRoot: dataRoot)
        }.sorted { $0.mediaID < $1.mediaID }

        let assemblyByShot = Dictionary(uniqueKeysWithValues:
            assembly.placements.map { ($0.shotID, $0) }
        )
        var roleProofs: [MusicAssemblyCoverageRoleV1] = []
        for item in coverage.items {
            let exceptions = Set(item.approvedExceptionRoleIDs)
            for roleID in item.requiredRoleIDs where !exceptions.contains(roleID) {
                guard let evidence = item.evidence.first(where: { $0.roleID == roleID }) else {
                    throw ToolError(
                        "Music Video coverage '\(item.id)' has no evidence for role '\(roleID)'."
                    )
                }
                let qualifying = evidence.shotIDs.compactMap { shotID -> TimelineAssemblyProofV1.Placement? in
                    guard let placement = assemblyByShot[shotID],
                          Double(placement.durationFrames) / Double(assembly.timelineFPS)
                            + 0.000_001 >= evidence.minimumContinuousSeconds else {
                        return nil
                    }
                    return placement
                }.sorted {
                    if $0.startFrame == $1.startFrame { return $0.shotID < $1.shotID }
                    return $0.startFrame < $1.startFrame
                }
                guard let longest = qualifying.max(by: {
                    $0.durationFrames < $1.durationFrames
                }) else {
                    throw ToolError(
                        "The timeline does not satisfy Music Video coverage role '\(roleID)' "
                            + "for at least \(evidence.minimumContinuousSeconds) seconds."
                    )
                }
                roleProofs.append(MusicAssemblyCoverageRoleV1(
                    coverageID: item.id,
                    roleID: roleID,
                    assemblyRoleID: evidence.assemblyRoleID,
                    shotIDs: qualifying.map(\.shotID),
                    clipIDs: qualifying.map(\.clipID),
                    minimumContinuousSeconds: evidence.minimumContinuousSeconds,
                    provedContinuousSeconds: Double(longest.durationFrames)
                        / Double(assembly.timelineFPS)
                ))
            }
        }
        let proof = MusicAssemblyProofV1(
            projectID: assembly.project,
            performanceBindingSHA256: FileDigest.sha256(of: performanceData),
            coveragePlanSHA256: FileDigest.sha256(of: coverageData),
            timelineAssemblySHA256: FileDigest.sha256(of: assemblyData),
            originalSong: originalSong,
            providerAudioSuppressed: performance.finalMix.providerSongAudioMuted,
            additionalAudioLayers: additionalLayers,
            roles: roleProofs.sorted {
                ($0.coverageID, $0.roleID) < ($1.coverageID, $1.roleID)
            }
        )
        try MusicAssemblyProofValidatorV1.validate(proof)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(proof)
        let url = PipelineLayout.url(MusicAssemblyProofV1.relativePath, in: dataRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func materialize(
        _ placement: AudioPlacement,
        expectedPath: String?,
        expectedSHA256: String?,
        dataRoot: URL
    ) throws -> MusicAssemblyAudioLayerV1 {
        let projectHome = FrameInventory.projectHome(of: dataRoot)
            .standardizedFileURL.resolvingSymlinksInPath()
        let url = placement.url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(projectHome.path + "/") else {
            throw ToolError("Assembly audio must be stored inside the project.")
        }
        let normalizedDataRoot = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        let path: String
        if let expectedPath {
            let expectedURL = try ProjectLocalFile.resolve(expectedPath, dataRoot: dataRoot)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard expectedURL == url else {
                throw ToolError("The timeline song does not match the approved song path.")
            }
            path = expectedPath
        } else if url.path.hasPrefix(normalizedDataRoot.path + "/") {
            path = FrameInventory.relativePath(of: url, to: normalizedDataRoot)
        } else {
            path = FrameInventory.relativePath(of: url, to: projectHome)
        }
        let sha256 = try FileDigest.sha256(of: url)
        if let expectedSHA256 {
            guard sha256 == expectedSHA256 else {
                throw ToolError("The timeline song does not match the approved song bytes.")
            }
        }
        _ = try ProjectLocalFile.requireHash(sha256, at: path, dataRoot: dataRoot)
        return MusicAssemblyAudioLayerV1(
            mediaID: placement.mediaID,
            clipID: placement.clipID,
            path: path,
            sha256: sha256,
            startFrame: placement.startFrame,
            durationFrames: placement.durationFrames
        )
    }

    private static func read(_ path: String, dataRoot: URL) throws -> Data {
        try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
    }

    private static func removeProof(dataRoot: URL) throws {
        let url = PipelineLayout.url(MusicAssemblyProofV1.relativePath, in: dataRoot)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
