import Foundation

extension FramesManifest {
    public func reconciled(with projection: ProductionPlanProjectionV1,
                           generated: String = currentTimestamp()) throws -> FramesManifest {
        try ProductionPlanProjectionValidatorV1.validate(projection)
        guard project == projection.header.projectID else {
            throw FramesManifestReconciliationError.projectMismatch(manifest: project, shotlist: projection.header.projectID)
        }
        try ProductionPlanFramesV1.validateDuplicates(self)
        var result = self
        result.generated = generated
        result.shots = projection.shots.compactMap { shot in
            let roles = projection.requiredFrameRoles(for: shot.id)
            guard !roles.isEmpty, let existing = self.shot(shot.id) else { return nil }
            return ShotFrames(shotId: shot.id, keyframeStrategy: ProductionPlanFramesV1.strategy(roles),
                              frames: existing.frames.filter { roles.contains($0.role) })
        }
        return result
    }
}

public enum ProductionPlanFramesV1 {
    public static func validate(_ manifest: FramesManifest, projection: ProductionPlanProjectionV1) throws {
        try ProductionPlanProjectionValidatorV1.validate(projection)
        try validateDuplicates(manifest)
        let required = projection.shots.filter { !projection.requiredFrameRoles(for: $0.id).isEmpty }
        try PlanningValidation.require(manifest.schema == framesSchemaVersion && manifest.project == projection.header.projectID
            && manifest.shots.count == required.count && Set(manifest.shots.map(\.shotId)) == Set(required.map(\.id)),
                                       "frames.currentShots")
        for shot in required {
            let roles = projection.requiredFrameRoles(for: shot.id)
            guard let entry = manifest.shot(shot.id) else { throw ProductionPlanningError.invalid("frames.requiredShot") }
            try PlanningValidation.require(entry.keyframeStrategy == strategy(roles) && entry.frames.count == roles.count
                && Set(entry.frames.map(\.role)) == Set(roles), "frames.requiredRoles")
            for frame in entry.frames {
                try PlanningValidation.path(frame.path)
                try PlanningValidation.require(frame.path.hasPrefix("frames/"), "frames.imagePath")
                try PlanningValidation.text(frame.providerPrompt, "frames.compiledPrompt")
                try PlanningValidation.text(frame.runwayModel, "frames.model")
                try PlanningValidation.require(ProductionPromptPolicy.stillPromptViolations(frame.providerPrompt).isEmpty,
                                               "frames.motionInStillPrompt")
            }
        }
    }

