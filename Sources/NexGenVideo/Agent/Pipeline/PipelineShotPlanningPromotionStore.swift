import AVFoundation
import Foundation
import NexGenEngine

@MainActor
enum PipelineShotPlanningPromotionStore {
    struct Preparation: Codable, Sendable, Equatable {
        let schema: String
        let projectID: String
        let draft: CanonicalArtifactReferenceV1
        let bible: CanonicalArtifactReferenceV1
        let graph: CanonicalArtifactReferenceV1
    }

    struct Snapshot: Sendable, Equatable {
        let preparation: Preparation
        let draft: ShotPlanningDraftV1
        let timing: StoryboardTimingV1
        let assets: [AssetGraphNodeV1]
        let resolutions: [ShotPlanningPromotionV1.Resolution]
        let sourceRanges: [String: SourceFootageRangeV1]
        let fingerprint: String
        let eligibleAssetIDs: [String: [String]]
        let canAssign: Bool
        let assignmentMessage: String?

        func eligibleAssets(shotID: String, obligationID: String) -> [AssetGraphNodeV1] {
            let allowed = Set(eligibleAssetIDs[shotID + ":" + obligationID] ?? [])
            return assets.filter { allowed.contains($0.id) }
        }
    }

    private struct ResolutionReceipt: Codable, Sendable, Equatable {
        let schema: String
        let id: String
        let projectID: String
        let workflowID: String
        let draft: CanonicalArtifactReferenceV1
        let bible: CanonicalArtifactReferenceV1
        let graphSHA256: String
        let shotID: String
        let obligationID: String
        let outcome: ShotPlanningPromotionV1.Resolution.Outcome
        let nativeSelectedAt: String
        let sourceInputRange: SourceFootageRangeV1?
    }

    private struct Ledger: Codable, Sendable, Equatable {
        let schema: String
        let projectID: String
        let workflowID: String
        let preparation: Preparation
        var resolutions: [ShotPlanningPromotionV1.Resolution]
    }

    nonisolated static let preparationPath = "shot-planning/asset-preparation-current.v1.json"
    nonisolated private static let ledgerPath = "shot-planning/obligation-resolutions-current.v1.json"

    static func prepareAssets(graph: AssetGraphV1, access: PipelinePlanningWriteAccess,
                              revalidate: @MainActor @Sendable () throws -> Void = {}) async throws -> Preparation {
        try revalidate()
        guard ["bible", "shotlist"].contains(access.phase) else { throw GateBlocked("Prepare production assets during Bible or Shot List.") }
        let root = access.dataRoot
        let policy = try assignmentPolicy(workflow: access.workflow, dataRoot: root)
        guard policy.allowed else { throw GateBlocked(policy.message ?? "Rewind to Bible before preparing promoted production assets.") }
        let before = try await Task.detached(priority: .userInitiated) { try sourceInputs(dataRoot: root) }.value
        try revalidate()
        try await Task.detached(priority: .userInitiated) {
            try await validateAssets(graph, bible: before.bibleValue, draft: before.draftValue, dataRoot: root)
        }.value
        try Task.checkCancellation()
        try revalidate()
        try access.revalidate()
        let after = try await Task.detached(priority: .userInitiated) { try sourceInputs(dataRoot: root) }.value
        try Task.checkCancellation()
        try revalidate()
        guard before.draft == after.draft, before.bible == after.bible else { throw changed() }
        let bytes = try AssetGraphCanonicalCodecV1.encode(graph)
        let path = "shot-planning/asset-candidates/" + FileDigest.sha256(of: bytes) + ".v1.json"
        let reference = PlanningWriterIO.reference(path, id: graph.id, role: AssetGraphV1.artifactRole, bytes: bytes)
        let preparation = Preparation(schema: "production-asset-preparation/v1", projectID: graph.projectID,
                                      draft: before.draft, bible: before.bible, graph: reference)
        var files: [(path: String, bytes: Data)] = [(preparationPath, try PlanningWriterIO.json(preparation))]
        if FileManager.default.fileExists(atPath: access.dataRoot.appendingPathComponent(path).path) {
            _ = try ProjectLocalFile.requireHash(reference.sha256, at: path, dataRoot: access.dataRoot)
        } else { files.append((path, bytes)) }
        try revalidate()
        try access.publish(files, captureLineage: false) {
            try revalidate()
            guard try assignmentPolicy(workflow: access.workflow, dataRoot: root).allowed else { throw changed() }
            _ = try requirePreparation(dataRoot: root)
        }
        return preparation
    }

