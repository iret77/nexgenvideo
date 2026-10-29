import Foundation

public enum ProductionPlanningLineageV2 {
    public static let phases = ["project_init", "brief", "production_design", "treatment", "script", "storyboard",
                                "shot_planning", "bible", "shotlist", "sanity", "frames", "render_review", "render"]

    public static func snapshot(phase: String, dataRoot: URL) throws -> PhaseLineageSnapshot {
        try snapshot(phase: phase, dataRoot: dataRoot, evidenceReferences: nil)
    }

    public static func snapshot(phase: String, dataRoot: URL,
                                evidenceReferences: StoryboardSketchEvidenceReferences?) throws -> PhaseLineageSnapshot {
        guard let index = phases.firstIndex(of: phase) else { throw ProductionPlanningError.invalid("lineage.phase") }
        let inputs = try phases.prefix(index).flatMap { try artifactPaths(phase: $0, dataRoot: dataRoot, evidenceReferences: evidenceReferences) }
        let artifacts = try artifactPaths(phase: phase, dataRoot: dataRoot, evidenceReferences: evidenceReferences)
        return PhaseLineageSnapshot(inputFingerprint: try fingerprint(inputs, dataRoot: dataRoot),
            artifactFingerprint: try fingerprint(artifacts, dataRoot: dataRoot))
    }

    public static func artifactPaths(phase: String, dataRoot: URL) throws -> [String] {
        try artifactPaths(phase: phase, dataRoot: dataRoot, evidenceReferences: nil)
    }

