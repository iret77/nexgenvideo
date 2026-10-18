import Foundation
import NexGenEngine

struct PipelinePlanningWriteAccess {
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
            try PipelinePhaseMutationRecorder.record(phase: phase, dataRoot: dataRoot, captureLineage: true,
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
        let revisions = names.compactMap { name -> Int? in
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
            return Int(name.dropFirst(prefix.count).dropLast(suffix.count))
        }.sorted()
        guard revisions.isEmpty || revisions == Array(1...(revisions.last ?? 1)) else {
            throw GateBlocked("Production artifact history is incomplete. Restore it before making a revision.")
        }
        guard (revisions.last ?? 0) < Int.max else { throw GateBlocked("Production revision is invalid.") }
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
        try ProductionPlanningStoreV1.readStoryboard(dataRoot: dataRoot, script: script(dataRoot: dataRoot),
            requireVisuals: requireVisuals, evidenceVerifier: PipelineStoryboardSketchEvidence.requireCurrent)
    }
}

enum PipelineScriptWriter {
    static func write(summary: String, scenes: [ScriptV1.Scene], origin: PlanningArtifactHeaderV1.Origin,
                      access: PipelinePlanningWriteAccess) throws -> ScriptV1 {
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
        try access.publish([(ScriptV1.versionPath(revision), bytes), (ScriptV1.currentPath, bytes)]) {
            _ = try PlanningWriterIO.script(dataRoot: root)
        }
        return script
    }
}