    nonisolated static func readSnapshot(dataRoot: URL) throws -> Snapshot {
        let preparation = try requirePreparation(dataRoot: dataRoot)
        let storyboard = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let inputs = try sourceInputs(dataRoot: dataRoot)
        let home = FrameInventory.projectHome(of: dataRoot)
        let pack: ProjectPackBinding?
        switch ProjectPluginSettings.bindingResolution(projectURL: home) {
        case .absent: pack = nil
        case .bound(let binding): pack = binding
        default: throw changed()
        }
        let core: HostProductionContractBinding?
        switch ProjectPluginSettings.productionContractResolution(projectURL: home) {
        case .absent: core = nil
        case .bound(let binding): core = binding
        default: throw changed()
        }
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot, expectedPack: pack,
            expectedProductionContract: core) else { throw changed() }
        let resolutions = try resolutions(preparation: preparation, workflowID: workflow.contractID, dataRoot: dataRoot)
        var ranges: [String: SourceFootageRangeV1] = [:]
        for shot in inputs.draftValue.shots {
            if let range = shot.sourceInputRange { ranges[shot.shotID] = range }
            else if let obligationID = shot.sourceObligationID,
                    resolutions.contains(where: { $0.shotID == shot.shotID && $0.obligationID == obligationID }) {
                ranges[shot.shotID] = try resolvedSourceRange(shotID: shot.shotID, obligationID: obligationID, dataRoot: dataRoot)
            }
        }
        let ledgerHash: String
        if FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(ledgerPath).path) {
            ledgerHash = try FileDigest.sha256(of: ProjectLocalFile.resolve(ledgerPath, dataRoot: dataRoot))
        } else { ledgerHash = "absent" }
        let identity = ["preparation": try FileDigest.sha256(of: ProjectLocalFile.resolve(preparationPath, dataRoot: dataRoot)),
            "ledger": ledgerHash,
            "storyboard": storyboard.fingerprint, "draft": inputs.draft.sha256, "bible": inputs.bible.sha256,
            "graph": preparation.graph.sha256]
        let fingerprint = FileDigest.sha256(of: try PlanningWriterIO.json(identity))
        let assets = try graph(preparation.graph, dataRoot: dataRoot).assets
        var eligible: [String: [String]] = [:]
        for shot in inputs.draftValue.shots {
            for obligation in shot.obligations {
                eligible[shot.shotID + ":" + obligation.id] = assets.filter {
                    (try? validateResolution(asset: $0, obligation: obligation, bible: inputs.bibleValue,
                        source: shot.source, sourceMode: shot.sourceMode)) != nil
                }.map(\.id)
            }
        }
        let policy = try assignmentPolicy(workflow: workflow, dataRoot: dataRoot)
        return Snapshot(preparation: preparation, draft: inputs.draftValue, timing: storyboard.timing,
            assets: assets, resolutions: resolutions, sourceRanges: ranges, fingerprint: fingerprint, eligibleAssetIDs: eligible,
            canAssign: policy.allowed, assignmentMessage: policy.message)
    }

    nonisolated static func availableAssets(dataRoot: URL) throws -> [AssetGraphNodeV1] {
        let preparation = try requirePreparation(dataRoot: dataRoot)
        return try graph(preparation.graph, dataRoot: dataRoot).assets
    }

    nonisolated static func draftFingerprint(dataRoot: URL) throws -> String {
        try sourceInputs(dataRoot: dataRoot).draft.sha256
    }

    static func recordResolution(shotID: String, obligationID: String, assetID: String?, skipReason: String?,
                                 sourceInputRange: SourceFootageRangeV1? = nil, expectedDraftFingerprint: String,
                                 expectedPreparationFingerprint: String, editor: EditorViewModel) async throws {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home),
              let key = editor.openWorkingCopyKey,
              let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Assign production asset") else {
            throw GateBlocked("Finish the current production action before assigning an asset.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: declaration.binding,
            expectedProductionContract: declaration.productionContract) else { throw changed() }
        let state = try ProjectStateBuilder.buildSnapshot(dataRoot: root, order: PhaseContractRuntime.order(workflow: workflow))
        guard let phase = state.nextPhase, ["bible", "shotlist"].contains(phase) else {
            throw GateBlocked("Assign draft obligations during Bible or Shot List. Rewind before revising approved planning.")
        }
        let access = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: phase)
        let policy = try assignmentPolicy(workflow: workflow, dataRoot: root)
        guard policy.allowed else { throw GateBlocked(policy.message ?? "Rewind to Bible before changing promoted reference assignments.") }
        let shown = try await Task.detached(priority: .userInitiated) { try readSnapshot(dataRoot: root) }.value
        let preparation = shown.preparation
        guard preparation.draft.sha256 == expectedDraftFingerprint, shown.fingerprint == expectedPreparationFingerprint else { throw changed() }
        let inputs = try await Task.detached(priority: .userInitiated) { try sourceInputs(dataRoot: root) }.value
        guard let shot = inputs.draftValue.shots.first(where: { $0.shotID == shotID }),
              let obligation = shot.obligations.first(where: { $0.id == obligationID }),
              (assetID == nil) != (skipReason == nil) else { throw GateBlocked("Choose an actual asset or the draft's explicit optional alternative.") }
        let assets = try await Task.detached(priority: .userInitiated) { try graph(preparation.graph, dataRoot: root) }.value
        let outcome: ShotPlanningPromotionV1.Resolution.Outcome
        if let assetID {
            guard let asset = assets.assets.first(where: { $0.id == assetID }) else { throw changed() }
            try await Task.detached(priority: .userInitiated) {
                try await validateAssets(assets, bible: inputs.bibleValue, draft: inputs.draftValue, dataRoot: root)
            }.value
            try validateResolution(asset: asset, obligation: obligation, bible: inputs.bibleValue,
                source: shot.source, sourceMode: shot.sourceMode)
            if obligation.kind == .sourceFootage {
                guard let range = sourceInputRange, range.source.path == asset.path, range.source.sha256 == asset.sha256,
                      let duration = asset.durationSeconds else { throw GateBlocked("Select the exact source range for this footage assignment.") }
                try range.validate()
                let end = range.startTicks.addingReportingOverflow(range.durationTicks)
                guard !end.overflow, range.timebase.seconds(for: end.partialValue) <= duration else { throw changed() }
                if shot.sourceMode == .imported {
                    guard let planned = shown.timing.shots.first(where: { $0.id == shotID }),
                          range.timebase.representsSameTime(range.durationTicks, as: planned.durationTicks, timebase: shown.timing.timebase) else {
                        throw GateBlocked("Select an imported source range with exactly the planned shot duration.")
                    }
                }
            } else if sourceInputRange != nil { throw changed() }
            outcome = .asset(assetID: asset.id, evidence: .init(id: asset.id, role: "core.production-asset", path: asset.path, sha256: asset.sha256))
        } else {
            guard sourceInputRange == nil, !obligation.required, let skipReason, skipReason == obligation.allowedSkipReason else {
                throw GateBlocked("This obligation is required or its proposed alternative changed. Revise Shot Planning first.")
            }
            outcome = .skipped(reason: skipReason)
        }
        try Task.checkCancellation()
        let current = try await Task.detached(priority: .userInitiated) { try readSnapshot(dataRoot: root) }.value
        guard editor.workingRoot == home, editor.openWorkingCopyKey == key,
              editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: root, id: lease),
              current.fingerprint == expectedPreparationFingerprint, current.canAssign else { throw changed() }
        try access.revalidate()
        var ledger = try ledgerIfCurrent(preparation: preparation, workflowID: workflow.contractID, dataRoot: root)
        let id = UUID().uuidString.lowercased()
        let receipt = ResolutionReceipt(schema: "native-obligation-resolution/v1", id: id, projectID: preparation.projectID,
            workflowID: workflow.contractID, draft: preparation.draft, bible: preparation.bible, graphSHA256: preparation.graph.sha256,
            shotID: shotID, obligationID: obligationID, outcome: outcome, nativeSelectedAt: ISO8601DateFormatter().string(from: Date()),
            sourceInputRange: sourceInputRange)
        let path = "shot-planning/resolution-receipts/" + id + ".v1.json"
        let bytes = try PlanningWriterIO.json(receipt)
        let reference = PlanningWriterIO.reference(path, id: id, role: "host.obligation-resolution", bytes: bytes)
        ledger.resolutions.removeAll { $0.shotID == shotID && $0.obligationID == obligationID }
        ledger.resolutions.append(.init(shotID: shotID, obligationID: obligationID, outcome: outcome, confirmationReceipt: reference))
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else { throw changed() }
        try ProjectWorkingCopy.markDirty(key: key)
        try access.publish([(path, bytes), (ledgerPath, try PlanningWriterIO.json(ledger))], captureLineage: false) {
            guard try assignmentPolicy(workflow: workflow, dataRoot: root).allowed else { throw changed() }
            try requireNativeResolutions(ledger.resolutions, draft: preparation.draft, bible: preparation.bible,
                graphSHA256: preparation.graph.sha256, workflowID: workflow.contractID, projectID: preparation.projectID, dataRoot: root)
        }
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
    }

    nonisolated static func resolvedSourceRange(shotID: String, obligationID: String, dataRoot: URL) throws -> SourceFootageRangeV1? {
        let ledger = try PlanningWriterIO.read(Ledger.self, at: ledgerPath, dataRoot: dataRoot)
        guard let resolution = ledger.resolutions.first(where: { $0.shotID == shotID && $0.obligationID == obligationID }) else { return nil }
        return try decode(ResolutionReceipt.self, reference: resolution.confirmationReceipt, dataRoot: dataRoot).sourceInputRange
    }

    nonisolated static func resolutions(preparation: Preparation, workflowID: String, dataRoot: URL) throws -> [ShotPlanningPromotionV1.Resolution] {
        let ledger = try ledgerIfCurrent(preparation: preparation, workflowID: workflowID, dataRoot: dataRoot)
        try requireNativeResolutions(ledger.resolutions, draft: preparation.draft, bible: preparation.bible,
            graphSHA256: preparation.graph.sha256, workflowID: workflowID, projectID: preparation.projectID, dataRoot: dataRoot)
        return ledger.resolutions
    }

    nonisolated static func requireCurrent(projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> ShotPlanningPromotionV1 {
        let value = try PlanningWriterIO.read(ShotPlanningPromotionV1.self, at: ShotPlanningPromotionV1.currentPath, dataRoot: dataRoot)
        let version = try PlanningWriterIO.read(ShotPlanningPromotionV1.self,
            at: ShotPlanningPromotionV1.versionPath(value.header.revision), dataRoot: dataRoot)
        guard value == version, value.header.revision == projection.header.revision else { throw changed() }
        let preparation = try requirePreparation(dataRoot: dataRoot)
        guard preparation.draft == value.draft, preparation.bible == value.bible,
              preparation.graph.sha256 == value.assetGraph.sha256 else { throw changed() }
        let storyboard = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: storyboard)
        try PipelineShotPlanningWriter.requireSpatialInputs(draft, dataRoot: dataRoot)
        guard let bible = try loadBible(dataRoot: dataRoot) else { throw GateBlocked("The production Bible is missing.") }
        try PipelineProductionAssetEvidence.requireBible(bible, dataRoot: dataRoot)
        let graph = try plannedGraph(promotion: value, dataRoot: dataRoot)
        try value.requireCurrentEvidence(draft: draft, timing: storyboard.timing, bible: bible, assetGraph: graph,
            projection: projection, dataRoot: dataRoot, verifier: requireNativeEvidence)
        try ProductionPlanProjectionValidatorV1.validate(projection, storyboard: storyboard, draft: draft)
        try requirePlannedInputs(projection: projection, promotion: value, draft: draft, graph: graph, bible: bible, dataRoot: dataRoot)
        for intent in draft.shots where intent.sourceMode != .generated {
            let selected: SourceFootageRangeV1?
            if let range = intent.sourceInputRange { selected = range }
            else if let obligationID = intent.sourceObligationID {
                selected = try resolvedSourceRange(shotID: intent.shotID, obligationID: obligationID, dataRoot: dataRoot)
            } else { selected = nil }
            guard let selected, let source = projection.source(for: intent.shotID),
                  selected.source.path == source.path, selected.source.sha256 == source.sha256,
                  let asset = graph.assets.first(where: { $0.path == source.path && $0.sha256 == source.sha256 }),
                  let duration = asset.durationSeconds else { throw changed() }
            try selected.validate()
            let end = selected.startTicks.addingReportingOverflow(selected.durationTicks)
            guard !end.overflow, selected.timebase.seconds(for: end.partialValue) <= duration else { throw changed() }
            if intent.sourceMode == .aiEnhanced {
                guard let actual = projection.sourceInputRanges.first(where: { $0.shotID == intent.shotID }),
                      actual.timebase == selected.timebase, actual.startTicks == selected.startTicks,
                      actual.durationTicks == selected.durationTicks else { throw changed() }
            } else {
                guard let timing = projection.timing(for: intent.shotID),
                      projection.timebase.representsSameTime(timing.sourceInTicks, as: selected.startTicks, timebase: selected.timebase),
                      projection.timebase.representsSameTime(timing.durationTicks, as: selected.durationTicks, timebase: selected.timebase) else { throw changed() }
            }
        }
        return value
    }

    nonisolated private static func requirePlannedInputs(projection: ProductionPlanProjectionV1, promotion: ShotPlanningPromotionV1,
        draft: ShotPlanningDraftV1, graph: AssetGraphV1, bible: Bible, dataRoot: URL) throws {
        let musicvideo = projection.executionPlan.extensionReferences.contains { $0.id == MusicvideoProductionExtensionV2.artifactID }
            ? try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: dataRoot) : nil
        for (shot, intent) in zip(projection.shots, draft.shots) {
            guard shot.blocking.allSatisfy({ bible.lookupId($0.entityID) != nil }) else { throw changed() }
            if shot.generationRequirement == nil {
                try requireSpatialDemands(intent: intent, shot: shot, demands: [], graph: graph, dataRoot: dataRoot)
                continue
            }
            guard let requirement = shot.generationRequirement else { throw changed() }
            guard requirement.maximumCost == nil, let timing = projection.timing(for: shot.id) else { throw changed() }
            let template = try inputTemplate(for: shot.id, promotion: promotion, dataRoot: dataRoot)
            guard template.projectID == projection.header.projectID, template.shotID == shot.id else { throw changed() }
            try ProductionInputTemplateValidatorV1.validate(template, requirement: requirement,
                chainedFromPredecessor: intent.chainKind == .frameContinuation)
            if intent.chainKind == .nativeExtension {
                guard requirement.sourceVideoAssetID == PipelineProductionPlanWriter.predecessorVideoRecipe(shotID: shot.id) else { throw changed() }
            } else if shot.sourceMode == .aiEnhanced {
                guard requirement.sourceVideoAssetID == projection.source(for: shot.id)?.id else { throw changed() }
            } else if requirement.sourceVideoAssetID != nil { throw changed() }
            let demands = try plannedDemands(for: shot.id, promotion: promotion, dataRoot: dataRoot)
            guard demands.projectID == projection.header.projectID, demands.shotID == shot.id else { throw changed() }
            try AssetGraphValidatorV1.validate(demands, against: graph, assetGraphPath: promotion.assetGraph.path)
            try PipelineProductionPlanWriter.validateRealDemands(demands.demands, requirement: requirement, graph: graph)
            try requireSpatialDemands(intent: intent, shot: shot, demands: demands.demands, graph: graph, dataRoot: dataRoot)
            let sourceDuration: Double?
            if intent.chainKind == .nativeExtension, let predecessor = intent.predecessorShotID,
               let plannedPredecessor = projection.timing(for: predecessor) {
                sourceDuration = projection.timebase.seconds(for: plannedPredecessor.nativeDurationTicks ?? plannedPredecessor.durationTicks)
            } else if let range = projection.sourceInputRanges.first(where: { $0.shotID == shot.id }) {
                sourceDuration = range.timebase.seconds(for: range.durationTicks)
            } else { sourceDuration = nil }
            let complete = PipelineProductionPlanWriter.plannedDemands(real: demands, template: template, intent: intent,
                timing: timing, timebase: projection.timebase, requirement: requirement, sourceDurationSeconds: sourceDuration,
                audioDurationSeconds: musicvideo?.performanceSegments.first(where: { $0.draft.shotIDs.contains(shot.id) }).map {
                    Double($0.draft.sourceEndSample - $0.draft.sourceStartSample) / Double($0.draft.sampleRate)
                })
            if ShotDeliveryModeResolverV1.resolve(shot) == .timelineAnimatedStill {
                guard template.coreInputs == ProductionCoreInputModesV1(), requirement.duration == nil,
                      timing.nativeDurationTicks == nil, timing.sourceInTicks == 0 else { throw changed() }
                continue
            }
            let stored = try route(for: shot.id, promotion: promotion, dataRoot: dataRoot)
            let candidate = ProductionRouteCandidateV1(capabilities: stored.capabilitySnapshot.capabilities,
                providerActivated: true, liveAvailable: true, qualityScore: stored.qualityScore, preferenceScore: stored.preferenceScore,
                qualityTargetIDs: stored.capabilitySnapshot.qualityTargetIDs,
                satisfiedProductionProfileRequirementIDs: stored.capabilitySnapshot.satisfiedProductionProfileRequirementIDs,
                inputSlots: stored.capabilitySnapshot.inputSlots, estimatedCost: stored.estimatedCost,
                estimatedLatencySeconds: stored.estimatedLatencySeconds)
            guard case .matched(let expected, _) = try ProductionRequirementResolverV1.plannedRoute(requirement: requirement,
                demandSet: complete, assetGraph: graph, candidate: candidate), expected == stored else { throw changed() }
        }
    }

    nonisolated static func plannedGraph(promotion: ShotPlanningPromotionV1, dataRoot: URL) throws -> AssetGraphV1 {
        try graph(promotion.assetGraph, dataRoot: dataRoot)
    }

    nonisolated static func route(for shotID: String, promotion: ShotPlanningPromotionV1, dataRoot: URL) throws -> ProductionRouteV1 {
        guard let reference = promotion.routes.first(where: { $0.shotID == shotID })?.route else { throw changed() }
        return try decode(ProductionRouteV1.self, reference: reference, dataRoot: dataRoot)
    }

    nonisolated static func inputTemplate(for shotID: String, promotion: ShotPlanningPromotionV1, dataRoot: URL) throws -> ProductionInputTemplateV1 {
        try input(ProductionInputTemplateV1.self, path: ShotPlanningPromotionV1.inputTemplatePath(shotID: shotID, revision: promotion.header.revision),
                  promotion: promotion, dataRoot: dataRoot)
    }

    nonisolated static func plannedDemands(for shotID: String, promotion: ShotPlanningPromotionV1, dataRoot: URL) throws -> ReferenceDemandSetV1 {
        try input(ReferenceDemandSetV1.self, path: ShotPlanningPromotionV1.demandPath(shotID: shotID, revision: promotion.header.revision),
                  promotion: promotion, dataRoot: dataRoot)
    }

    nonisolated static func requirePreparation(dataRoot: URL) throws -> Preparation {
        let value = try PlanningWriterIO.read(Preparation.self, at: preparationPath, dataRoot: dataRoot)
        let inputs = try sourceInputs(dataRoot: dataRoot)
        guard value.schema == "production-asset-preparation/v1", value.projectID == inputs.draftValue.header.projectID,
              value.draft == inputs.draft, value.bible == inputs.bible else { throw changed() }
        _ = try graph(value.graph, dataRoot: dataRoot)
        return value
    }

    nonisolated private static func assignmentPolicy(workflow: HostWorkflowKey, dataRoot: URL) throws -> (allowed: Bool, message: String?) {
        let state = try ProjectStateBuilder.buildSnapshot(dataRoot: dataRoot, order: PhaseContractRuntime.order(workflow: workflow))
        if state.nextPhase == "bible" { return (true, nil) }
        if state.nextPhase == "shotlist" {
            let candidate = dataRoot.appendingPathComponent(ShotPlanningPromotionV1.currentPath)
            let hasPromotion = FileManager.default.fileExists(atPath: candidate.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil
            let directory = dataRoot.appendingPathComponent("shot-planning")
            let hasHistory = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.contains {
                $0.hasPrefix("promotion-v") && $0.hasSuffix(".v1.json")
            } ?? false
            if !hasPromotion && !hasHistory { return (true, nil) }
        }
        if state.phases.first(where: { $0.phase == "bible" })?.approved == true {
            return (false, "Select References in the workflow dock and choose Revise References to change approved assignments.")
        }
        if let next = state.nextPhase {
            return (false, "Complete \(PhaseDisplay.label(next)) in the workflow dock before changing reference assignments.")
        }
        return (false, "Select References in the workflow dock and review its current requirements before changing assignments.")
    }

    nonisolated private static func ledgerIfCurrent(preparation: Preparation, workflowID: String, dataRoot: URL) throws -> Ledger {
        guard FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(ledgerPath).path) else {
            return Ledger(schema: "obligation-resolution-ledger/v1", projectID: preparation.projectID, workflowID: workflowID,
                          preparation: preparation, resolutions: [])
        }
        let value = try PlanningWriterIO.read(Ledger.self, at: ledgerPath, dataRoot: dataRoot)
        guard value.schema == "obligation-resolution-ledger/v1", value.projectID == preparation.projectID,
              value.workflowID == workflowID else { throw changed() }
        if value.preparation != preparation {
            return Ledger(schema: value.schema, projectID: preparation.projectID, workflowID: workflowID, preparation: preparation, resolutions: [])
        }
        return value
    }

    nonisolated private static func requireNativeEvidence(_ value: ShotPlanningPromotionV1, _ root: URL) throws {
        let home = FrameInventory.projectHome(of: root)
        let pack: ProjectPackBinding?
        switch ProjectPluginSettings.bindingResolution(projectURL: home) {
        case .absent: pack = nil
        case .bound(let value): pack = value
        default: throw changed()
        }
        let core: HostProductionContractBinding?
        switch ProjectPluginSettings.productionContractResolution(projectURL: home) {
        case .absent: core = nil
        case .bound(let value): core = value
        default: throw changed()
        }
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: pack,
            expectedProductionContract: core) else { throw changed() }
        try requireNativeResolutions(value.resolutions, draft: value.draft, bible: value.bible,
            graphSHA256: value.assetGraph.sha256, workflowID: workflow.contractID, projectID: value.header.projectID, dataRoot: root)
    }

    nonisolated private static func requireNativeResolutions(_ resolutions: [ShotPlanningPromotionV1.Resolution],
        draft: CanonicalArtifactReferenceV1, bible: CanonicalArtifactReferenceV1, graphSHA256: String,
        workflowID: String, projectID: String, dataRoot: URL) throws {
        var keys = Set<String>()
        for resolution in resolutions {
            let ref = resolution.confirmationReceipt
            let receipt = try decode(ResolutionReceipt.self, reference: ref, dataRoot: dataRoot)
            guard keys.insert(resolution.shotID + ":" + resolution.obligationID).inserted,
                  ref.role == "host.obligation-resolution", ref.id == receipt.id,
                  ref.path == "shot-planning/resolution-receipts/" + receipt.id + ".v1.json",
                  UUID(uuidString: receipt.id) != nil, receipt.schema == "native-obligation-resolution/v1",
                  receipt.projectID == projectID, receipt.workflowID == workflowID, receipt.draft == draft,
                  receipt.bible == bible, receipt.graphSHA256 == graphSHA256,
                  receipt.shotID == resolution.shotID, receipt.obligationID == resolution.obligationID,
                  receipt.outcome == resolution.outcome, !receipt.nativeSelectedAt.isEmpty else { throw changed() }
        }
        if !resolutions.isEmpty {
            let ledger = try PlanningWriterIO.read(Ledger.self, at: ledgerPath, dataRoot: dataRoot)
            guard ledger.resolutions == resolutions, ledger.preparation.draft == draft,
                  ledger.preparation.bible == bible, ledger.preparation.graph.sha256 == graphSHA256,
                  ledger.projectID == projectID, ledger.workflowID == workflowID else { throw changed() }
        }
    }

    nonisolated private static func sourceInputs(dataRoot: URL) throws -> (draft: CanonicalArtifactReferenceV1, bible: CanonicalArtifactReferenceV1,
                                                               draftValue: ShotPlanningDraftV1, bibleValue: Bible) {
        let storyboard = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: storyboard)
        try PipelineShotPlanningWriter.requireSpatialInputs(draft, dataRoot: dataRoot)
        guard let bible = try loadBible(dataRoot: dataRoot) else { throw GateBlocked("Create the Bible before resolving production obligations.") }
        try PipelineProductionAssetEvidence.requireBible(bible, dataRoot: dataRoot)
        return (try PlanningWriterIO.reference(ShotPlanningDraftV1.versionPath(draft.header.revision), id: "shot-planning.draft",
                    role: "core.shot-planning-draft", dataRoot: dataRoot),
                try PlanningWriterIO.reference(PipelineLayout.bibleFile, id: "bible", role: "core.bible", dataRoot: dataRoot), draft, bible)
    }

    nonisolated static func normalizeAsset(_ asset: AssetGraphNodeV1, bible: Bible, dataRoot: URL) throws -> AssetGraphNodeV1 {
        if let sequence = try spatialShotEvidence(asset, dataRoot: dataRoot) {
            guard asset.entityID == nil, asset.stateID == nil, asset.viewID == nil else { throw changed() }
            try PipelineProductionAssetEvidence.requireReferencePurpose(path: asset.path, sha256: asset.sha256,
                semanticJobID: CoreReferenceSemanticJobIDV1.motionReference, dataRoot: dataRoot, geometry: true)
            return try AssetGraphContentAddressV1.reidentified(.init(id: "pending", version: asset.version, path: asset.path,
                sha256: asset.sha256, modality: .video, approval: asset.approval,
                provenance: .init(kindID: PlanningSpatialAssetV1.provenanceKindID, sourceShotID: sequence.shotID,
                    sourceRoleID: PlanningSpatialAssetV1.sourceRoleID, sourceProofPath: sequence.proof.path,
                    sourceProofSHA256: sequence.proof.sha256, recordedAt: asset.provenance.recordedAt),
                allowedUseIDs: asset.allowedUseIDs, durationSeconds: asset.durationSeconds))
        }
        guard let id = asset.entityID, case .location(let location)? = bible.lookupId(id) else {
            guard asset.provenance.kindID != PlanningSpatialAssetV1.provenanceKindID else { throw changed() }
            try PipelineProductionAssetEvidence.requireReferencePurpose(path: asset.path, sha256: asset.sha256,
                semanticJobID: "appearance-or-source", dataRoot: dataRoot)
            return asset
        }
        let evidence = try spatialAssetEvidence(asset, location: location, dataRoot: dataRoot)
        guard let proof = evidence.first(where: { $0.role == "core.spatial-derivation" || $0.role == "host.panorama-selection" }) else {
            guard asset.provenance.kindID != PlanningSpatialAssetV1.provenanceKindID else { throw changed() }
            try PipelineProductionAssetEvidence.requireReferencePurpose(path: asset.path, sha256: asset.sha256,
                semanticJobID: "appearance-or-source", dataRoot: dataRoot)
            return asset
        }
        let provenance = AssetProvenanceV1(kindID: PlanningSpatialAssetV1.provenanceKindID,
            sourceRoleID: PlanningSpatialAssetV1.sourceRoleID, sourceProofPath: proof.path, sourceProofSHA256: proof.sha256,
            recordedAt: asset.provenance.recordedAt)
        return try AssetGraphContentAddressV1.reidentified(.init(id: "pending", version: asset.version, path: asset.path,
            sha256: asset.sha256, modality: asset.modality, entityID: asset.entityID, canonIDs: asset.canonIDs,
            stateID: asset.stateID,
            viewID: proof.role == "host.panorama-selection" ? location.scene3d.povs.first(where: {
                asset.path == (location.scene3d.panorama as NSString).deletingLastPathComponent + "/" + $0.name + ".png"
            })?.name : asset.viewID,
            approval: asset.approval, provenance: provenance,
            allowedUseIDs: asset.allowedUseIDs, durationSeconds: asset.durationSeconds))
    }

    nonisolated private static func spatialShotEvidence(_ asset: AssetGraphNodeV1, dataRoot: URL)
        throws -> (shotID: String, proof: CanonicalArtifactReferenceV1, references: [CanonicalArtifactReferenceV1])? {
        guard asset.modality == .video else { return nil }
        let board = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: board)
        for shot in draft.shots {
            if let reference = shot.camera.blockingReference,
               let refs = try PipelineNativeBlockoutStore.matchingVideoReferences(reference, shot: shot,
                   path: asset.path, sha256: asset.sha256, dataRoot: dataRoot) {
                return (shot.shotID, reference, refs)
            }
            guard let reference = shot.camera.spatialDerivation, let state = shot.camera.spatialState,
                  let camera = shot.camera.spatialCameraID, let scene = shot.camera.sceneReference else { continue }
            let references = try PipelineSpatialDerivationWriter.planningDerivationReferences(reference: reference,
                stateReference: state, cameraID: camera, sceneReference: scene, shotID: shot.shotID, dataRoot: dataRoot)
            if references.contains(where: { $0.role == "core.shot-clay-video" && $0.path == asset.path && $0.sha256 == asset.sha256 }) {
                return (shot.shotID, reference, references)
            }
        }
        return nil
    }

    nonisolated static func requireSpatialDemands(intent: ShotPlanningDraftV1.ShotIntent, shot: ExecutionShotV1,
        demands: [ReferenceDemandV1], graph: AssetGraphV1, dataRoot: URL) throws {
        if let reference = intent.camera.blockingReference, let clip = try PipelineNativeBlockoutStore.video(for: intent, dataRoot: dataRoot) {
            guard ShotDeliveryModeResolverV1.resolve(shot) == .providerVideo,
                  let asset = graph.assets.first(where: { $0.modality == .video && $0.path == clip.path && $0.sha256 == clip.sha256
                    && $0.provenance.kindID == PlanningSpatialAssetV1.provenanceKindID && $0.provenance.sourceShotID == intent.shotID
                    && $0.provenance.sourceProofPath == reference.path && $0.provenance.sourceProofSHA256 == reference.sha256 }),
                  let demand = demands.first(where: { $0.assetID == asset.id && $0.isRequired }) else {
                throw GateBlocked("This shot's confirmed blockout clip needs video delivery and its actual bytes as a required geometry motion reference.")
            }
            try PlanningSpatialAssetV1.requireDemandPurpose(demand, asset: asset, targetShotID: intent.shotID)
        }
        guard let reference = intent.camera.spatialDerivation, let state = intent.camera.spatialState,
              let camera = intent.camera.spatialCameraID, let scene = intent.camera.sceneReference else { return }
        let references = try PipelineSpatialDerivationWriter.planningDerivationReferences(reference: reference,
            stateReference: state, cameraID: camera, sceneReference: scene, shotID: intent.shotID, dataRoot: dataRoot)
        guard ShotDeliveryModeResolverV1.resolve(shot) == .providerVideo,
              let clip = references.first(where: { $0.role == "core.shot-clay-video" }),
              let asset = graph.assets.first(where: { $0.modality == .video && $0.path == clip.path && $0.sha256 == clip.sha256
                && $0.provenance.kindID == PlanningSpatialAssetV1.provenanceKindID && $0.provenance.sourceShotID == intent.shotID
                && $0.provenance.sourceProofPath == reference.path && $0.provenance.sourceProofSHA256 == reference.sha256 }),
              let demand = demands.first(where: { $0.assetID == asset.id && $0.isRequired }) else {
            throw GateBlocked("This shot's native Clay animation needs video delivery and its actual clip as a required geometry motion reference.")
        }
        try PlanningSpatialAssetV1.requireDemandPurpose(demand, asset: asset, targetShotID: intent.shotID)
    }

    nonisolated private static func spatialAssetEvidence(_ asset: AssetGraphNodeV1, location: Location,
                                                         dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        if asset.modality == .image {
            let panorama = try PipelinePanoramaStore.references(location: location, dataRoot: dataRoot)
            if panorama.contains(where: { $0.role == "core.panorama-pov-geometry" && $0.path == asset.path && $0.sha256 == asset.sha256 }) { return panorama }
        }
        if asset.modality == .image, let view = location.sheets.first(where: { $0.value == asset.path })?.key {
            return try PipelineSpatialDerivationWriter.bibleViewReferences(location: location, viewID: view, dataRoot: dataRoot) ?? []
        }
        guard asset.modality == .geometry,
              try PipelineSpatialDerivationWriter.bibleGeometryReferences(location: location, dataRoot: dataRoot)
                .contains(where: { $0.path == asset.path && $0.sha256 == asset.sha256 }) else { return [] }
        return try location.sheets.keys.sorted().flatMap { view -> [CanonicalArtifactReferenceV1] in
            let references = try PipelineSpatialDerivationWriter.bibleViewReferences(location: location, viewID: view, dataRoot: dataRoot) ?? []
            return references.contains(where: { $0.path == asset.path && $0.sha256 == asset.sha256 }) ? references : []
        }
    }

    nonisolated private static func validateAssets(_ graph: AssetGraphV1, bible: Bible, draft: ShotPlanningDraftV1, dataRoot: URL) async throws {
        guard graph.projectID == bible.project else { throw changed() }
        try AssetGraphValidatorV1.validateProjectFiles(graph, dataRoot: dataRoot)
        try PipelineSpatialSceneAuthority.requireCurrent(dataRoot: dataRoot)
        let design = try YAMLArtifactStore(dataRoot: dataRoot).load(ProductionDesign.self, at: PipelineLayout.productionDesignFile)
        for asset in graph.assets {
            let url = try ProjectLocalFile.requireHash(asset.sha256, at: asset.path, dataRoot: dataRoot)
            guard asset.approval == .approved, ["core.planning-asset", PlanningSpatialAssetV1.provenanceKindID].contains(asset.provenance.kindID),
                  asset.provenance.modelID == nil, asset.provenance.promptSHA256 == nil,
                  asset.provenance.sourceAssetID == nil,
                  asset.provenance.kindID != CoreAssetProvenanceKindIDV1.approvedFrame,
                  asset.provenance.kindID != CoreAssetProvenanceKindIDV1.renderFrame,
                  (asset.provenance.sourceShotID == nil || (asset.provenance.kindID == PlanningSpatialAssetV1.provenanceKindID && asset.modality == .video)) else { throw GateBlocked("Planning assets cannot claim future Frame or Take provenance.") }
            try PipelineProductionAssetEvidence.requireReferencePurpose(path: asset.path, sha256: asset.sha256,
                semanticJobID: "planning-asset", dataRoot: dataRoot, geometry: asset.provenance.kindID == PlanningSpatialAssetV1.provenanceKindID)
            if asset.provenance.kindID == PlanningSpatialAssetV1.provenanceKindID, asset.modality == .video {
                guard asset.entityID == nil, asset.stateID == nil, asset.viewID == nil,
                      let sequence = try spatialShotEvidence(asset, dataRoot: dataRoot),
                      asset.provenance.sourceShotID == sequence.shotID,
                      asset.provenance.sourceProofPath == sequence.proof.path, asset.provenance.sourceProofSHA256 == sequence.proof.sha256,
                      asset.allowedUseIDs.allSatisfy({ ProductionIdentifierNormalizerV1.matches($0, CoreReferenceSemanticJobIDV1.motionReference) }) else { throw changed() }
            } else if asset.provenance.kindID == PlanningSpatialAssetV1.provenanceKindID {
                guard let id = asset.entityID, case .location(let location)? = bible.lookupId(id) else { throw changed() }
                let evidence = try spatialAssetEvidence(asset, location: location, dataRoot: dataRoot)
                guard evidence.contains(where: { ($0.role == "core.spatial-derivation" || $0.role == "host.panorama-selection") && $0.path == asset.provenance.sourceProofPath
                    && $0.sha256 == asset.provenance.sourceProofSHA256 }),
                      asset.allowedUseIDs.allSatisfy({ asset.modality == .image && ProductionIdentifierNormalizerV1.matches($0, CoreReferenceSemanticJobIDV1.referenceAnchor) }) else { throw changed() }
            }
            switch asset.modality {
            case .image:
                _ = try FrameRasterizer.loadImage(at: url)
                if let entityID = asset.entityID {
                    if let stateID = asset.stateID {
                        guard let variants = try BibleIdentityVariantStoreV1.loadIfPresent(dataRoot: dataRoot) else { throw changed() }
                        try BibleIdentityVariantStoreV1.validate(variants, bible: bible, dataRoot: dataRoot)
                        guard variants.variants.contains(where: { $0.variantEntityID == stateID && $0.baseEntityID == entityID }),
                              let variant = bible.lookupId(stateID), entityPaths(variant).contains(asset.path) else { throw changed() }
                    } else {
                        guard let entity = bible.lookupId(entityID) else { throw changed() }
                        var nativePOV = false
                        if case .location(let location) = entity,
                           let panorama = try PipelinePanoramaStore.current(location: location, dataRoot: dataRoot),
                           let view = panorama.views.first(where: { $0.image.path == asset.path && $0.image.sha256 == asset.sha256 }) {
                            guard asset.provenance.kindID == PlanningSpatialAssetV1.provenanceKindID,
                                  asset.viewID == view.geometry.name else { throw changed() }
                            nativePOV = true
                        }
                        guard nativePOV || entityPaths(entity).contains(asset.path) else { throw changed() }
                        if case .location(let location) = entity,
                           let viewID = location.sheets.first(where: { $0.value == asset.path })?.key,
                           let evidence = try PipelineSpatialDerivationWriter.bibleViewReferences(location: location, viewID: viewID, dataRoot: dataRoot) {
                            guard asset.provenance.kindID == PlanningSpatialAssetV1.provenanceKindID,
                                  asset.viewID == viewID,
                                  evidence.contains(where: { $0.path == asset.path && $0.sha256 == asset.sha256 }),
                                  evidence.contains(where: { $0.role == "core.spatial-derivation"
                                    && $0.path == asset.provenance.sourceProofPath && $0.sha256 == asset.provenance.sourceProofSHA256 }) else { throw changed() }
                        }
                    }
                } else {
                    guard design.refs.contains(where: { $0.path == asset.path }) || design.lightingAnchor == asset.path else {
                        throw GateBlocked("A planned image needs an actual Bible identity or approved Design role.")
                    }
                }
            case .geometry:
                guard asset.provenance.kindID == PlanningSpatialAssetV1.provenanceKindID,
                      let id = asset.entityID, case .location(let location)? = bible.lookupId(id),
                      asset.viewID == nil, asset.stateID == nil,
                      try PipelineSpatialDerivationWriter.bibleGeometryReferences(location: location, dataRoot: dataRoot)
                        .contains(where: { $0.path == asset.path && $0.sha256 == asset.sha256 }) else {
                    throw GateBlocked("Assign this scene to the same Bible location through a native spatial view before using its geometry.")
                }
                let matchingViews = try location.sheets.keys.sorted().flatMap { viewID -> [CanonicalArtifactReferenceV1] in
                    let references = try PipelineSpatialDerivationWriter.bibleViewReferences(location: location, viewID: viewID, dataRoot: dataRoot) ?? []
                    return references.contains(where: { $0.path == asset.path && $0.sha256 == asset.sha256 }) ? references : []
                }
                guard matchingViews.contains(where: { $0.role == "core.spatial-derivation"
                    && $0.path == asset.provenance.sourceProofPath && $0.sha256 == asset.provenance.sourceProofSHA256 }) else { throw changed() }
            case .video, .audio:
                let expectedType: AVMediaType = asset.modality == .video ? .video : .audio
                let measured = try await Task.detached(priority: .userInitiated) {
                    let source = AVURLAsset(url: url)
                    let duration = try await source.load(.duration)
                    let tracks = try await source.loadTracks(withMediaType: expectedType)
                    guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0, !tracks.isEmpty else {
                        throw GateBlocked("Choose a readable source with the required media track.")
                    }
                    if expectedType == .video { _ = try await AVAssetImageGenerator(asset: source).image(at: .zero) }
                    return duration.seconds
                }.value
                guard let declared = asset.durationSeconds, measured == declared else {
                    throw GateBlocked("The planned media duration does not match its actual source.")
                }
            }
            _ = try ProjectLocalFile.requireHash(asset.sha256, at: asset.path, dataRoot: dataRoot)
        }
    }

    nonisolated private static func validateResolution(asset: AssetGraphNodeV1, obligation: ShotPlanningDraftV1.Obligation,
                                                       bible: Bible, source: CanonicalArtifactReferenceV1?, sourceMode: SourceMode) throws {
        guard sourceMode != .generated || obligation.kind != .sourceFootage else {
            throw GateBlocked("Generated shots can only use this source-footage obligation's declared optional alternative.")
        }
        try ShotPlanningPromotionValidatorV1.requireAsset(asset, for: obligation, bible: bible, source: source)
    }

    nonisolated private static func entityPaths(_ entity: BibleEntity) -> [String] {
        switch entity {
        case .character(let value): value.referenceImages + Array(value.sheets.values)
        case .ensemble(let value): value.referenceImages + Array(value.sheets.values)
        case .location(let value): value.referenceImages + Array(value.sheets.values) + (value.scene3d.panorama.isEmpty ? [] : [value.scene3d.panorama])
        case .prop(let value): value.referenceImages + Array(value.sheets.values)
        }
    }

    nonisolated private static func graph(_ reference: CanonicalArtifactReferenceV1, dataRoot: URL) throws -> AssetGraphV1 {
        let value = try decode(AssetGraphV1.self, reference: reference, dataRoot: dataRoot)
        try AssetGraphValidatorV1.validateProjectFiles(value, dataRoot: dataRoot)
        return value
    }

    nonisolated private static func decode<T: Decodable>(_ type: T.Type, reference: CanonicalArtifactReferenceV1, dataRoot: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)))
    }

    nonisolated private static func input<T: Decodable>(_ type: T.Type, path: String, promotion: ShotPlanningPromotionV1, dataRoot: URL) throws -> T {
        guard let ref = promotion.header.inputs.first(where: { $0.path == path }) else { throw changed() }
        return try decode(type, reference: ref, dataRoot: dataRoot)
    }

    nonisolated private static func changed() -> GateBlocked {
        GateBlocked("Production assets or their native assignments changed. Reload the current draft and resolve its exact obligations.")
    }
}
