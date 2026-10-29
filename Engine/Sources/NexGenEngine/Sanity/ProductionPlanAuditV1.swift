import Foundation

public enum ProductionPlanAuditV1 {
    public static func run(projection: ProductionPlanProjectionV1, timing: StoryboardTimingV1,
                           profileIDs: Set<ProductionProfileID>, routes: ProductionDisciplineSidecarV1) throws -> SanityReport {
        try ProductionPlanProjectionValidatorV1.validate(projection)
        _ = try PlanningValidation.end(start: timing.rangeStartTicks, duration: timing.rangeDurationTicks)
        try PlanningValidation.require(projection.timebase == timing.timebase && projection.mode == timing.mode
            && projection.timings.map(\.shotID) == timing.shots.map(\.id), "sanity.timingBinding")
        for (actual, planned) in zip(projection.timings, timing.shots) {
            try PlanningValidation.require(actual.startTicks == planned.startTicks && actual.durationTicks == planned.durationTicks,
                                           "sanity.editorialTiming")
        }
        var findings = coverage(projection: projection, timing: timing)
        let modes = Dictionary(grouping: projection.shots, by: \.sourceMode)
        if modes[.imported] != nil || modes[.aiEnhanced] != nil {
            findings.append(.init(level: .info, code: "SOURCE_MODE_COVERAGE", message:
                "source modes — generated: \(modes[.generated]?.count ?? 0), imported: \(modes[.imported]?.count ?? 0), ai_enhanced: \(modes[.aiEnhanced]?.count ?? 0)"))
        }
        if profileIDs.contains(.generativeFilm) {
            for shot in projection.shots where shot.sourceMode != .imported {
                guard let requirement = shot.generationRequirement, let route = routes.route(for: shot.id) else {
                    findings.append(.init(level: .error, code: "PRODUCTION_ROUTE_MISSING", shotId: shot.id,
                                          message: "Resolve a current production route for this shot."))
                    continue
                }
                if let maximum = route.maximumVisibleCharacters, requirement.visibleEntityCount > maximum {
                    findings.append(.init(level: .error, code: "TOO_MANY_VISIBLE_CHARACTERS", shotId: shot.id,
                                          message: "The shot exceeds the selected route's visible-character capacity."))
                }
                if let maximum = route.maximumDurationSeconds, let duration = projection.timing(for: shot.id),
                   projection.timebase.seconds(for: duration.nativeDurationTicks ?? duration.durationTicks) > maximum,
                   !shot.risks.contains(RenderabilityRisk.longTake.rawValue) {
                    findings.append(.init(level: .error, code: "LONG_TAKE_RISK_UNDECLARED", shotId: shot.id,
                                          message: "Declare this route's duration risk and rescue or select a capable route."))
                }
                if shot.sourceMode == .generated && shot.blocking.contains(where: { $0.anchorAssetID == nil }) {
                    findings.append(.init(level: .error, code: "BLOCKING_ANCHOR_MISSING", shotId: shot.id,
                                          message: "Bind generated character blocking to a named set or prop asset."))
                }
                if !requirement.identityLockAssetIDs.isEmpty && shot.continuityLocks.isEmpty {
                    findings.append(.init(level: .warn, code: "CONTINUITY_LOCKS_MISSING", shotId: shot.id,
                                          message: "Named production assets require explicit continuity locks."))
                }
                if shot.renderability != .green && shot.rescue == nil {
                    findings.append(.init(level: .error, code: "RESCUE_CUT_MISSING", shotId: shot.id,
                                          message: "Define a rescue cut for this yellow or red shot."))
                }
            }
        }
        if profileIDs.contains(.narrativeStorytelling) {
            findings += narrative(projection)
        }
        return SanityReport(project: projection.header.projectID, findings: findings)
    }

