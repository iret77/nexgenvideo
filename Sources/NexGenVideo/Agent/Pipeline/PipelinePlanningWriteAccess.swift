import Foundation
import NexGenEngine

struct PipelinePlanningWriteAccess: Sendable {
    let dataRoot: URL
    let declaration: ProjectPackGate.MutationDeclaration
    let workflow: HostWorkflowKey
    let phase: String

    init(dataRoot: URL, declaration: ProjectPackGate.MutationDeclaration, phase: String) throws {
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot,
            expectedPack: declaration.binding, expectedProductionContract: declaration.productionContract),
              workflow.isProductionV2 else {
            throw GateBlocked("This action requires an explicitly selected production workflow.")
        }
        self.dataRoot = dataRoot
        self.declaration = declaration
        self.workflow = workflow
        self.phase = phase
        try revalidate()
    }

    func revalidate() throws {
        guard try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot, expectedPack: declaration.binding,
            expectedProductionContract: declaration.productionContract) == workflow else {
            throw GateBlocked("The production workflow changed. Reopen the project.")
        }
        let order = try PhaseContractRuntime.order(workflow: workflow)
        let state = try ProjectStateBuilder.buildSnapshot(dataRoot: dataRoot, order: order)
        guard state.nextPhase == phase else {
            throw GateBlocked("Only the current production phase can change. Complete it or explicitly rewind first.")
        }
    }

    func publish(_ files: [(path: String, bytes: Data)], validate: () throws -> Void) throws {
        try publish(files, captureLineage: true, validate: validate)
    }

    func publish(_ files: [(path: String, bytes: Data)], captureLineage: Bool, validate: () throws -> Void) throws {
        let metadata = [PipelineLayout.gatesFile, PipelineLayout.lineageFile]
        let paths = files.map { dataRoot.appendingPathComponent($0.path) }
            + metadata.map { dataRoot.appendingPathComponent($0) }
        try ArtifactTransaction.perform(paths: paths, dataRoot: dataRoot) {
            try revalidate()
            for file in files {
                let parent = (file.path as NSString).deletingLastPathComponent
                _ = try ProjectLocalFile.ensureDirectory(parent, dataRoot: dataRoot)
                try file.bytes.write(to: dataRoot.appendingPathComponent(file.path), options: .atomic)
            }
            try validate()
            try revalidate()
            try PipelinePhaseMutationRecorder.record(phase: phase, dataRoot: dataRoot, captureLineage: captureLineage,
                declaredPack: declaration.packName, declaredBinding: declaration.binding,
                declaredProductionContract: declaration.productionContract)
        }
    }
}

enum PlanningWriterIO {
    static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func read<T: Decodable>(_ type: T.Type, at path: String, dataRoot: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
    }

