import Foundation
import NexGenEngine

@MainActor
enum PatternRecommendationsStore {
    struct Snapshot: Sendable {
        let home: URL
        let key: String
        let generation: UUID
        let declaration: ProjectPackGate.MutationDeclaration
        let workflow: HostWorkflowKey
        let mode: String
        let excluded: [String]
        let envelope: PatternRecommendationsModel.Envelope
        let details: [String: PatternRecommendationsModel.Detail]
        let selectedID: String?
        let decision: Decision?
        let affect: String?
        let selectedPatternSHA256: String?
        let fingerprint: String
        let briefSHA256: String
        let projectSHA256: String
        let canEdit: Bool
        let rawResult: Data

        var responseBinding: ResponseBinding {
            .init(sha256: FileDigest.sha256(of: rawResult), mode: mode, excluded: excluded, fingerprint: fingerprint)
        }
    }

    struct ResponseBinding: Codable, Sendable, Equatable {
        let sha256: String
        let mode: String
        let excluded: [String]
        let fingerprint: String
    }

    static func responseBindingText(_ snapshot: Snapshot) -> String? {
        guard let data = try? PlanningWriterIO.json(snapshot.responseBinding) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    struct Decision: Codable, Sendable, Equatable {
        let schema: String
        let id: String
        let projectID: String
        let patternID: String?
        let previousPatternID: String?
        let inputFingerprint: String
        let resultSHA256: String
        let selectedPatternSHA256: String?
        let briefSHA256: String
        let warnings: [String]
        let reason: String
        let selectedAt: String
        let restored: Bool
    }

    private struct Loaded: Sendable {
        let brief: Brief
        let workflow: HostWorkflowKey
        let envelope: PatternRecommendationsModel.Envelope
        let details: [String: PatternRecommendationsModel.Detail]
        let rawResult: Data
        let patternBytes: [String: Data]
        let fingerprint: String
        let briefSHA256: String
        let projectSHA256: String
        let decision: Decision?
        let canEdit: Bool
        let affect: String?
    }

    private struct Revision: Sendable {
        let home: URL
        let key: String
        let generation: UUID
        let patternID: String?
        let briefSHA256: String
        let projectSHA256: String
        let patternSHA256: String?
        let mode: String
        let excluded: [String]
    }

    @MainActor private final class Session {
        weak var editor: EditorViewModel?
        let home: URL
        let key: String
        let generation: UUID
        let history: PipelineNativeRevisionHistory<Revision>

        init(editor: EditorViewModel, snapshot: Snapshot, manager: UndoManager) {
            self.editor = editor; home = snapshot.home; key = snapshot.key; generation = snapshot.generation
            history = PipelineNativeRevisionHistory(manager: manager, equivalent: {
                $0.home == $1.home && $0.key == $1.key && $0.generation == $1.generation && $0.patternID == $1.patternID
            }, restore: { [weak editor] desired, expected in
                guard let editor, editor.workingRoot == expected.home, editor.openWorkingCopyKey == expected.key,
                      editor.openWorkingCopyGeneration == expected.generation else { throw changed() }
                let current = try await capture(editor: editor, mode: desired.mode, excluded: desired.excluded)
                guard current.briefSHA256 == expected.briefSHA256, current.projectSHA256 == expected.projectSHA256 else { throw changed() }
                return try await apply(desired.patternID, expected: current, reason: "Restore the previous native pattern choice.",
                    acknowledged: true, editor: editor, restoring: true, recordHistory: false,
                    restoredPatternSHA256: desired.patternSHA256)
            }, failure: { [weak editor] error in editor?.mediaPanelToast = MediaPanelToast(message: error.localizedDescription) })
        }
    }

    private static var sessions: [ObjectIdentifier: Session] = [:]
    nonisolated static let decisionPath = "brief/pattern-selection.current.v1.json"

    static func isBusy(editor: EditorViewModel) -> Bool { sessions[ObjectIdentifier(editor)]?.history.isBusy == true }

    static func capture(editor: EditorViewModel, mode: String = "balanced", excluded: [String] = []) async throws -> Snapshot {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home),
              let key = editor.openWorkingCopyKey else { throw changed() }
        guard let generation = editor.openWorkingCopyGeneration else { throw changed() }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: declaration.packName,
            declaredBinding: declaration.binding, declaredProductionContract: declaration.productionContract)
        guard let provider = PackCatalog.registry(activePack: declaration.packName).patternProvider else {
            throw GateBlocked("This format pack has no director patterns. You can continue without a pattern.")
        }
        let loaded = try await Task.detached(priority: .userInitiated) {
            try load(root: root, declaration: declaration, provider: provider, mode: mode, excluded: excluded)
        }.value
        guard editor.workingRoot == home, editor.openWorkingCopyKey == key,
              editor.openWorkingCopyGeneration == generation,
              editor.declaredPluginName == declaration.packName, editor.declaredPluginBinding == declaration.binding,
              editor.declaredProductionContract == declaration.productionContract else { throw changed() }
        return .init(home: home, key: key, generation: generation, declaration: declaration, workflow: loaded.workflow,
            mode: mode, excluded: excluded, envelope: loaded.envelope, details: loaded.details,
            selectedID: loaded.brief.directorPattern, decision: loaded.decision, affect: loaded.affect,
            selectedPatternSHA256: loaded.brief.directorPattern.flatMap { loaded.patternBytes[$0] }.map { FileDigest.sha256(of: $0) },
            fingerprint: loaded.fingerprint,
            briefSHA256: loaded.briefSHA256, projectSHA256: loaded.projectSHA256, canEdit: loaded.canEdit, rawResult: loaded.rawResult)
    }

    static func select(_ id: String?, expected: Snapshot, reason: String, acknowledged: Bool,
                       editor: EditorViewModel) async throws {
        _ = try await apply(id, expected: expected, reason: reason, acknowledged: acknowledged, editor: editor,
            restoring: false, recordHistory: true, restoredPatternSHA256: nil)
    }

    private static func apply(_ id: String?, expected: Snapshot, reason: String, acknowledged: Bool,
                              editor: EditorViewModel, restoring: Bool, recordHistory: Bool,
                              restoredPatternSHA256: String?) async throws -> Revision {
        guard expected.canEdit, editor.openWorkingCopyGeneration == expected.generation,
              editor.workingRoot == expected.home, editor.openWorkingCopyKey == expected.key else { throw changed() }
        let history: PipelineNativeRevisionHistory<Revision>?
        if recordHistory {
            guard let manager = editor.undoManager else { throw GateBlocked("Open the project window before changing its pattern.") }
            sessions = sessions.filter { $0.value.editor != nil }
            let identity = ObjectIdentifier(editor)
            if let old = sessions[identity], old.home == expected.home, old.key == expected.key, old.generation == expected.generation {
                history = old.history
            } else {
                sessions[identity]?.history.clear()
                let session = Session(editor: editor, snapshot: expected, manager: manager)
                sessions[identity] = session; history = session.history
            }
        } else { history = nil }
        try history?.beginPublication()
        var holdsPublication = history != nil
        defer { if holdsPublication { history?.endPublication() } }
        let access = try PipelineNativeEditAccess(editor: editor, label: "Select director pattern")
        var holdsLease = true
        defer { if holdsLease { access.end(editor: editor) } }
        guard access.declaration == expected.declaration,
              let provider = PackCatalog.registry(activePack: expected.declaration.packName).patternProvider else { throw changed() }
        _ = try ProjectPackGate.requireLiveMutation(projectURL: access.home, declaredPack: access.declaration.packName,
            declaredBinding: access.declaration.binding, declaredProductionContract: access.declaration.productionContract)
        let task = Task.detached(priority: .userInitiated) {
            let current = try load(root: access.root, declaration: access.declaration, provider: provider,
                mode: expected.mode, excluded: expected.excluded)
            guard current.canEdit, current.fingerprint == expected.fingerprint else { throw changed() }
            let choice = current.envelope.recommendations?.results.first { $0.id == id }
            let selectedBytes: Data?
            if let id {
                guard let bytes = try provider.get(id: id) else { throw changed() }
                _ = try PatternRecommendationsModel.detail(bytes, expectedID: id)
                selectedBytes = bytes
                if restoring, FileDigest.sha256(of: bytes) != restoredPatternSHA256 { throw changed() }
                if !restoring {
                    guard let choice, !choice.excluded else { throw GateBlocked("An excluded pattern cannot be selected. Review its confirmed constraints or choose another pattern.") }
                    if choice.requiresDeliberateChoice {
                        guard acknowledged, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw GateBlocked("Confirm the warnings and give a reason for this deliberate pattern choice.")
                        }
                    }
                }
            } else { selectedBytes = nil }
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root)
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let verified = try load(root: staging, declaration: access.declaration, provider: provider,
                    mode: expected.mode, excluded: expected.excluded)
                guard verified.fingerprint == expected.fingerprint else { throw changed() }
                if let id, try provider.get(id: id) != selectedBytes { throw changed() }
                var brief = verified.brief
                let decisionID = UUID().uuidString.lowercased()
                brief.directorPattern = id; brief.generated = ISO8601DateFormatter().string(from: Date())
                brief.generator = "brief-native@pattern-selection/" + decisionID
                var range: PlaybackRangeV1?
                if verified.workflow.isProductionV2, verified.workflow.packID == "musicvideo" {
                    range = try PlanningWriterIO.read(PlaybackRangeV1.self, at: PlaybackRangeV1.currentPath, dataRoot: staging)
                    try PipelinePlaybackRangeWriter.requireCanonicalCurrent(range!, dataRoot: staging, workflowID: verified.workflow.contractID)
                }
                try PipelineBriefArtifactWriter.write(brief, dataRoot: staging, replacingNativePatternChoice: true)
                let briefBytes = try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.briefFile, dataRoot: staging))
                let decision = Decision(schema: "native-pattern-selection/v1", id: decisionID,
                    projectID: brief.project, patternID: id, previousPatternID: verified.brief.directorPattern,
                    inputFingerprint: verified.fingerprint, resultSHA256: FileDigest.sha256(of: verified.rawResult),
                    selectedPatternSHA256: selectedBytes.map { FileDigest.sha256(of: $0) },
                    briefSHA256: FileDigest.sha256(of: briefBytes),
                    warnings: choice?.warnings ?? [], reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                    selectedAt: brief.generated, restored: restoring)
                try publish(brief, decision: decision, workflow: verified.workflow,
                    declaration: access.declaration, resultBytes: verified.rawResult,
                    patternBytes: selectedBytes, briefBytes: briefBytes, priorRange: range, dataRoot: staging)
                return Revision(home: access.home, key: access.key, generation: expected.generation, patternID: id,
                    briefSHA256: try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.briefFile, dataRoot: staging)),
                    projectSHA256: try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.projectFile, dataRoot: staging)),
                    patternSHA256: selectedBytes.map { FileDigest.sha256(of: $0) }, mode: expected.mode, excluded: expected.excluded)
            }
            do { try fence.requireUnchanged(); return (transaction, fence) }
            catch { transaction.discard(); throw error }
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        defer { Task.detached { result.0.discard() } }
        try Task.checkCancellation()
        let written = try result.0.commit { _ in
            try access.requireCurrent(editor: editor)
            try history?.requireNoPendingRestore()
            guard editor.openWorkingCopyGeneration == expected.generation else { throw changed() }
            try result.1.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        access.end(editor: editor)
        holdsLease = false
        history?.record(before: .init(home: expected.home, key: expected.key, generation: expected.generation,
                patternID: expected.selectedID, briefSHA256: expected.briefSHA256, projectSHA256: expected.projectSHA256,
                patternSHA256: expected.selectedPatternSHA256, mode: expected.mode, excluded: expected.excluded),
                after: written, name: "Select Director Pattern")
        history?.endPublication(); holdsPublication = false
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return written
    }

    nonisolated private static func load(root: URL, declaration: ProjectPackGate.MutationDeclaration,
                                        provider: any PatternProviding, mode: String, excluded: [String]) throws -> Loaded {
        guard ["conservative", "balanced", "experimental"].contains(mode), Set(excluded).count == excluded.count,
              let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: declaration.binding,
                expectedProductionContract: declaration.productionContract) else { throw changed() }
        let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: root)
        let store = YAMLArtifactStore(dataRoot: root)
        let brief = try store.load(Brief.self, at: PipelineLayout.briefFile); try brief.validate()
        let project = try store.load(ProjectMeta.self, at: PipelineLayout.projectFile)
        guard brief.project == project.project else { throw changed() }
        let briefBytes = try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.briefFile, dataRoot: root))
        let projectSHA256 = try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.projectFile, dataRoot: root))
        var inputs = [FileDigest.sha256(of: briefBytes), projectSHA256,
            try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.gatesFile, dataRoot: root))]
        var options: [String: Any] = ["match_mode": mode, "excluded_pattern_ids": excluded]
        if let analysisURL = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: root), FileManager.default.fileExists(atPath: analysisURL.path) {
            let path = FrameInventory.relativePath(of: analysisURL, to: root)
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: root))
            let analysis = try JSONDecoder().decode(AnalysisSurfaceData.self, from: bytes)
            guard analysis.perceivedBpm.isFinite, analysis.perceivedBpm > 0,
                  let source = analysis.verifiedSourceURL(dataRoot: root) else { throw changed() }
            options["perceived_bpm"] = analysis.perceivedBpm
            inputs += [FileDigest.sha256(of: bytes), try FileDigest.sha256(of: source)]
        }
        let affectURL = root.appendingPathComponent("analysis/affect.json")
        var affect: String?
        if FileManager.default.fileExists(atPath: affectURL.path) {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve("analysis/affect.json", dataRoot: root))
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw changed() }
            func tags(_ key: String) throws -> [String] {
                guard let raw = object[key] else { return [] }
                if raw is NSNull { return [] }
                guard let values = raw as? [[String: Any]] else { throw changed() }
                return try values.map { value in
                    guard let tag = value["value"] as? String, AffectTagVocabulary.all.contains(tag),
                          let weight = value["weight"] as? Double, weight.isFinite, weight > 0 else { throw changed() }
                    return PatternRecommendationsModel.label(tag)
                }
            }
            let detected = try tags("detected"), overridden = try tags("override")
            let basis = object["basis"] as? String ?? "inferred"
            guard ["measured", "documented", "inferred"].contains(basis) else { throw changed() }
            affect = "Detected interpretation: \(detected.joined(separator: ", ")) · recorded basis: \(basis)"
            if !overridden.isEmpty { affect! += " · User override: " + overridden.joined(separator: ", ") }
            if let rationale = object["rationale"] as? String, !rationale.isEmpty { affect! += "\n" + rationale }
            options["affect_profile"] = object
            inputs.append(FileDigest.sha256(of: bytes))
        }
        let raw = try provider.recommend(briefJSON: JSONEncoder().encode(brief),
            optionsJSON: JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]))
        let envelope = try PatternRecommendationsModel.decode(raw)
        var details: [String: PatternRecommendationsModel.Detail] = [:]
        var patternBytes: [String: Data] = [:]
        for result in envelope.recommendations?.results ?? [] {
            guard let bytes = try provider.get(id: result.id) else { throw changed() }
            details[result.id] = try PatternRecommendationsModel.detail(bytes, expectedID: result.id)
            patternBytes[result.id] = bytes
        }
        if let selected = brief.directorPattern, patternBytes[selected] == nil, let bytes = try provider.get(id: selected) {
            _ = try PatternRecommendationsModel.detail(bytes, expectedID: selected)
            patternBytes[selected] = bytes
        }
        let recorded = try PipelinePatternSelectionEvidence.read(dataRoot: root)
        let decision = recorded?.decision.patternID == brief.directorPattern ? recorded?.decision : nil
        inputs += recorded?.references.map { $0.sha256 } ?? []
        let state = try ProjectStateBuilder.buildSnapshot(dataRoot: root, order: PhaseContractRuntime.order(workflow: workflow))
        inputs += [FileDigest.sha256(of: raw), mode] + excluded.sorted()
        inputs += patternBytes.keys.sorted().map { $0 + ":" + FileDigest.sha256(of: patternBytes[$0]!) }
        try fence.requireUnchanged()
        return .init(brief: brief, workflow: workflow, envelope: envelope, details: details, rawResult: raw,
            patternBytes: patternBytes, fingerprint: FileDigest.sha256(of: try PlanningWriterIO.json(inputs)),
            briefSHA256: FileDigest.sha256(of: briefBytes), projectSHA256: projectSHA256,
            decision: decision, canEdit: state.nextPhase == "brief", affect: affect)
    }

    nonisolated private static func publish(_ brief: Brief, decision: Decision, workflow: HostWorkflowKey,
                                            declaration: ProjectPackGate.MutationDeclaration, resultBytes: Data,
                                            patternBytes: Data?, briefBytes: Data, priorRange: PlaybackRangeV1?, dataRoot: URL) throws {
        let state = try ProjectStateBuilder.buildSnapshot(dataRoot: dataRoot, order: PhaseContractRuntime.order(workflow: workflow))
        guard state.nextPhase == "brief" else { throw changed() }
        let bytes = try PlanningWriterIO.json(decision)
        var files = [(decisionPath, bytes), ("brief/pattern-selections/\(decision.id).v1.json", bytes),
            ("brief/pattern-selections/\(decision.id).recommendations.json", resultBytes),
            ("brief/pattern-selections/\(decision.id).brief.yaml", briefBytes)]
        if let patternBytes { files.append(("brief/pattern-selections/\(decision.id).pattern.json", patternBytes)) }
        if workflow.isProductionV2 {
            let access = try PipelinePlanningWriteAccess(dataRoot: dataRoot, declaration: declaration, phase: "brief")
            let source = try PipelineStorySourceWriter.bindCurrentSelection(access: access)
            files.append((StorySourceV1.currentPath, try PlanningWriterIO.json(source)))
            if let range = priorRange {
                let currentBrief = try PlanningWriterIO.reference(PipelineLayout.briefFile, id: "brief", role: "core.brief", dataRoot: dataRoot)
                let inputs = range.header.inputs.map { $0.path == PipelineLayout.briefFile ? currentBrief : $0 }
                let rebound = PlaybackRangeV1(header: .init(projectID: brief.project, revision: range.header.revision,
                    origin: .userRevision, inputs: inputs), kind: range.kind, analysis: range.analysis,
                    timebase: range.timebase, audioDurationTicks: range.audioDurationTicks, startTicks: range.startTicks,
                    durationTicks: range.durationTicks, selectionReceipt: range.selectionReceipt)
                try rebound.validate()
                files.append((PlaybackRangeV1.currentPath, try PlanningWriterIO.json(rebound)))
            }
            try access.publish(files) { try HostProductionPhaseGate.requireCurrent(phase: "brief", dataRoot: dataRoot, workflow: workflow) }
        } else {
            for (path, bytes) in files {
                _ = try ProjectLocalFile.ensureDirectory((path as NSString).deletingLastPathComponent, dataRoot: dataRoot)
                try bytes.write(to: dataRoot.appendingPathComponent(path), options: .atomic)
            }
            try PipelinePhaseMutationRecorder.record(phase: "brief", dataRoot: dataRoot, captureLineage: true,
                declaredPack: declaration.packName, declaredBinding: declaration.binding,
                declaredProductionContract: declaration.productionContract)
        }
    }

    nonisolated private static func changed() -> GateBlocked {
        GateBlocked("The Brief, analysis, pattern library or project changed. Reload recommendations before choosing a pattern; reopen Brief to edit an approved choice.")
    }
}
