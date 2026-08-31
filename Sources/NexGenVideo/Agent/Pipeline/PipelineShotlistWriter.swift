import Foundation
import NexGenEngine

enum PipelineShotlistWriter {
    static func write(
        _ shotlist: Shotlist,
        executionInputs: [PipelineExecutionShotInput],
        dataRoot: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding? = nil,
        disciplineSidecar: ProductionDisciplineSidecarV1? = nil
    ) throws -> URL {
        try validate(
            shotlist,
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding,
            disciplineSidecar: disciplineSidecar
        )
        let version = (latestShotlistVersion(dataRoot: dataRoot) ?? 0) + 1
        let shotlistPath = PipelineLayout.shotlistVersionFile(version)
        let shotlistURL = PipelineLayout.url(shotlistPath, in: dataRoot)
        let shotlistData = Data(try YAMLCoding.encode(shotlist).utf8)
        let executionInputData = try PipelineExecutionShotInputStore.canonicalData(
            executionShots: executionInputs,
            shotlist: shotlist,
            shotlistPath: shotlistPath,
            shotlistData: shotlistData
        )
        let executionSnapshot = try PipelineExecutionPlanWriter.snapshot(
            dataRoot: dataRoot
        )
        let executionInputSnapshot = try PipelineExecutionShotInputStore.snapshot(
            dataRoot: dataRoot
        )
        let productionInputsSnapshot = try PipelineProductionInputsWriter.snapshot(
            shotIDs: Set(executionInputs.map(\.id)),
            dataRoot: dataRoot
        )
        let previousShotlist = FileManager.default.fileExists(atPath: shotlistURL.path)
            ? try Data(contentsOf: shotlistURL)
            : nil

        do {
            try requirePackMutation(
                dataRoot: dataRoot,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
            )
            try FileManager.default.createDirectory(
                at: shotlistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try shotlistData.write(to: shotlistURL, options: .atomic)
            try PipelineExecutionShotInputStore.write(
                executionInputData,
                dataRoot: dataRoot
            )
            let draft = try PipelineExecutionPlanComposer.compose(
                shotlist: shotlist,
                executionInputs: executionInputs,
                executionInputData: executionInputData,
                shotlistPath: shotlistPath,
                dataRoot: dataRoot,
                declaredPack: declaredPack
            )
            try PipelineProductionInputsWriter.write(
                graph: draft.assetGraph,
                demandSets: draft.demandSets,
                templates: draft.inputTemplates,
                dataRoot: dataRoot,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
            )
            _ = try PipelineExecutionPlanWriter.write(
                plan: draft.plan,
                context: draft.context,
                dataRoot: dataRoot
            )
            try PipelineExecutionPlanWriter.requireCurrentShotlistBinding(
                dataRoot: dataRoot
            )
            return shotlistURL
        } catch {
            let writeError = error
            var rollbackFailures: [String] = []
            do {
                try restore(previousShotlist, at: shotlistURL)
            } catch {
                rollbackFailures.append("Shot List: \(error.localizedDescription)")
            }
            do {
                try PipelineProductionInputsWriter.restore(
                    productionInputsSnapshot,
                    dataRoot: dataRoot
                )
            } catch {
                rollbackFailures.append("production inputs: \(error.localizedDescription)")
            }
            do {
                try PipelineExecutionShotInputStore.restore(
                    executionInputSnapshot,
                    dataRoot: dataRoot
                )
            } catch {
                rollbackFailures.append("execution inputs: \(error.localizedDescription)")
            }
            do {
                try PipelineExecutionPlanWriter.restore(
                    executionSnapshot,
                    dataRoot: dataRoot
                )
            } catch {
                rollbackFailures.append("execution plan: \(error.localizedDescription)")
            }
            if !rollbackFailures.isEmpty {
                throw ToolError(
                    "Couldn't roll back the Shot List and execution plan: "
                        + rollbackFailures.joined(separator: "; ")
                )
            }
            if let error = writeError as? ToolError {
                throw error
            }
            throw ToolError(
                "Couldn't write the Shot List and execution plan: "
                    + writeError.localizedDescription
            )
        }
    }

    static func write(
        _ shotlist: Shotlist,
        dataRoot: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding? = nil,
        disciplineSidecar: ProductionDisciplineSidecarV1? = nil
    ) throws -> URL {
        try validate(
            shotlist,
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding,
            disciplineSidecar: disciplineSidecar
        )
        do {
            try requirePackMutation(
                dataRoot: dataRoot,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
            )
            return try saveShotlist(shotlist, to: dataRoot)
        } catch {
            throw ToolError("Couldn't write shot list: \(error.localizedDescription)")
        }
    }

    static func setSourceMode(
        shotId: String,
        to mode: SourceMode,
        dataRoot: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding? = nil
    ) throws -> Bool {
        try changeSourceMode(
            shotId: shotId,
            to: mode,
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding,
            persist: true
        )
    }

    static func canSetSourceMode(
        shotId: String,
        to mode: SourceMode,
        dataRoot: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding? = nil
    ) -> Bool {
        (try? changeSourceMode(
            shotId: shotId,
            to: mode,
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding,
            persist: false
        )) == true
    }

    private static func changeSourceMode(
        shotId: String,
        to mode: SourceMode,
        dataRoot: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding?,
        persist: Bool
    ) throws -> Bool {
        try requirePackMutation(
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
        guard var shotlist = try loadShotlist(dataRoot: dataRoot),
              let index = shotlist.shots.firstIndex(where: { $0.id == shotId }),
              shotlist.shots[index].sourceMode != mode else {
            return false
        }
        guard mode == .imported,
              shotlist.shots[index].sourceMode == .generated
                || shotlist.shots[index].sourceMode == .aiEnhanced else {
            throw ToolError(
                "Only a generated or AI-enhanced shot can switch to Imported here. "
                    + "Ask the assistant to re-plan any other source change."
            )
        }
        guard !ChainContinuity.needsLastFrame(shotlist, shotId: shotId) else {
            throw ToolError(
                "This shot anchors the next chained shot. Ask the assistant to re-plan "
                    + "that chain before switching this source to Imported."
            )
        }
        do {
            try PipelineExecutionPlanWriter.requireCurrentShotlistBinding(
                dataRoot: dataRoot
            )
        } catch {
            throw ToolError(
                "Rebuild the Shot List execution plan before changing this source."
            )
        }
        let (plan, _) = try PipelineExecutionPlanWriter.load(dataRoot: dataRoot)
        let storedInputs = try PipelineExecutionShotInputStore.loadCurrent(
            dataRoot: dataRoot
        ).executionShots
        guard plan.shots.count == shotlist.shots.count,
              storedInputs.count == shotlist.shots.count,
              plan.shots[index].id == shotId,
              storedInputs[index].id == shotId else {
            throw ToolError(
                "Rebuild the Shot List execution plan before changing this source."
            )
        }
        var executionInputs = storedInputs
        executionInputs[index] = try PipelineExecutionShotInput.imported(
            from: plan.shots[index]
        )
        let previousMode = shotlist.shots[index].sourceMode
        shotlist.shots[index].sourceMode = mode
        if previousMode == .generated {
            shotlist.shots[index].sourcePath = nil
        }
        shotlist.shots[index].productionPlan = nil
        shotlist.shots[index].keyframeStrategy = .none
        shotlist.shots[index].chainWithPreviousEnd = false
        shotlist.shots[index].referenceImageRefs = []
        shotlist.shots[index].seedanceInputMode = .keyframe
        guard persist else { return true }
        _ = try write(
            shotlist,
            executionInputs: executionInputs,
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
        return true
    }

    static func validate(
        _ shotlist: Shotlist,
        dataRoot: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding? = nil,
        disciplineSidecar: ProductionDisciplineSidecarV1? = nil
    ) throws {
        try requirePackMutation(
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
        do {
            try shotlist.validate()
        } catch {
            throw ToolError("The Shot List is invalid: \(error.localizedDescription)")
        }
        let briefURL = PipelineLayout.url(PipelineLayout.briefFile, in: dataRoot)
        let brief: Brief?
        if FileManager.default.fileExists(atPath: briefURL.path) {
            do {
                brief = try YAMLArtifactStore(dataRoot: dataRoot).load(
                    Brief.self,
                    at: PipelineLayout.briefFile
                )
            } catch {
                throw ToolError(
                    "The Brief is unreadable. Repair or restore it before writing the Shot List: "
                        + error.localizedDescription
                )
            }
        } else {
            brief = nil
        }
        let bibleURL = PipelineLayout.url(PipelineLayout.bibleFile, in: dataRoot)
        let bible: Bible?
        if FileManager.default.fileExists(atPath: bibleURL.path) {
            do {
                bible = try loadBible(dataRoot: dataRoot)
            } catch {
                throw ToolError(
                    "The Bible is unreadable. Repair or restore it before writing the Shot List: "
                        + error.localizedDescription
                )
            }
        } else {
            bible = nil
        }
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
            guard !Shotlist.requiresProductionPlan(forGenerator: shotlist.generator)
                    || missingPlans.isEmpty else {
                throw ToolError(
                    "Every new shot requires production_plan (e.g. "
                        + missingPlans.prefix(3).map(\.id).joined(separator: ", ")
                        + ")."
                )
            }
            let crowded = shotlist.shots.filter {
                $0.productionPlan != nil
                    && ProductionDiscipline.hasTooManyVisibleCharacters(
                        $0,
                        bible: bible,
                        route: disciplineSidecar?.route(for: $0.id)
                    )
            }
            guard crowded.isEmpty else {
                throw ToolError(
                    "Generated shots exceed the selected routes' visible-character capacity; revise "
                        + crowded.prefix(3).map(\.id).joined(separator: ", ")
                        + " or select capable routes."
                )
            }
            let undeclaredLongTakes = shotlist.shots.filter {
                ProductionDiscipline.hasUndeclaredLongTake(
                    $0,
                    route: disciplineSidecar?.route(for: $0.id)
                )
            }
            guard undeclaredLongTakes.isEmpty else {
                throw ToolError(
                    "Generated shots exceed the selected routes' duration capacity without "
                        + "declaring long_take and a rescue cut "
                        + "(e.g. "
                        + undeclaredLongTakes.prefix(3).map(\.id).joined(separator: ", ")
                        + ")."
                )
            }
            let excessiveReferences = shotlist.shots.filter {
                ProductionDiscipline.exceedsReferenceCapacity(
                    $0,
                    route: disciplineSidecar?.route(for: $0.id)
                )
            }
            guard excessiveReferences.isEmpty else {
                throw ToolError(
                    "Generated shots exceed the selected routes' reference capacity; revise "
                        + excessiveReferences.prefix(3).map(\.id).joined(separator: ", ")
                        + " or select capable routes."
                )
            }
            let unanchoredBlocking = shotlist.shots.filter {
                $0.productionPlan != nil
                    && ProductionDiscipline.hasUnanchoredCharacterBlocking($0)
            }
            guard unanchoredBlocking.isEmpty else {
                throw ToolError(
                    "Generated character blocking must pair a production_plan.blocking_anchors "
                        + "entry that exactly matches the shot's prop_refs or visible_zones with "
                        + "a non-empty character_blocking.relation_to_set "
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

    private static func requirePackMutation(
        dataRoot: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding?
    ) throws {
        do {
            _ = try ProjectPackGate.requireMutation(
                projectURL: FrameInventory.projectHome(of: dataRoot),
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
            )
        } catch {
            throw ToolError(error.localizedDescription)
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

    private static func restore(_ data: Data?, at url: URL) throws {
        if let data {
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