    @discardableResult
    public static func save(projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> SanityArtifact {
        let inputs = try currentInputs(projection: projection, dataRoot: dataRoot)
        let report = try run(projection: projection, timing: inputs.timing, profileIDs: inputs.profiles, routes: inputs.routes)
        let artifact = SanityArtifact(report: report, inputFingerprint: try ProductionPlanFilesV1.fingerprint(inputs.references))
        try ProductionPlanFilesV1.require(inputs.references, dataRoot: dataRoot)
        try JSONArtifactStore(dataRoot: dataRoot).save(artifact, to: PipelineLayout.sanityReportFile)
        return artifact
    }

    public static func report(projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> SanityReport {
        let inputs = try currentInputs(projection: projection, dataRoot: dataRoot)
        let result = try run(projection: projection, timing: inputs.timing, profileIDs: inputs.profiles, routes: inputs.routes)
        try ProductionPlanFilesV1.require(inputs.references, dataRoot: dataRoot)
        return result
    }

    @discardableResult
    public static func requireCurrent(projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> SanityArtifact {
        let inputs = try currentInputs(projection: projection, dataRoot: dataRoot)
        let reportReference = try ProductionPlanFilesV1.reference(PipelineLayout.sanityReportFile, dataRoot: dataRoot)
        let artifact = try SanityArtifactStore.load(dataRoot: dataRoot)
        let actual = try run(projection: projection, timing: inputs.timing, profileIDs: inputs.profiles, routes: inputs.routes)
        try PlanningValidation.require(artifact.schema == "sanity/v1" && artifact.project == projection.header.projectID
            && artifact.inputFingerprint == ProductionPlanFilesV1.fingerprint(inputs.references)
            && artifact.findings == actual.findings && artifact.errors.isEmpty, "sanity.currentReport")
        try ProductionPlanFilesV1.require(inputs.references + [reportReference], dataRoot: dataRoot)
        return artifact
    }

    public static func artifactReferences(projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        try currentInputs(projection: projection, dataRoot: dataRoot).references
    }

    private struct Inputs {
        let timing: StoryboardTimingV1
        let profiles: Set<ProductionProfileID>
        let routes: ProductionDisciplineSidecarV1
        let references: [CanonicalArtifactReferenceV1]
    }

    private static func currentInputs(projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> Inputs {
        let bundle = try ProductionPlanFilesV1.planningInputs(projection, dataRoot: dataRoot)
        let briefURL = try ProjectLocalFile.resolve(PipelineLayout.briefFile, dataRoot: dataRoot)
        let brief = try YAMLCoding.decode(Brief.self, from: briefURL)
        var profiles: Set<ProductionProfileID> = [.generativeFilm]
        if [.narrative, .hybrid].contains(brief.conceptType) { profiles.insert(.narrativeStorytelling) }
        var routes: [String: ProductionRouteDisciplineV1] = [:]
        var references = bundle.references
        references.append(try ProductionPlanFilesV1.reference(PipelineLayout.briefFile, dataRoot: dataRoot))
        for shot in projection.shots {
            guard let requirement = shot.generationRequirement, ShotDeliveryModeResolverV1.resolve(shot) == .providerVideo else { continue }
            let path = ShotPlanningPromotionV1.routePath(shotID: shot.id, revision: projection.header.revision)
            guard let bound = projection.header.inputs.first(where: { $0.path == path }) else { throw ProductionPlanningError.invalid("sanity.routeBinding") }
            _ = try ProjectLocalFile.requireHash(bound.sha256, at: path, dataRoot: dataRoot)
            let route = try JSONDecoder().decode(ProductionRouteV1.self, from: Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
            let candidate = ProductionPlanFilesV1.candidate(route)
            let hashes = try ProductionRequirementResolverV1.fingerprints(requirement: requirement, candidate: candidate)
            try PlanningValidation.require(route.schema == productionRouteV1Schema && route.projectID == projection.header.projectID
                && route.shotID == shot.id && route.requirementSHA256 == hashes.requirementSHA256
                && route.capabilitiesSHA256 == hashes.capabilitiesSHA256 && route.routeSHA256 == hashes.routeSHA256,
                                           "sanity.currentRoute")
            routes[shot.id] = ProductionRouteDisciplineV1(capabilityProfile: candidate.capabilities.effective)
            references.append(try ProductionPlanFilesV1.reference(path, dataRoot: dataRoot))
        }
        return Inputs(timing: bundle.timing, profiles: profiles, routes: .init(routesByShotID: routes),
                      references: try ProductionPlanFilesV1.unique(references))
    }

    private static func coverage(projection: ProductionPlanProjectionV1, timing: StoryboardTimingV1) -> [Finding] {
        CoverageIntervalsV1.findings(projection.timings.map {
            CoverageIntervalV1(id: $0.shotID, startSeconds: projection.timebase.seconds(for: $0.startTicks),
                               endSeconds: projection.timebase.seconds(for: $0.startTicks + $0.durationTicks))
        }, mode: projection.mode, rangeStartSeconds: projection.timebase.seconds(for: timing.rangeStartTicks),
           rangeEndSeconds: projection.timebase.seconds(for: timing.rangeStartTicks + timing.rangeDurationTicks))
    }

    private static func narrative(_ projection: ProductionPlanProjectionV1) -> [Finding] {
        var out = projection.editorialBindings.filter { $0.narrativeBeat == nil }.map {
            Finding(level: .error, code: "NARRATIVE_BEAT_MISSING", shotId: $0.shotID,
                    message: "Narrative and hybrid projects require a narrative beat for every shot.")
        }
        let groups = Dictionary(grouping: projection.editorialBindings, by: \.sceneID)
        for scene in groups.keys.sorted() {
            let entries = (groups[scene] ?? []).sorted {
                let first = projection.timing(for: $0.shotID)?.startTicks ?? 0
                let second = projection.timing(for: $1.shotID)?.startTicks ?? 0
                return first == second ? $0.shotID < $1.shotID : first < second
            }
            guard entries.count >= 3 else { continue }
            let beats = entries.compactMap(\.narrativeBeat)
            if !beats.isEmpty && beats.allSatisfy({ $0 == .performance || $0 == .atmosphere }) { continue }
            guard let action = beats.firstIndex(of: .action) else {
                out.append(.init(level: .warn, code: "NARRATIVE_ACTION_MISSING", message: "Scene \(scene) has no observable action beat."))
                continue
            }
            if !beats[..<action].contains(where: { $0 == .establish || $0 == .atmosphere }) {
                out.append(.init(level: .warn, code: "NARRATIVE_CONTEXT_MISSING", message: "Scene \(scene) has no establish or atmosphere beat before its action."))
            }
            if !beats[beats.index(after: action)...].contains(where: { $0 == .reaction || $0 == .detail || $0 == .transition }) {
                out.append(.init(level: .warn, code: "NARRATIVE_CONSEQUENCE_MISSING", message: "Scene \(scene) has no reaction, detail, or transition beat after its action."))
            }
        }
        return out
    }
}

enum ProductionPlanFilesV1 {
    static func planningInputs(_ projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> (timing: StoryboardTimingV1, draft: ShotPlanningDraftV1, references: [CanonicalArtifactReferenceV1]) {
        try projection.requireCurrentInputs(dataRoot: dataRoot)
        let graph = try TreatmentCausalityStoreV2.requireCurrent(dataRoot: dataRoot)
        let source = try JSONDecoder().decode(StorySourceV1.self, from: Data(contentsOf: ProjectLocalFile.resolve(StorySourceV1.currentPath, dataRoot: dataRoot)))
        let sourceBytes: [String: Data]
        if let original = source.source {
            sourceBytes = [original.id: try Data(contentsOf: ProjectLocalFile.requireHash(original.sha256, at: original.path, dataRoot: dataRoot))]
        } else { sourceBytes = [:] }
        let script = try ProductionPlanningStoreV1.readScript(dataRoot: dataRoot, treatmentBeatIDs: Set(graph.beats.map(\.id)), sourceBytes: sourceBytes)
        let board = try ProductionPlanningStoreV1.readStoryboard(dataRoot: dataRoot, script: script, requireVisuals: false)
        let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: board)
        let context = try ExecutionPlanCanonicalCodec.decodeContext(Data(contentsOf: ProjectLocalFile.resolve(projection.executionPlan.creativeContext.path, dataRoot: dataRoot)))
        try ProductionPlanProjectionValidatorV1.validate(projection, storyboard: board, draft: draft, context: context)
        var refs = board.references + projection.header.inputs + graph.header.inputs + source.header.inputs
        refs += [projection.draftReference, projection.storyboardReference, projection.executionPlan.creativeContext]
        refs += context.artifacts + context.media.map { .init(id: $0.id, role: $0.role, path: $0.path, sha256: $0.sha256) }
        refs += context.extensions.map { .init(id: $0.id, role: $0.schema, path: $0.path, sha256: $0.sha256) }
        for path in [ProductionPlanProjectionV1.versionPath(projection.header.revision), ShotPlanningDraftV1.currentPath,
                     StorySourceV1.currentPath, TreatmentCausalityV2.currentPath, PipelineLayout.treatmentCurrentFile] {
            refs.append(try reference(path, dataRoot: dataRoot))
        }
        refs = try unique(refs)
        try require(refs, dataRoot: dataRoot)
        return (board.timing, draft, refs)
    }

    static func reference(_ path: String, dataRoot: URL) throws -> CanonicalArtifactReferenceV1 {
        .init(id: "input-" + FileDigest.sha256(of: Data(path.utf8)), role: "core.production-input",
              path: path, sha256: try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
    }

    static func unique(_ refs: [CanonicalArtifactReferenceV1]) throws -> [CanonicalArtifactReferenceV1] {
        var paths: [String: CanonicalArtifactReferenceV1] = [:]
        for ref in refs {
            try PlanningValidation.reference(ref)
            if let prior = paths[ref.path] { try PlanningValidation.require(prior.sha256 == ref.sha256, "productionInputs.conflictingPath") }
            else { paths[ref.path] = ref }
        }
        return paths.values.sorted { $0.path < $1.path }
    }

    static func require(_ refs: [CanonicalArtifactReferenceV1], dataRoot: URL) throws {
        for ref in refs { _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: dataRoot) }
    }

    static func fingerprint(_ refs: [CanonicalArtifactReferenceV1]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return FileDigest.sha256(of: try encoder.encode(refs.map { [$0.path, $0.sha256] }))
    }

    static func candidate(_ route: ProductionRouteV1) -> ProductionRouteCandidateV1 {
        .init(capabilities: route.capabilitySnapshot.capabilities, providerActivated: true, liveAvailable: true,
              qualityScore: route.qualityScore, preferenceScore: route.preferenceScore,
              qualityTargetIDs: route.capabilitySnapshot.qualityTargetIDs,
              satisfiedProductionProfileRequirementIDs: route.capabilitySnapshot.satisfiedProductionProfileRequirementIDs,
              inputSlots: route.capabilitySnapshot.inputSlots, estimatedCost: route.estimatedCost,
              estimatedLatencySeconds: route.estimatedLatencySeconds)
    }
}
