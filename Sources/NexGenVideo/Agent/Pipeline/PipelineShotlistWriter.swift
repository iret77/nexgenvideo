import Foundation
import NexGenEngine

enum PipelineShotlistWriter {
    static func write(
        _ shotlist: Shotlist,
        dataRoot: URL,
        declaredPack: String?,
        enforceProductionPlans: Bool
    ) throws -> URL {
        try validate(
            shotlist,
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            enforceProductionPlans: enforceProductionPlans
        )
        do {
            return try saveShotlist(shotlist, to: dataRoot)
        } catch {
            throw ToolError("Couldn't write shot list: \(error.localizedDescription)")
        }
    }

    static func validate(
        _ shotlist: Shotlist,
        dataRoot: URL,
        declaredPack: String?,
        enforceProductionPlans: Bool
    ) throws {
        let brief = try? YAMLArtifactStore(dataRoot: dataRoot).load(
            Brief.self,
            at: PipelineLayout.briefFile
        )
        let activePack: String?
        do {
            activePack = try ProjectPluginSettings.resolvedPlugin(
                projectURL: FrameInventory.projectHome(of: dataRoot),
                declaredPack: declaredPack
            )
        } catch {
            throw ToolError(error.localizedDescription)
        }
        let profileIDs = PackCatalog.registry(activePack: activePack)
            .activeProductionProfileIDs(metadata: [
                "concept_type": brief?.conceptType.rawValue ?? "",
            ])

        let importedPlans = shotlist.shots.filter {
            $0.sourceMode == .imported && $0.productionPlan != nil
        }
        guard importedPlans.isEmpty else {
            throw ToolError(
                "Imported shots use their existing footage as production truth and omit "
                    + "production_plan (e.g. "
                    + importedPlans.prefix(3).map(\.id).joined(separator: ", ")
                    + ")."
            )
        }

        if profileIDs.contains(.generativeFilm) {
            let missingPlans = shotlist.shots.filter {
                ProductionDiscipline.requiresProductionPlan($0)
                    && $0.productionPlan == nil
            }
            guard !enforceProductionPlans || missingPlans.isEmpty else {
                throw ToolError(
                    "Every new shot requires production_plan (e.g. "
                        + missingPlans.prefix(3).map(\.id).joined(separator: ", ")
                        + ")."
                )
            }
            let crowded = shotlist.shots.filter {
                $0.productionPlan != nil
                    && ProductionDiscipline.hasTooManyVisibleCharacters($0)
            }
            guard crowded.isEmpty else {
                throw ToolError(
                    "Generated shots may contain at most two visible characters; split "
                        + crowded.prefix(3).map(\.id).joined(separator: ", ")
                        + " into simpler shots."
                )
            }
            let undeclaredLongTakes = shotlist.shots.filter(
                ProductionDiscipline.hasUndeclaredLongTake
            )
            guard undeclaredLongTakes.isEmpty else {
                throw ToolError(
                    "Generated shots over 12 seconds must declare long_take and a rescue cut "
                        + "(e.g. "
                        + undeclaredLongTakes.prefix(3).map(\.id).joined(separator: ", ")
                        + ")."
                )
            }
            let unanchoredBlocking = shotlist.shots.filter {
                $0.productionPlan != nil
                    && ProductionDiscipline.hasUnanchoredCharacterBlocking($0)
            }
            guard unanchoredBlocking.isEmpty else {
                throw ToolError(
                    "Generated character blocking must name set_anchor separately from relation_to_set "
                        + "(e.g. "
                        + unanchoredBlocking.prefix(3).map(\.id).joined(separator: ", ")
                        + ")."
                )
            }
        }

        if profileIDs.contains(.narrativeStorytelling) {
            let missingBeats = shotlist.shots.filter {
                $0.productionPlan != nil && $0.productionPlan?.narrativeBeat == nil
            }
            guard missingBeats.isEmpty else {
                throw ToolError(
                    "Narrative and hybrid projects require narrative_beat for every planned shot "
                        + "(e.g. "
                        + missingBeats.prefix(3).map(\.id).joined(separator: ", ")
                        + ")."
                )
            }
        }

        for shot in shotlist.shots {
            for reference in shot.referenceImageRefs {
                guard let url = projectFileURL(
                    reference,
                    dataRoot: dataRoot
                ),
                ProjectMediaExtensions.images.contains(
                    url.pathExtension.lowercased()
                ) else {
                    throw ToolError(
                        "\(shot.id).reference_image_refs must name real images "
                            + "inside the project: '\(reference)'."
                    )
                }
            }

            switch shot.sourceMode {
            case .generated:
                guard shot.sourcePath == nil else {
                    throw ToolError(
                        "\(shot.id) is generated and cannot declare source_path."
                    )
                }
            case .imported:
                guard shot.keyframeStrategy == .none,
                      !shot.chainWithPreviousEnd else {
                    throw ToolError(
                        "\(shot.id) is imported and cannot request generated "
                            + "keyframes or render chaining."
                    )
                }
            case .aiEnhanced:
                guard let sourcePath = shot.sourcePath,
                      !sourcePath.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty,
                      let sourceURL = projectFileURL(
                          sourcePath,
                          dataRoot: dataRoot
                      ),
                      ProjectMediaExtensions.videos.contains(
                          sourceURL.pathExtension.lowercased()
                      ),
                      shot.keyframeStrategy == .none,
                      !shot.chainWithPreviousEnd,
                      shot.seedanceInputMode == .keyframe,
                      shot.referenceImageRefs.isEmpty else {
                    throw ToolError(
                        "\(shot.id) is AI-enhanced and needs exactly one "
                            + "project-local source video, with no generated "
                            + "keyframes, chaining, or reference inputs."
                    )
                }
            }
        }

        let invalidChains = shotlist.shots.filter {
            $0.chainWithPreviousEnd
                && (
                    $0.sourceMode != .generated
                        || $0.keyframeStrategy != .none
                        || $0.seedanceInputMode != .keyframe
                        || !$0.referenceImageRefs.isEmpty
                        || ChainContinuity.chainPredecessor(
                            shotlist,
                            shotId: $0.id
                        ) == nil
                )
        }
        guard invalidChains.isEmpty else {
            throw ToolError(
                "Chained shots must be generated, follow an earlier renderable "
                    + "shot, use keyframe_strategy=none and "
                    + "seedance_input_mode=keyframe, and declare no reference "
                    + "images (e.g. "
                    + invalidChains.prefix(3).map(\.id).joined(separator: ", ")
                    + ")."
            )
        }

        let invalidReferenceMode = shotlist.shots.filter {
            $0.seedanceInputMode == .reference
                && (
                    $0.keyframeStrategy != .none
                        || $0.chainWithPreviousEnd
                )
        }
        guard invalidReferenceMode.isEmpty else {
            throw ToolError(
                "Reference-mode shots must use keyframe_strategy=none and "
                    + "cannot chain from a predecessor (e.g. "
                    + invalidReferenceMode.prefix(3).map(\.id)
                        .joined(separator: ", ")
                    + ")."
            )
        }
    }

    private static func projectFileURL(
        _ path: String,
        dataRoot: URL
    ) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !NSString(string: trimmed).isAbsolutePath,
              !trimmed.split(separator: "/").contains("..") else {
            return nil
        }
        let home = FrameInventory.projectHome(of: dataRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        for candidate in [
            dataRoot.appendingPathComponent(trimmed),
            home.appendingPathComponent(trimmed),
        ] {
            let resolved = candidate.standardizedFileURL
                .resolvingSymlinksInPath()
            guard resolved.path == home.path
                    || resolved.path.hasPrefix(home.path + "/") else {
                continue
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: resolved.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue {
                return resolved
            }
        }
        return nil
    }
}