    public static func artifactPaths(phase: String, dataRoot: URL,
                                     evidenceReferences: StoryboardSketchEvidenceReferences?) throws -> [String] {
        var paths: [String]
        switch phase {
        case "project_init": paths = [PipelineLayout.projectFile]
        case "brief":
            let source = try json(StorySourceV1.self, path: StorySourceV1.currentPath, dataRoot: dataRoot)
            try source.requireCurrentBytes(dataRoot: dataRoot)
            paths = [PipelineLayout.briefFile, StorySourceV1.currentPath] + source.header.inputs.map(\.path)
                + [source.source, source.declineReceipt].compactMap { $0?.path }
                + source.sourceDecisions.map(\.confirmationReceipt.path)
                + optional([PlaybackRangeV1.currentPath, AffectProfile.file], dataRoot: dataRoot)
        case "production_design":
            let design = try YAMLArtifactStore(dataRoot: dataRoot).load(ProductionDesign.self, at: PipelineLayout.productionDesignFile)
            try design.validate()
            let spatial = try ProductionSpatialInventoryV1.loadIfPresent(dataRoot: dataRoot)
            paths = [PipelineLayout.productionDesignFile] + design.refs.map(\.path)
                + (design.lightingAnchor.isEmpty ? [] : [design.lightingAnchor])
                + optional([PipelineLayout.assetProofFile(scope: "production_design"), ResolvedProductionStyleV1.relativePath], dataRoot: dataRoot)
                + (spatial.map { [ProductionSpatialInventoryV1.currentPath] + $0.references.map(\.path) } ?? [])
        case "treatment":
            let value = try TreatmentCausalityStoreV2.requireCurrent(dataRoot: dataRoot, approval: false)
            paths = [PipelineLayout.treatmentCurrentFile, PipelineLayout.treatmentVersionFile(value.header.revision),
                TreatmentCausalityV2.currentPath, TreatmentCausalityV2.versionPath(value.header.revision)] + value.header.inputs.map(\.path)
        case "script":
            let value = try script(dataRoot: dataRoot)
            paths = [ScriptV1.currentPath, ScriptV1.versionPath(value.header.revision)] + value.header.inputs.map(\.path)
        case "storyboard":
            paths = try storyboard(dataRoot: dataRoot, evidenceReferences: evidenceReferences).references.map(\.path)
        case "shot_planning":
            let value = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: storyboard(dataRoot: dataRoot, evidenceReferences: evidenceReferences))
            paths = [ShotPlanningDraftV1.currentPath, ShotPlanningDraftV1.versionPath(value.header.revision)] + value.header.inputs.map(\.path)
        case "bible":
            guard let bible = try loadBible(dataRoot: dataRoot) else { throw ProductionPlanningError.invalid("lineage.bibleMissing") }
            try bible.validate()
            paths = [PipelineLayout.bibleFile] + BibleViewProvenanceRequirementsV1.make(bible: bible).map(\.path)
                + optional([PipelineLayout.assetProofFile(scope: "bible"), PipelineLayout.bibleIdentityVariantsFile,
                    PipelineLayout.confirmedIdentityAdoptionsFile], dataRoot: dataRoot)
        case "shotlist":
            let projection = try projection(dataRoot: dataRoot)
            let promotion = try json(ShotPlanningPromotionV1.self, path: ShotPlanningPromotionV1.currentPath, dataRoot: dataRoot)
            let archived = try json(ShotPlanningPromotionV1.self, path: ShotPlanningPromotionV1.versionPath(promotion.header.revision), dataRoot: dataRoot)
            guard promotion == archived, promotion.header.revision == projection.header.revision,
                  promotion.projection.path == ProductionPlanProjectionV1.versionPath(projection.header.revision) else {
                throw ProductionPlanningError.invalid("lineage.promotion")
            }
            try promotion.header.requireCurrentInputs(dataRoot: dataRoot)
            paths = [ProductionPlanProjectionV1.versionPath(projection.header.revision), ShotPlanningPromotionV1.currentPath,
                ShotPlanningPromotionV1.versionPath(promotion.header.revision)] + projection.header.inputs.map(\.path)
                + projection.sourceBindings.map(\.path) + [projection.executionPlan.creativeContext.path]
                + projection.executionPlan.extensionReferences.map(\.path) + promotion.artifactReferences.map(\.path)
        case "sanity": paths = [PipelineLayout.sanityReportFile] + (try ProductionPlanAuditV1.artifactReferences(projection: projection(dataRoot: dataRoot), dataRoot: dataRoot)).map(\.path)
        case "frames":
            let frames = try loadFramesManifest(dataRoot: dataRoot)
            paths = [PipelineLayout.framesManifestFile] + frames.shots.flatMap(\.frames).map(\.path)
                + optional([PipelineLayout.renderManifestFile(phase: "frames"), RenderRecordPublicationV1.artifactPath(phase: "frames"),
                    RenderShotProvenancePublicationV1.artifactPath(phase: "frames")], dataRoot: dataRoot)
            for shot in frames.shots {
                for frame in shot.frames {
                    let receiptPath = "frames/production-receipts/\(shot.shotId)-\(frame.role).v1.json"
                    let receipt = try json(FrameReceiptInputs.self, path: receiptPath, dataRoot: dataRoot)
                    guard receipt.schema == "production-frame-receipt/v1" else { throw ProductionPlanningError.invalid("lineage.frameReceipt") }
                    for input in receipt.inputs { _ = try ProjectLocalFile.requireHash(input.sha256, at: input.path, dataRoot: dataRoot) }
                    paths += [receiptPath, FrameReferenceUsageStoreV1.path(shotID: shot.shotId, role: frame.role)] + receipt.inputs.map(\.path)
                    paths += optional(["frames/\(shot.shotId)-\(frame.role).audit.yaml", "frames/\(shot.shotId)-\(frame.role).acceptance.json"], dataRoot: dataRoot)
                }
            }
        case "render_review":
            let review = try json(RenderReviewV1.self, path: RenderReviewV1.currentPath, dataRoot: dataRoot)
            paths = [RenderReviewV1.currentPath, RenderReviewV1.versionPath(review.header.revision)] + review.references.map(\.path)
        case "render":
            let manifest = try loadRenderManifest(dataRoot: dataRoot, phase: "final")
            paths = [PipelineLayout.renderManifestFile(phase: "final"), PipelineLayout.renderProofFile(phase: "final"),
                RenderRecordPublicationV1.artifactPath(phase: "final"), RenderShotProvenancePublicationV1.artifactPath(phase: "final")]
                + manifest.entries.values.compactMap(\.output)
        default: throw ProductionPlanningError.invalid("lineage.phase")
        }
        for path in paths { _ = try ProjectLocalFile.resolve(path, dataRoot: dataRoot) }
        return Array(Set(paths)).sorted()
    }

    public static func script(dataRoot: URL) throws -> ScriptV1 {
        let cause = try TreatmentCausalityStoreV2.requireCurrent(dataRoot: dataRoot, approval: true)
        let source = try json(StorySourceV1.self, path: StorySourceV1.currentPath, dataRoot: dataRoot)
        var bytes: [String: Data] = [:]
        if let original = source.source {
            bytes[original.id] = try Data(contentsOf: ProjectLocalFile.requireHash(original.sha256, at: original.path, dataRoot: dataRoot))
        }
        return try ProductionPlanningStoreV1.readScript(dataRoot: dataRoot,
            treatmentBeatIDs: Set(cause.beats.map(\.id)), sourceBytes: bytes)
    }

    public static func storyboard(dataRoot: URL) throws -> StoryboardBundleSnapshot {
        try storyboard(dataRoot: dataRoot, evidenceReferences: nil)
    }

    public static func storyboard(dataRoot: URL, evidenceReferences: StoryboardSketchEvidenceReferences?) throws -> StoryboardBundleSnapshot {
        try ProductionPlanningStoreV1.readStoryboard(dataRoot: dataRoot, script: script(dataRoot: dataRoot), requireVisuals: false,
            evidenceReferences: evidenceReferences)
    }

    public static func projection(dataRoot: URL) throws -> ProductionPlanProjectionV1 {
        let directory = dataRoot.appendingPathComponent("shotlist")
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ProductionPlanningError.invalid("productionPlan.directory") }
        let versions = try FileManager.default.contentsOfDirectory(atPath: directory.path).compactMap { name -> Int? in
            guard name.hasPrefix("v"), name.hasSuffix(".v5.yaml") else { return nil }
            return Int(name.dropFirst().dropLast(".v5.yaml".count))
        }
        guard let revision = versions.max(), revision > 0 else { throw ProductionPlanningError.invalid("productionPlan.missing") }
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(ProductionPlanProjectionV1.versionPath(revision), dataRoot: dataRoot))
        guard let text = String(data: bytes, encoding: .utf8) else { throw ProductionPlanningError.invalid("productionPlan.utf8") }
        let value = try YAMLCoding.decode(ProductionPlanProjectionV1.self, from: text)
        try value.requireCurrentInputs(dataRoot: dataRoot)
        return value
    }

    private static func fingerprint(_ paths: [String], dataRoot: URL) throws -> String {
        let values = try Set(paths).sorted().map { path in
            ["path": path, "sha256": try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: dataRoot))]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return FileDigest.sha256(of: try encoder.encode(values))
    }

    private static func optional(_ paths: [String], dataRoot: URL) -> [String] {
        paths.filter { FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent($0).path) }
    }

    private static func json<T: Decodable>(_ type: T.Type, path: String, dataRoot: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
    }
    private struct FrameReceiptInputs: Decodable {
        let schema: String
        let inputs: [CanonicalArtifactReferenceV1]
    }

}