    static func reference(_ path: String, id: String, role: String, dataRoot: URL) throws -> CanonicalArtifactReferenceV1 {
        .init(id: id, role: role, path: path,
              sha256: try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
    }

    static func reference(_ path: String, id: String, role: String, bytes: Data) -> CanonicalArtifactReferenceV1 {
        .init(id: id, role: role, path: path, sha256: FileDigest.sha256(of: bytes))
    }

    static func nextRevision(directory: String, prefix: String = "v", suffix: String, dataRoot: URL) throws -> Int {
        let url = dataRoot.appendingPathComponent(directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return 1 }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        let revisions = try names.compactMap { name -> Int? in
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
            let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
            guard !digits.isEmpty, digits.utf8.first != 48, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  let revision = Int(digits), revision > 0, revision < Int.max else {
                throw GateBlocked("Production revision is invalid.")
            }
            return revision
        }.sorted()
        guard revisions.enumerated().allSatisfy({ $0.element == $0.offset + 1 }) else {
            throw GateBlocked("Production artifact history is incomplete. Restore it before making a revision.")
        }
        return (revisions.last ?? 0) + 1
    }

    static func script(dataRoot: URL) throws -> ScriptV1 {
        let causality = try TreatmentCausalityStoreV2.requireCurrent(dataRoot: dataRoot, approval: true)
        let source = try read(StorySourceV1.self, at: StorySourceV1.currentPath, dataRoot: dataRoot)
        var bytes: [String: Data] = [:]
        if let reference = source.source {
            bytes[reference.id] = try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot))
        }
        return try ProductionPlanningStoreV1.readScript(dataRoot: dataRoot,
            treatmentBeatIDs: Set(causality.beats.map(\.id)), sourceBytes: bytes)
    }

    static func storyboard(dataRoot: URL, requireVisuals: Bool = true) throws -> StoryboardBundleSnapshot {
        let result = try ProductionPlanningStoreV1.readStoryboard(dataRoot: dataRoot, script: script(dataRoot: dataRoot),
            requireVisuals: requireVisuals, evidenceVerifier: PipelineStoryboardSketchEvidence.requireCurrent,
            evidenceReferences: PipelineStoryboardSketchEvidence.references)
        if case .bound(let binding) = ProjectPluginSettings.bindingResolution(projectURL: FrameInventory.projectHome(of: dataRoot)),
           binding.id == "musicvideo" {
            guard binding.version == HostWorkflowKey.musicvideoV2Version,
                  binding.projectSchema == HostWorkflowKey.musicvideoV2Schema else {
                throw GateBlocked("This Storyboard requires its exact Music Video production workflow.")
            }
            try PipelinePlaybackRangeWriter.requireStoryboardBinding(result.timing, dataRoot: dataRoot,
                workflowID: HostWorkflowKey.musicvideoV2Contract)
        }
        return result
    }
}

enum PipelineScriptWriter {
    static func write(summary: String, scenes: [ScriptV1.Scene], origin: PlanningArtifactHeaderV1.Origin,
                      access: PipelinePlanningWriteAccess, filmFlow: FilmFlowAdoption.PreparedScript? = nil,
                      beforePublish: () throws -> Void = {}) throws -> ScriptV1 {
        guard access.phase == "script" else { throw GateBlocked("Script has a different phase owner.") }
        let root = access.dataRoot
        let causality = try TreatmentCausalityStoreV2.requireCurrent(dataRoot: root, approval: true)
        let source = try PlanningWriterIO.read(StorySourceV1.self, at: StorySourceV1.currentPath, dataRoot: root)
        let revision = try PlanningWriterIO.nextRevision(directory: "script", suffix: ".v1.json", dataRoot: root)
        let inputs = [causality.treatmentReference, causality.briefReference, causality.storySourceReference,
            try PlanningWriterIO.reference(TreatmentCausalityV2.versionPath(causality.header.revision), id: "treatment.causality", role: "core.treatment-causality", dataRoot: root)]
            + [source.source, source.declineReceipt].compactMap { $0 }
        let header = PlanningArtifactHeaderV1(projectID: causality.header.projectID, revision: revision, origin: origin, inputs: inputs)
        let script = ScriptV1(header: header, summary: summary, scenes: scenes)
        var sourceBytes: [String: Data] = [:]
        if let original = source.source {
            sourceBytes[original.id] = try Data(contentsOf: ProjectLocalFile.requireHash(original.sha256, at: original.path, dataRoot: root))
        }
        try header.requireCurrentInputs(dataRoot: root)
        try ScriptValidatorV1.validate(script, treatmentBeatIDs: Set(causality.beats.map(\.id)), sourceBytes: sourceBytes)
        let bytes = try PlanningWriterIO.json(script)
        var files = [(path: ScriptV1.versionPath(revision), bytes: bytes), (path: ScriptV1.currentPath, bytes: bytes)]
        if let filmFlow {
            files.append(try filmFlow.file(outputs: [PlanningWriterIO.reference(
                ScriptV1.versionPath(revision), id: "script", role: "core.script", bytes: bytes)], dataRoot: root))
        }
        try beforePublish()
        try access.publish(files) {
            _ = try PlanningWriterIO.script(dataRoot: root)
        }
        return script
    }
}
