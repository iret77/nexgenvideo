import Foundation
import NexGenEngine

enum PipelineStorySourceWriter {
    private static let selectionPath = "brief/story-source-selection.v1.json"

    struct ConfirmedSelection: Equatable, Sendable {
        enum Disposition: Equatable, Sendable { case greenfield, imported }
        let disposition: Disposition
        let displayName: String
        let source: CanonicalArtifactReferenceV1?
    }

    private struct Selection: Codable {
        let schema: String
        let id: String
        let projectID: String
        let workflowID: String
        let source: CanonicalArtifactReferenceV1?
        let originalSource: CanonicalArtifactReferenceV1?
        let originalName: String?
        let selectedAt: String
    }

    @MainActor
    static func confirmGreenfield(editor: EditorViewModel) throws {
        try confirm(from: nil, editor: editor)
    }

    @MainActor
    static func confirmImportedSource(from url: URL, editor: EditorViewModel, filmFlow: FilmFlowAdoption? = nil) throws {
        try confirm(from: url, editor: editor, filmFlow: filmFlow)
    }

    @MainActor
    static func confirmPastedSource(text: String, editor: EditorViewModel) throws {
        try confirm(from: nil, pastedText: text, editor: editor)
    }

    @MainActor
    private static func confirm(from selectedURL: URL?, pastedText: String? = nil, editor: EditorViewModel, filmFlow: FilmFlowAdoption? = nil) throws {
        guard let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }),
              let key = editor.openWorkingCopyKey else { throw GateBlocked("Open a project before choosing story material.") }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: declaration.binding,
            expectedProductionContract: declaration.productionContract), workflow.isProductionV2 else {
            throw GateBlocked("Choose a production workflow before assigning story material.")
        }
        let state = try ProjectStateBuilder.buildSnapshot(dataRoot: root, order: PhaseContractRuntime.order(workflow: workflow))
        guard let phase = state.nextPhase, phase == "brief" || (workflow.packID == nil && phase == "project_init") else {
            throw GateBlocked("Explicitly rewind Brief before changing the selected story source.")
        }
        guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: phase) else {
            throw GateBlocked("Wait for the current production job before changing story material.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
        let access = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: phase)
        try ProjectWorkingCopy.markDirty(key: key)
        try writeSelection(from: selectedURL, pastedText: pastedText, access: access, filmFlow: filmFlow)
        editor.onPipelineChanged?()
    }

    static func writeSelection(from selectedURL: URL?, pastedText: String? = nil,
                               access: PipelinePlanningWriteAccess, filmFlow: FilmFlowAdoption? = nil) throws {
        guard access.phase == "brief" || (access.workflow.packID == nil && access.phase == "project_init") else {
            throw GateBlocked("Explicitly rewind Brief before changing the selected story source.")
        }
        let root = access.dataRoot
        let project = try YAMLArtifactStore(dataRoot: root).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        let id = UUID().uuidString.lowercased()
        var source: CanonicalArtifactReferenceV1?
        var files: [(path: String, bytes: Data)] = []
        var originalName: String?
        var originalSource: CanonicalArtifactReferenceV1?
        if let selectedURL {
            let values = try selectedURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  ["md", "txt", "markdown"].contains(selectedURL.pathExtension.lowercased()) else {
                throw GateBlocked("Choose a regular text or Markdown file.")
            }
            let bytes = try Data(contentsOf: selectedURL)
            guard let text = String(data: bytes, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GateBlocked("Story material must contain readable UTF-8 text.")
            }
            source = PlanningWriterIO.reference("import/script.md", id: "story-source", role: "core.imported-story", bytes: bytes)
            files.append(("import/script.md", bytes))
            originalName = selectedURL.lastPathComponent
        } else if let pastedText {
            guard !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GateBlocked("Story material cannot be empty.")
            }
            let bytes = Data(pastedText.utf8)
            source = PlanningWriterIO.reference("import/script.md", id: "story-source", role: "core.imported-story", bytes: bytes)
            files.append(("import/script.md", bytes))
            originalName = "Pasted story"
        }
        if let source, let sourceBytes = files.first(where: { $0.path == source.path })?.bytes {
            let originalPath = "brief/source-selections/\(id).source.md"
            originalSource = PlanningWriterIO.reference(originalPath, id: "story-source.original", role: "host.original-story-bytes", bytes: sourceBytes)
            files.append((originalPath, sourceBytes))
        }
        let selection = Selection(schema: "story-source-selection/v1", id: id, projectID: project.project,
            workflowID: access.workflow.contractID, source: source, originalSource: originalSource, originalName: originalName, selectedAt: currentTimestamp())
        let bytes = try PlanningWriterIO.json(selection)
        let archive = "brief/source-selections/\(id).v1.json"
        files += [(archive, bytes), (selectionPath, bytes)]
        if let filmFlow {
            let outputs = [PlanningWriterIO.reference(archive, id: id, role: "host.story-source-selection", bytes: bytes)]
                + [originalSource].compactMap { $0 }
            files.append(try filmFlow.file(phase: "brief", outputs: outputs, dataRoot: root))
        }
        let paths = files.map { root.appendingPathComponent($0.path) }
            + [PipelineLayout.gatesFile, PipelineLayout.lineageFile].map { root.appendingPathComponent($0) }
        try ArtifactTransaction.perform(paths: paths, dataRoot: root) {
            try access.revalidate()
            for file in files {
                _ = try ProjectLocalFile.ensureDirectory((file.path as NSString).deletingLastPathComponent, dataRoot: root)
                try file.bytes.write(to: root.appendingPathComponent(file.path), options: .atomic)
            }
            try PipelinePhaseMutationRecorder.record(phase: "brief", dataRoot: root, captureLineage: false,
                declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
                declaredProductionContract: access.declaration.productionContract)
        }
    }

    struct SelectionState: Sendable, Equatable {
        let selection: Data?
        let source: Data?
    }

    static func selectionState(dataRoot: URL) throws -> SelectionState {
        func read(_ path: String) throws -> Data? {
            guard FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(path).path) else { return nil }
            return try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
        }
        return try .init(selection: read(selectionPath), source: read("import/script.md"))
    }

    static func restoreSelection(_ desired: SelectionState, expected: SelectionState,
                                 access: PipelinePlanningWriteAccess) throws {
        guard access.phase == "brief" || (access.workflow.packID == nil && access.phase == "project_init"),
              try selectionState(dataRoot: access.dataRoot) == expected else {
            throw GateBlocked("The selected story material changed. Rewind Brief and reload it before Undo.")
        }
        let root = access.dataRoot
        let values: [(String, Data?)] = [(selectionPath, desired.selection), ("import/script.md", desired.source)]
        let paths = values.map { root.appendingPathComponent($0.0) }
            + [PipelineLayout.gatesFile, PipelineLayout.lineageFile].map { root.appendingPathComponent($0) }
        try ArtifactTransaction.perform(paths: paths, dataRoot: root) {
            try access.revalidate()
            for (path, bytes) in values {
                let url = root.appendingPathComponent(path)
                if let bytes { try bytes.write(to: url, options: .atomic) }
                else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            _ = try confirmedSelection(dataRoot: root, workflowID: access.workflow.contractID)
            try PipelinePhaseMutationRecorder.record(phase: "brief", dataRoot: root, captureLineage: false,
                declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
                declaredProductionContract: access.declaration.productionContract)
        }
    }

    static func confirmedSelection(dataRoot: URL, workflowID: String) throws -> ConfirmedSelection? {
        guard FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(selectionPath).path) else { return nil }
        let selection = try PlanningWriterIO.read(Selection.self, at: selectionPath, dataRoot: dataRoot)
        guard let id = UUID(uuidString: selection.id), id.uuidString.lowercased() == selection.id,
              selection.schema == "story-source-selection/v1", selection.workflowID == workflowID,
              try Data(contentsOf: ProjectLocalFile.resolve(selectionPath, dataRoot: dataRoot))
                == Data(contentsOf: ProjectLocalFile.resolve("brief/source-selections/\(selection.id).v1.json", dataRoot: dataRoot)) else {
            throw GateBlocked("The selected story source is invalid. Choose it again in its native card.")
        }
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        guard project.project == selection.projectID else { throw GateBlocked("The story selection belongs to a different project.") }
        if let source = selection.source {
            let data = try Data(contentsOf: ProjectLocalFile.requireHash(source.sha256, at: source.path, dataRoot: dataRoot))
            guard let original = selection.originalSource, original.sha256 == source.sha256,
                  try Data(contentsOf: ProjectLocalFile.requireHash(original.sha256, at: original.path, dataRoot: dataRoot)) == data,
                  source.path == "import/script.md", let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let name = selection.originalName, !name.isEmpty else { throw GateBlocked("The selected story source is unreadable.") }
            return ConfirmedSelection(disposition: .imported, displayName: name, source: source)
        }
        return ConfirmedSelection(disposition: .greenfield, displayName: "Develop from scratch", source: nil)
    }

    static func bindCurrentSelection(access: PipelinePlanningWriteAccess) throws -> StorySourceV1 {
        let root = access.dataRoot
        guard access.phase == "brief" else { throw GateBlocked("Brief owns the selected story source.") }
        guard try confirmedSelection(dataRoot: root, workflowID: access.workflow.contractID) != nil else {
            throw GateBlocked("Confirm existing story material or Develop from scratch in the native card first.")
        }
        let project = try YAMLArtifactStore(dataRoot: root).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        let selection = try PlanningWriterIO.read(Selection.self, at: selectionPath, dataRoot: root)
        guard selection.projectID == project.project, let id = UUID(uuidString: selection.id), id.uuidString.lowercased() == selection.id else {
            throw GateBlocked("The source selection receipt is invalid.")
        }
        let receipt = try PlanningWriterIO.reference("brief/source-selections/\(selection.id).v1.json",
            id: "story-source.selection", role: "host.story-source-selection", dataRoot: root)
        guard selection.schema == "story-source-selection/v1", selection.workflowID == access.workflow.contractID,
              try Data(contentsOf: ProjectLocalFile.resolve(selectionPath, dataRoot: root))
                == Data(contentsOf: ProjectLocalFile.resolve(receipt.path, dataRoot: root)) else {
            throw GateBlocked("Confirm the current story source in its native card first.")
        }
        let briefReference = try PlanningWriterIO.reference(PipelineLayout.briefFile, id: "brief", role: "core.brief", dataRoot: root)
        let source = StorySourceV1(header: .init(projectID: project.project, revision: 1, origin: .userRevision,
            inputs: [briefReference, receipt] + [selection.source, selection.originalSource].compactMap { $0 }), source: selection.source,
            declineReceipt: selection.source == nil ? receipt : nil)
        try source.requireCurrentBytes(dataRoot: root)
        return source
    }

    static func requireConfirmed(_ source: StorySourceV1, workflowID: String, dataRoot: URL) throws {
        try source.requireCurrentBytes(dataRoot: dataRoot)
        guard let current = try confirmedSelection(dataRoot: dataRoot, workflowID: workflowID) else {
            throw GateBlocked("The story source has no current native selection.")
        }
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        let selection = try PlanningWriterIO.read(Selection.self, at: selectionPath, dataRoot: dataRoot)
        let currentReceipt = try PlanningWriterIO.reference("brief/source-selections/\(selection.id).v1.json",
            id: "story-source.selection", role: "host.story-source-selection", dataRoot: dataRoot)
        guard source.header.projectID == project.project, selection.projectID == project.project,
              source.header.inputs.contains(currentReceipt), source.source == current.source,
              source.source != nil || source.declineReceipt == currentReceipt else {
            throw GateBlocked("The selected story source changed. Update Brief before approving it.")
        }
        if let original = selection.originalSource {
            guard source.header.inputs.contains(original) else {
                throw GateBlocked("The story source is missing its original-byte binding.")
            }
        }
    }
}