    @discardableResult
    public static func requireCurrent(projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> FramesManifest {
        let refs = try artifactReferences(projection: projection, dataRoot: dataRoot)
        let manifest = try loadFramesManifest(dataRoot: dataRoot)
        try validate(manifest, projection: projection)
        let style = try ProductionStyleStoreV1.load(dataRoot: dataRoot)
        let publication: RenderShotProvenancePublicationV1?
        if manifest.shots.isEmpty { publication = nil }
        else {
            let path = RenderShotProvenancePublicationV1.artifactPath(phase: "frames")
            let value = try JSONDecoder().decode(RenderShotProvenancePublicationV1.self,
                from: Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
            try RenderShotProvenanceValidatorV1.validate(value)
            try PlanningValidation.require(value.project == projection.header.projectID && value.phase == "frames"
                && Set(value.proofs.keys) == Set(manifest.shots.map(\.shotId)), "frames.provenancePublication")
            publication = value
        }
        for shot in manifest.shots {
            guard let reference = publication?.proofs[shot.shotId] else { throw ProductionPlanningError.invalid("frames.hostProof") }
            let url = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
            let proof = try JSONDecoder().decode(RenderShotProvenanceProofV1.self, from: Data(contentsOf: url))
            try RenderShotProvenanceValidatorV1.validate(proof, artifactPath: reference.path, artifactSHA256: reference.sha256)
            try PlanningValidation.require(proof.project == manifest.project && proof.phase == "frames"
                && proof.shotID == shot.shotId && proof.frames == shot, "frames.provenanceTarget")
            for frame in shot.frames {
                let image = try ProjectLocalFile.resolve(frame.path, dataRoot: dataRoot)
                _ = try FrameRasterizer.loadImage(at: image)
                let digest = try FileDigest.sha256(of: image)
                try PlanningValidation.require(proof.outputs.contains(.init(path: frame.path, sha256: digest)), "frames.provenanceImage")
                guard let audit = try loadFrameAudit(dataRoot: dataRoot, shotId: shot.shotId, role: frame.role) else {
                    throw ProductionPlanningError.invalid("frames.auditMissing")
                }
                try audit.validate()
                try PlanningValidation.require(audit.shotId == shot.shotId && audit.role == frame.role
                    && audit.renderSha256 == digest && Set(standardAuditCheckKeys).isSubset(of: Set(audit.checks.keys))
                    && ProjectLocalFile.resolve(audit.renderPath, dataRoot: dataRoot) == image, "frames.auditTarget")
                try FrameAuditAcceptanceStoreV1.requireResolved(audit: audit, dataRoot: dataRoot)
                if let style { try FrameObservationStoreV1.requireStyleAudit(audit, style: style, dataRoot: dataRoot) }
            }
        }
        try ProductionPlanFilesV1.require(refs, dataRoot: dataRoot)
        return manifest
    }

    public static func artifactReferences(projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        var refs = try ProductionPlanFilesV1.planningInputs(projection, dataRoot: dataRoot).references
        let manifest = try loadFramesManifest(dataRoot: dataRoot)
        try validate(manifest, projection: projection)
        refs.append(try ProductionPlanFilesV1.reference(PipelineLayout.framesManifestFile, dataRoot: dataRoot))
        if !manifest.shots.isEmpty {
            let path = RenderShotProvenancePublicationV1.artifactPath(phase: "frames")
            refs.append(try ProductionPlanFilesV1.reference(path, dataRoot: dataRoot))
            let publication = try JSONDecoder().decode(RenderShotProvenancePublicationV1.self,
                from: Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
            try RenderShotProvenanceValidatorV1.validate(publication)
            for (shotID, ref) in publication.proofs {
                refs.append(.init(id: "proof-" + shotID, role: "core.frame-proof", path: ref.path, sha256: ref.sha256))
                let proof = try JSONDecoder().decode(RenderShotProvenanceProofV1.self,
                    from: Data(contentsOf: ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: dataRoot)))
                for output in proof.outputs + proof.dependencies {
                    refs.append(try ProductionPlanFilesV1.reference(output.path, dataRoot: dataRoot))
                    try PlanningValidation.require(refs.last?.sha256 == output.sha256, "frames.proofDependency")
                }
            }
        }
        for shot in manifest.shots {
            for frame in shot.frames {
                for path in [frame.path, "frames/\(shot.shotId)-\(frame.role).audit.yaml"] {
                    refs.append(try ProductionPlanFilesV1.reference(path, dataRoot: dataRoot))
                }
                for optional in ["frames/\(shot.shotId)-\(frame.role).acceptance.json", ResolvedProductionStyleV1.relativePath] {
                    if FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(optional).path) {
                        refs.append(try ProductionPlanFilesV1.reference(optional, dataRoot: dataRoot))
                    }
                }
            }
        }
        let result = try ProductionPlanFilesV1.unique(refs)
        try ProductionPlanFilesV1.require(result, dataRoot: dataRoot)
        return result
    }

    static func validateDuplicates(_ manifest: FramesManifest) throws {
        var ids = Set<String>()
        for shot in manifest.shots {
            guard ids.insert(shot.shotId).inserted else { throw FramesManifestReconciliationError.duplicateShot(shot.shotId) }
            var roles = Set<String>()
            for frame in shot.frames where !roles.insert(frame.role).inserted {
                throw FramesManifestReconciliationError.duplicateRole(shot: shot.shotId, role: frame.role)
            }
        }
    }

    public static func strategy(_ roles: [String]) -> String {
        roles == ["start", "end"] ? "start_end" : roles == ["end"] ? "end" : "start"
    }
}
