import Foundation
import NexGenEngine

enum ToolFailureKind: Sendable, Equatable {
    case agentCorrection
    case reviewChangedSource
    case reopenProject
    case hostBusy
    case phaseRecordRepair
    case approvalStructure

    var hostAction: AgentHostStateRecord.Action {
        switch self {
        case .reviewChangedSource: .reviewChangedSource
        case .reopenProject: .reopenProject
        case .hostBusy: .retryAfterHostRecovery
        case .agentCorrection, .phaseRecordRepair, .approvalStructure: .agentCorrection
        }
    }
}

struct ToolError: LocalizedError, Sendable {
    let message: String
    let kind: ToolFailureKind

    init(_ message: String, kind: ToolFailureKind = .agentCorrection) {
        self.message = message
        self.kind = kind
    }

    var errorDescription: String? { message }
}

/// Shared by the MCP server and the in-app agent.
/// Tool implementations live in the `ToolExecutor+*.swift` extension files.
@MainActor
final class ToolExecutor {
    typealias PhaseMutationRecorder = @MainActor (
        _ editor: EditorViewModel,
        _ phase: String,
        _ dataRoot: URL,
        _ captureLineage: Bool,
        _ declaredPack: String?,
        _ declaredBinding: ProjectPackBinding?
    ) async throws -> Void

    private let editorProvider: () -> EditorViewModel?
    let providerActivation: () -> ProviderActivation
    let productionRouteCandidates: ProductionRouteCandidateProvider
    let modelCatalog: ModelCatalog
    private let phaseMutationRecorder: PhaseMutationRecorder
    var editor: EditorViewModel? { editorProvider() }

    /// The hard gate refuses a phase's work tool until every earlier gate is approved. ON by default so
    /// EVERY production executor (agent + MCP runtime) enforces it; unit tests that exercise a tool in
    /// isolation opt out (they scaffold minimal state and don't walk the gate chain).
    private let enforceHardGates: Bool

    init(
        editor: EditorViewModel,
        enforceHardGates: Bool = true,
        providerActivation: @escaping () -> ProviderActivation = { ProviderActivation.current() },
        modelCatalog: ModelCatalog = .shared,
        productionRouteCandidates: ProductionRouteCandidateProvider? = nil,
        phaseMutationRecorder: @escaping PhaseMutationRecorder = ToolExecutor.defaultPhaseMutationRecorder
    ) {
        self.editorProvider = { [weak editor] in editor }
        self.enforceHardGates = enforceHardGates
        self.providerActivation = providerActivation
        self.modelCatalog = modelCatalog
        self.phaseMutationRecorder = phaseMutationRecorder
        self.productionRouteCandidates = productionRouteCandidates ?? {
            modelCatalog.productionRouteCandidates(activation: $0)
        }
    }

    init(
        editorProvider: @escaping () -> EditorViewModel?,
        enforceHardGates: Bool = true,
        providerActivation: @escaping () -> ProviderActivation = { ProviderActivation.current() },
        modelCatalog: ModelCatalog = .shared,
        productionRouteCandidates: ProductionRouteCandidateProvider? = nil,
        phaseMutationRecorder: @escaping PhaseMutationRecorder = ToolExecutor.defaultPhaseMutationRecorder
    ) {
        self.editorProvider = editorProvider
        self.enforceHardGates = enforceHardGates
        self.providerActivation = providerActivation
        self.modelCatalog = modelCatalog
        self.phaseMutationRecorder = phaseMutationRecorder
        self.productionRouteCandidates = productionRouteCandidates ?? {
            modelCatalog.productionRouteCandidates(activation: $0)
        }
    }

    static let defaultPhaseMutationRecorder: PhaseMutationRecorder = {
        editor,
        phase,
        dataRoot,
        captureLineage,
        declaredPack,
        declaredBinding in
        try await editor.pipelineAgentHarness.recordPhaseMutation(
            phase: phase,
            dataRoot: dataRoot,
            captureLineage: captureLineage,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
    }

    private var agentUndoStack: [String] = []
    var feedbackState = FeedbackState()
    let imageObservations = ImageObservationCache()

    func requirePhaseIdle(
        _ editor: EditorViewModel,
        dataRoot: URL
    ) throws {
        guard let running = editor.pipelinePhaseRunCoordinator.runningPhase(
            projectRoot: dataRoot
        ) else { return }
        throw ToolError(
            "Can't change pipeline state while \(running) is running. Wait for the phase to finish.",
            kind: .hostBusy
        )
    }

    func mutationPackDeclaration(
        _ editor: EditorViewModel,
        dataRoot: URL
    ) throws -> ProjectPackGate.MutationDeclaration {
        try mutationPackDeclaration(
            editor,
            projectURL: FrameInventory.projectHome(of: dataRoot)
        )
    }

    func mutationPackDeclaration(
        _ editor: EditorViewModel,
        projectURL: URL
    ) throws -> ProjectPackGate.MutationDeclaration {
        let target = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        if let workingRoot = editor.workingRoot,
           workingRoot.standardizedFileURL.resolvingSymlinksInPath() == target {
            return ProjectPackGate.MutationDeclaration(
                packName: editor.declaredPluginName,
                binding: editor.declaredPluginBinding
            )
        }
        do {
            return try ProjectPackGate.captureMutationDeclaration(
                projectURL: projectURL
            )
        } catch {
            throw ToolError(error.localizedDescription, kind: .reopenProject)
        }
    }

    func reserveDurablePipelineMutation(
        tool: ToolName,
        phase: String?,
        dataRoot: URL,
        editor: EditorViewModel
    ) throws -> UUID? {
        guard tool != .runPhase, tool.isDurableWrite else { return nil }
        return try reservePipelineMutation(
            label: phase ?? tool.rawValue,
            dataRoot: dataRoot,
            editor: editor
        )
    }

    func reservePipelineMutation(
        label: String,
        dataRoot: URL,
        editor: EditorViewModel
    ) throws -> UUID {
        guard let id = editor.pipelinePhaseRunCoordinator.beginMutation(
            projectRoot: dataRoot,
            label: label
        ) else {
            let active = editor.pipelinePhaseRunCoordinator.runningPhase(
                projectRoot: dataRoot
            ) ?? "pipeline phase"
            throw ToolError(
                "Can't change pipeline state while \(active) is running. "
                    + "Wait for the phase to finish.",
                kind: .hostBusy
            )
        }
        return id
    }

    func currentPhaseIfEnforced(
        tool: ToolName,
        editor: EditorViewModel,
        dataRoot: URL
    ) throws -> String? {
        guard enforceHardGates else { return nil }
        let declaration = try mutationPackDeclaration(
            editor,
            dataRoot: dataRoot
        )
        return try editor.pipelineAgentHarness.guardCurrentPhaseWork(
            tool: tool,
            dataRoot: dataRoot,
            declaredPack: declaration.packName,
            declaredBinding: declaration.binding
        )
    }

    func spendPipelineScope(
        tool: ToolName,
        editor: EditorViewModel
    ) throws -> SpendPipelineScope? {
        guard let dataRoot = editor.workingRoot.flatMap({
            DataRootResolver.dataRoot(of: $0)
        }) else { return nil }
        let phase = try currentPhaseIfEnforced(
            tool: tool,
            editor: editor,
            dataRoot: dataRoot
        )
        let declaration = try mutationPackDeclaration(
            editor,
            dataRoot: dataRoot
        )
        return SpendPipelineScope(
            dataRoot: dataRoot,
            phase: phase,
            tool: tool,
            declaredPack: declaration.packName,
            declaredBinding: declaration.binding,
            bindingResolution: ProjectPluginSettings.bindingResolution(
                projectURL: FrameInventory.projectHome(of: dataRoot)
            )
        )
    }

    func execute(
        name: String,
        args: [String: Any],
        origin: ToolCallOrigin = .direct,
        toolUseID: String? = nil
    ) async -> ToolResult {
        guard let tool = ToolName(rawValue: name) else {
            return .error("Unknown tool: \(name)")
        }
        guard let editor else { return .error("Editor not available") }
        let origin = normalizedToolCallOrigin(origin, editor: editor)
        let before = editor.timeline
        var result: ToolResult
        var guardedPhase: String?
        var guardedRoot: URL?
        var guardedDeclaration: ProjectPackGate.MutationDeclaration?
        var hostStatePhase: String?
        var hostStateRoot: URL?
        var mutationLease: (root: URL, id: UUID)?
        var artifactBefore: HostArtifactSnapshot?
        var writerEntered = false
        var writerReturnedSuccess = false
        var phaseRecordFailed = false
        var failureKind: ToolFailureKind = .agentCorrection
        let hostStateID = UUID()
        let hostToolUseID = toolUseID
        defer {
            if let mutationLease {
                editor.pipelinePhaseRunCoordinator.endMutation(
                    projectRoot: mutationLease.root,
                    id: mutationLease.id
                )
            }
        }
        let started = ContinuousClock.now
        Log.agent.notice(
            "tool start name=\(tool.rawValue)",
            telemetry: "Agent tool started",
            data: ["tool": tool.rawValue, "projectId": editor.projectId ?? "unknown"]
        )
        do {
            if let reason = editor.agentService.toolCallBlockReason(
                tool: tool,
                args: args,
                origin: origin
            ) {
                throw ToolError(reason)
            }
            guard let schema = ToolDefinitions.all.first(where: { $0.name == tool })?.inputSchema else {
                throw ToolError("Tool schema unavailable: \(tool.rawValue)")
            }
            try validateToolInput(in: args, against: schema, path: tool.rawValue)
            let resolved = try expandingIdPrefixes(in: args, editor: editor)
            if tool.isCanonicalArtifactWriter {
                hostStatePhase = tool.advancingPhase(args: resolved)
                hostStateRoot = try? resolveDataRoot(resolved, editor: editor)
            }
            if enforceHardGates {
                if let phase = tool.advancingPhase(args: resolved) {
                    let root = try resolveDataRoot(resolved, editor: editor)
                    let declaration = try mutationPackDeclaration(
                        editor,
                        dataRoot: root
                    )
                    guardedPhase = phase
                    guardedRoot = root
                    guardedDeclaration = declaration
                    try editor.pipelineAgentHarness.guardPhaseWork(
                        tool: tool,
                        phase: phase,
                        dataRoot: root,
                        declaredPack: declaration.packName,
                        declaredBinding: declaration.binding
                    )
                } else if tool.usesCurrentPipelinePhase {
                    let root = try resolveDataRoot(resolved, editor: editor)
                    let declaration = try mutationPackDeclaration(
                        editor,
                        dataRoot: root
                    )
                    guardedPhase = try editor.pipelineAgentHarness.guardCurrentPhaseWork(
                        tool: tool,
                        dataRoot: root,
                        declaredPack: declaration.packName,
                        declaredBinding: declaration.binding
                    )
                    guardedRoot = root
                    guardedDeclaration = declaration
                }
            }
            if tool != .runPhase, let guardedRoot {
                try requirePhaseIdle(editor, dataRoot: guardedRoot)
            }
            if tool != .runPhase,
               tool.isDurableWrite,
               let guardedRoot {
                let id = try reserveDurablePipelineMutation(
                    tool: tool,
                    phase: guardedPhase,
                    dataRoot: guardedRoot,
                    editor: editor
                )
                mutationLease = id.map { (root: guardedRoot, id: $0) }
            }
            if tool.isDurableWrite,
               let mutationRoot = guardedRoot ?? (try? resolveDataRoot(resolved, editor: editor)) {
                let declaration: ProjectPackGate.MutationDeclaration
                if let guardedDeclaration {
                    declaration = guardedDeclaration
                } else {
                    declaration = try mutationPackDeclaration(
                        editor,
                        dataRoot: mutationRoot
                    )
                }
                do {
                    _ = try ProjectPackGate.requireLiveMutation(
                        projectURL: FrameInventory.projectHome(of: mutationRoot),
                        declaredPack: declaration.packName,
                        declaredBinding: declaration.binding
                    )
                } catch {
                    throw ToolError(error.localizedDescription, kind: .reopenProject)
                }
            }
            if tool.isDurableWrite,
               tool != .writeShotlist,
               editor.projectURL != nil {
                guard let key = editor.openWorkingCopyKey else {
                    throw ToolError(
                        "The project working copy is unavailable. Reopen the project before writing.",
                        kind: .reopenProject
                    )
                }
                do {
                    try ProjectWorkingCopy.markDirty(key: key)
                } catch {
                    throw ToolError(error.localizedDescription, kind: .reopenProject)
                }
            }
            if tool.isCanonicalArtifactWriter,
               artifactBefore == nil,
               let hostStateRoot {
                artifactBefore = await hostArtifactSnapshot(
                    phase: hostStatePhase,
                    dataRoot: hostStateRoot
                )
            }
            if tool.isCanonicalArtifactWriter, let phase = hostStatePhase {
                editor.agentService.recordHostState(
                    AgentHostStateRecord(
                        id: hostStateID,
                        toolUseID: hostToolUseID,
                        state: .draft,
                        phase: phase,
                        toolName: tool.rawValue,
                        action: .none,
                        artifactPath: artifactBefore?.path,
                        byteComparison: nil,
                        previousSHA256: artifactBefore?.bytes.map {
                            FileDigest.sha256(of: $0)
                        },
                        currentSHA256: nil
                    ),
                    origin: origin,
                    toolUseID: hostToolUseID
                )
            }
            writerEntered = tool.isCanonicalArtifactWriter
            result = try await run(
                tool,
                editor,
                resolved,
                origin: origin,
                toolUseID: hostToolUseID,
                hostStateID: hostStateID
            )
            writerReturnedSuccess = tool.isCanonicalArtifactWriter
                && !result.isError
                && result.turnDisposition == .continueTurn
            if tool != .runPhase,
               tool != .writeShotlist,
               !result.isError,
               result.turnDisposition == .continueTurn,
               let phase = guardedPhase,
               let root = guardedRoot,
               tool.invalidatesPhaseState(args: resolved, dataRoot: root) {
                if mutationLease == nil {
                    try requirePhaseIdle(editor, dataRoot: root)
                }
                let declaration: ProjectPackGate.MutationDeclaration
                if let guardedDeclaration {
                    declaration = guardedDeclaration
                } else {
                    declaration = try mutationPackDeclaration(
                        editor,
                        dataRoot: root
                    )
                }
                do {
                    try await phaseMutationRecorder(
                        editor,
                        phase,
                        root,
                        tool.writesPhaseArtifact(
                            args: resolved,
                            dataRoot: root
                        ),
                        declaration.packName,
                        declaration.binding
                    )
                    await editor.refreshEngineState()
                } catch {
                    phaseRecordFailed = true
                    failureKind = .phaseRecordRepair
                    result = .error(
                        "The artifact bytes were written, but the host could not record the "
                            + "phase mutation. The written bytes remain in the working copy. "
                            + "Repair the phase record before approval: \(error.localizedDescription)"
                    )
                }
            }
            // Record any edit that actually changed the timeline so `undo` can revert it.
            if tool != .undo, !result.isError, editor.timeline != before,
               let actionName = editor.undoManager?.undoActionName {
                agentUndoStack.append(actionName)
            }
        } catch let err as ToolError {
            failureKind = err.kind
            result = .error(err.message)
        } catch {
            result = .error(error.localizedDescription)
        }
        let state = await hostStateRecord(
            tool: tool,
            args: args,
            result: result,
            phase: hostStatePhase ?? guardedPhase,
            dataRoot: hostStateRoot ?? guardedRoot,
            artifactBefore: artifactBefore,
            writerEntered: writerEntered,
            writerReturnedSuccess: writerReturnedSuccess,
            phaseRecordFailed: phaseRecordFailed,
            failureKind: failureKind,
            pendingApproval: editor.agentService.pendingGateApproval,
            toolUseID: hostToolUseID,
            hostStateID: hostStateID
        )
        if let state {
            editor.agentService.recordHostState(
                state,
                origin: origin,
                toolUseID: hostToolUseID
            )
            if state.state == .persistedPhaseRecordFailed,
               !phaseRecordFailed {
                let detail = result.content.compactMap { block -> String? in
                    guard case .text(let text) = block else { return nil }
                    return text
                }.joined(separator: " ")
                result = .error(
                    "The writer reported an error after the project artifact bytes changed. "
                        + "The changed bytes remain in the working copy, but phase bookkeeping "
                        + "must be repaired before approval. Writer error: \(detail)"
                )
            }
        }
        // A successful pipeline write diverges the working copy from the saved package — mark the
        // document edited so ⌘S persists it and the user is warned before closing without saving.
        if (!result.isError || writerReturnedSuccess
            || state?.state == .persistedPhaseRecordFailed),
           result.turnDisposition == .continueTurn,
           tool.isDurableWrite {
            editor.onPipelineChanged?()
        }
        feedbackState.record(result, for: tool)
        let elapsed = started.duration(to: .now).seconds
        let telemetry = result.isError ? "Agent tool failed" : "Agent tool finished"
        let payload: Telemetry.Payload = [
            "tool": tool.rawValue,
            "durationSeconds": elapsed,
            "timelineChanged": editor.timeline != before
        ]
        if result.isError {
            Log.agent.warning(
                "tool failed name=\(tool.rawValue) duration=\(elapsed)",
                telemetry: telemetry,
                data: payload
            )
        } else {
            Log.agent.notice(
                "tool ok name=\(tool.rawValue) duration=\(elapsed)",
                telemetry: telemetry,
                data: payload
            )
        }
        // Shorten on the post-run state so newly created ids in summaries are shortened too.
        return shorteningIds(in: result, editor: editor)
    }

    struct HostArtifactSnapshot: Sendable {
        let path: String
        let exists: Bool
        let bytes: Data?
    }

    private func hostStateRecord(
        tool: ToolName,
        args: [String: Any],
        result: ToolResult,
        phase guardedPhase: String?,
        dataRoot: URL?,
        artifactBefore: HostArtifactSnapshot?,
        writerEntered: Bool,
        writerReturnedSuccess: Bool,
        phaseRecordFailed: Bool,
        failureKind: ToolFailureKind,
        pendingApproval: GateApproval?,
        toolUseID: String?,
        hostStateID: UUID
    ) async -> AgentHostStateRecord? {
        let phase = guardedPhase ?? tool.advancingPhase(args: args)
        if tool.isCanonicalArtifactWriter, let phase {
            guard writerEntered else {
                let action = failureKind.hostAction
                guard action != .agentCorrection else { return nil }
                return AgentHostStateRecord(
                    id: hostStateID,
                    toolUseID: toolUseID,
                    state: .writeBlocked,
                    phase: phase,
                    toolName: tool.rawValue,
                    action: action,
                    artifactPath: nil,
                    byteComparison: nil,
                    previousSHA256: nil,
                    currentSHA256: nil
                )
            }
            let artifactAfter: HostArtifactSnapshot?
            if let dataRoot {
                artifactAfter = await hostArtifactSnapshot(
                    phase: phase,
                    dataRoot: dataRoot
                )
            } else {
                artifactAfter = nil
            }
            let comparison = compare(before: artifactBefore, after: artifactAfter)
            let state: AgentHostStateRecord.State
            let action: AgentHostStateRecord.Action
            if writerReturnedSuccess, !phaseRecordFailed {
                state = .persisted
                action = .reviewForApproval
            } else if phaseRecordFailed
                || comparison == .created
                || comparison == .changed {
                state = .persistedPhaseRecordFailed
                action = .agentCorrection
            } else if comparison == .unchanged {
                state = .writeRejected
                action = failureKind.hostAction
            } else {
                state = .writeOutcomeUnavailable
                action = failureKind.hostAction
            }
            return AgentHostStateRecord(
                id: hostStateID,
                toolUseID: toolUseID,
                state: state,
                phase: phase,
                toolName: tool.rawValue,
                action: action,
                artifactPath: artifactAfter?.path ?? artifactBefore?.path,
                byteComparison: comparison,
                previousSHA256: artifactBefore?.bytes.map {
                    FileDigest.sha256(of: $0)
                },
                currentSHA256: artifactAfter?.bytes.map {
                    FileDigest.sha256(of: $0)
                }
            )
        }

        let requestsApproval = tool == .approveGate || (
            tool == .setGateState
                && (args["state"] as? String).flatMap(GateState.init(rawValue:))
                    .map(GateApproval.isApproval) == true
        )
        guard requestsApproval,
              !result.isError,
              result.turnDisposition == .suspendTurn,
              let phase = (args["phase"] as? String)?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              !phase.isEmpty,
              let payload = result.content.compactMap({ block -> String? in
                  guard case .text(let text) = block else { return nil }
                  return text
              }).first.flatMap({ text -> [String: Any]? in
                  guard let data = text.data(using: .utf8) else { return nil }
                  guard let object = try? JSONSerialization.jsonObject(with: data) else {
                      return nil
                  }
                  return object as? [String: Any]
              }),
              payload["status"] as? String == "approval_pending",
              payload["phase"] as? String == phase,
              payload["requested_phase"] as? String == phase,
              payload["new_request"] as? Bool == true,
              pendingApproval?.phase == phase else { return nil }
        return AgentHostStateRecord(
            id: hostStateID,
            toolUseID: toolUseID,
            state: .checked,
            phase: phase,
            toolName: tool.rawValue,
            action: .reviewForApproval,
            artifactPath: nil,
            byteComparison: nil,
            previousSHA256: nil,
            currentSHA256: nil
        )
    }

    func hostArtifactSnapshot(
        phase: String?,
        dataRoot: URL
    ) async -> HostArtifactSnapshot? {
        guard let phase, let url = currentArtifactURL(phase: phase, dataRoot: dataRoot) else {
            return nil
        }
        return await Task.detached(priority: .utility) {
            let root = dataRoot.standardizedFileURL
            let candidate = url.standardizedFileURL
            let lexicalPrefix = root.path + "/"
            guard candidate.path.hasPrefix(lexicalPrefix) else { return nil }
            let relativePath = String(candidate.path.dropFirst(lexicalPrefix.count))
            let resolvedRoot = root.resolvingSymlinksInPath()
            let target = candidate.resolvingSymlinksInPath()
            let resolvedPrefix = resolvedRoot.path + "/"
            guard target.path.hasPrefix(resolvedPrefix) else { return nil }
            let manager = FileManager.default
            guard manager.fileExists(atPath: target.path) else {
                return HostArtifactSnapshot(
                    path: relativePath,
                    exists: false,
                    bytes: nil
                )
            }
            let values = try? target.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
            ])
            let maximumBytes = 16 * 1_024 * 1_024
            guard values?.isRegularFile == true,
                  let fileSize = values?.fileSize,
                  fileSize >= 0,
                  fileSize <= maximumBytes else {
                return HostArtifactSnapshot(
                    path: relativePath,
                    exists: true,
                    bytes: nil
                )
            }
            guard let handle = try? FileHandle(forReadingFrom: target) else {
                return HostArtifactSnapshot(
                    path: relativePath,
                    exists: true,
                    bytes: nil
                )
            }
            defer { try? handle.close() }
            guard let bytes = try? handle.read(upToCount: maximumBytes + 1),
                  bytes.count <= maximumBytes else {
                return HostArtifactSnapshot(
                    path: relativePath,
                    exists: true,
                    bytes: nil
                )
            }
            return HostArtifactSnapshot(
                path: relativePath,
                exists: true,
                bytes: bytes
            )
        }.value
    }

    private func currentArtifactURL(phase: String, dataRoot: URL) -> URL? {
        let relative: String?
        switch phase {
        case "analysis":
            return AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot)
        case "brief": relative = PipelineLayout.briefFile
        case "production_design": relative = PipelineLayout.productionDesignFile
        case "treatment": relative = PipelineLayout.treatmentCurrentFile
        case "storyboard": relative = PipelineLayout.storyboardCurrentFile
        case "bible": relative = PipelineLayout.bibleFile
        case "shotlist":
            guard let version = latestShotlistVersion(dataRoot: dataRoot) else { return nil }
            relative = PipelineLayout.shotlistVersionFile(version)
        default: relative = nil
        }
        return relative.map { PipelineLayout.url($0, in: dataRoot) }
    }

    private func compare(
        before: HostArtifactSnapshot?,
        after: HostArtifactSnapshot?
    ) -> AgentHostStateRecord.ByteComparison {
        guard let before, let after else { return .unavailable }
        if !before.exists, !after.exists { return .unchanged }
        if before.exists, !after.exists { return .changed }
        guard after.exists, let current = after.bytes else { return .unavailable }
        if !before.exists { return .created }
        guard let previous = before.bytes else { return .unavailable }
        return previous == current ? .unchanged : .changed
    }

    private func normalizedToolCallOrigin(
        _ origin: ToolCallOrigin,
        editor: EditorViewModel
    ) -> ToolCallOrigin {
        guard case .embeddedRuntime(let chatSessionID, let mcpSessionID) = origin,
              !editor.agentService.sessions.contains(where: { $0.id == chatSessionID }) else {
            return origin
        }
        return .externalMCP(sessionID: mcpSessionID)
    }

    private func run(
        _ tool: ToolName,
        _ editor: EditorViewModel,
        _ args: [String: Any],
        origin: ToolCallOrigin,
        toolUseID: String?,
        hostStateID: UUID
    ) async throws -> ToolResult {
        switch tool {
        case .getProductionKnowledge: return try getProductionKnowledge(args)
        case .getTimeline:   return try await getTimeline(editor, args)
        case .getMedia:      return try getMedia(editor)
        case .inspectMedia:  return try await inspectMedia(editor, args)
        case .getTranscript: return try await getTranscript(editor, args)
        case .inspectTimeline: return try await inspectTimeline(editor, args)
        case .searchMedia:   return try await searchMedia(editor, args)
        case .applyColor:    return try applyColor(editor, args)
        case .applyEffect:   return try applyEffect(editor, args)
        case .inspectColor:  return try await inspectColor(editor, args)
        case .addClips:         return try addClips(editor, args)
        case .insertClips:      return try insertClips(editor, args)
        case .removeClips:      return try removeClips(editor, args)
        case .removeTracks:     return try removeTracks(editor, args)
        case .moveClips:        return try moveClips(editor, args)
        case .setClipProperties: return try setClipProperties(editor, args)
        case .setKeyframes:     return try setKeyframes(editor, args)
        case .splitClip:        return try splitClip(editor, args)
        case .rippleDeleteRanges: return try rippleDeleteRanges(editor, args)
        case .removeWords:   return try await removeWords(editor, args)
        case .syncAudio:     return try await syncAudio(editor, args)
        case .undo:          return try undo(editor)
        case .addTexts:      return try addTexts(editor, args)
        case .addCaptions:   return try await addCaptions(editor, args)
        case .exportProject: return try await exportProject(editor, args)
        case .showDialog: return try showDialog(editor, args, origin: origin)
        case .showBlocks: return try showBlocks(args)
        case .compilePrompt: return try await compilePrompt(editor, args)
        case .generateVideo:
            await CatalogDiscovery.ensureCurrent()
            return try await generate(editor, args, type: .video, origin: origin)
        case .generateImage:
            await CatalogDiscovery.ensureCurrent()
            return try await generate(editor, args, type: .image, origin: origin)
        case .prepareGenerationBatch:
            return try await prepareGenerationBatch(editor, args, origin: origin)
        case .getGenerationBatches:
            return try await getGenerationBatches(editor, args)
        case .generateAudio:
            await CatalogDiscovery.ensureCurrent()
            return try await generateAudio(editor, args, origin: origin)
        case .upscaleMedia:
            await CatalogDiscovery.ensureCurrent()
            return try await upscaleMedia(editor, args, origin: origin)
        case .importMedia:   return try await importMedia(editor, args)
        case .listModels:
            await CatalogDiscovery.ensureCurrent()
            return listModels(args)
        case .listFolders:   return listFolders(editor)
        case .createFolder:  return try createFolder(editor, args)
        case .moveToFolder:  return try moveToFolder(editor, args)
        case .renameMedia:   return try renameMedia(editor, args)
        case .renameFolder:  return try renameFolder(editor, args)
        case .deleteMedia:   return try deleteMedia(editor, args)
        case .deleteFolder:  return try deleteFolder(editor, args)
        case .sendFeedback:  return try await sendFeedback(editor, args)
        case .getProjectState:      return try getProjectState(editor, args)
        case .listPhases:           return try listPhasesTool(editor, args)
        case .getBible:             return try getBible(editor, args)
        case .runSanity:            return try runSanityTool(editor, args)
        case .suggestPatterns:      return try suggestPatternsTool(editor, args)
        case .recordAffect:         return try recordAffectTool(editor, args)
        case .writeAnalysisInterpretation:
            return try writeAnalysisInterpretationTool(editor, args)
        case .writeBrief:           return try writeBriefTool(editor, args)
        case .writeProductionDesign: return try writeProductionDesignTool(editor, args)
        case .writeTreatment:       return try writeTreatmentTool(editor, args)
        case .writeStoryboard:      return try writeStoryboardTool(editor, args)
        case .writeBible:           return try writeBibleTool(editor, args)
        case .writeShotlist:        return try writeShotlistTool(editor, args)
        case .writePhaseExtension:  return try writePhaseExtensionTool(editor, args)
        case .getPattern:           return try getPatternTool(editor, args)
        case .initProject:          return try initProjectTool(editor, args)
        case .approveGate:
            return try await approveGateTool(
                editor,
                args,
                origin: origin,
                toolUseID: toolUseID,
                hostStateID: hostStateID
            )
        case .rewind:               return try rewindTool(editor, args)
        case .estimateCost:         return try estimateCostTool(editor, args)
        case .showArtifact:         return try showArtifactTool(editor, args)
        case .listProjectFiles:     return try listProjectFilesTool(editor, args)
        case .copyProjectFile:      return try copyProjectFileTool(editor, args)
        case .runPhase:             return try await runPhaseTool(editor, args)
        case .attachSong:           return try await attachSongTool(editor, args)
        case .nextRenderShot:       return try await nextRenderShotTool(editor, args)
        case .recordRender:         return try await recordRenderTool(editor, args)
        case .getRenderManifest:    return try getRenderManifestTool(editor, args)
        case .getFramesManifest:    return try getFramesManifestTool(editor, args)
        case .saveFrameAudit:       return try saveFrameAuditTool(editor, args)
        case .getFrameAudit:        return try getFrameAuditTool(editor, args)
        case .cropToAspect:         return try await cropToAspectTool(editor, args)
        case .extractScene3dPovs:   return try extractScene3dPovsTool(editor, args)
        case .assembleTimeline:     return try await assembleTimelineTool(editor, args)
        case .getLedger:            return try getLedgerTool(editor, args)
        case .setLedgerAttribute:   return try setLedgerAttributeTool(editor, args)
        case .lockLedgerAttribute:  return try lockLedgerAttributeTool(editor, args)
        case .removeLedgerAttribute: return try removeLedgerAttributeTool(editor, args)
        case .resolveModel:         return try resolveModelTool(editor, args)
        case .getUIContract:        return try getUIContractTool(editor)
        case .setGateState:
            return try await setGateStateTool(
                editor,
                args,
                origin: origin,
                toolUseID: toolUseID,
                hostStateID: hostStateID
            )
        case .runProviderTool:      return try await runProviderTool(editor, args, origin: origin)
        }
    }

    /// Reverts the assistant's most recent timeline edit. Refuses to undo the user's own edits.
    func undo(_ editor: EditorViewModel) throws -> ToolResult {
        guard let expected = agentUndoStack.last else {
            throw ToolError("No assistant edit to undo this session. The user's own edits are theirs to undo.")
        }
        guard let undoManager = editor.undoManager, undoManager.canUndo else {
            agentUndoStack.removeAll()
            throw ToolError("Nothing to undo.")
        }
        guard undoManager.undoActionName == expected else {
            throw ToolError("The most recent change ('\(undoManager.undoActionName)') wasn't made by the assistant — not undoing it.")
        }
        undoManager.undo()
        agentUndoStack.removeLast()
        return .ok("Undid: \(expected). The timeline is restored to its state before that edit; re-read with get_timeline or get_transcript before editing again.")
    }

    // Shared helpers used by tool extensions in other files.

    func asset(_ id: String, editor: EditorViewModel, label: String = "Media asset") throws -> MediaAsset {
        guard let asset = editor.mediaAssets.first(where: { $0.id == id }) else {
            throw ToolError("\(label) not found: \(id)")
        }
        return asset
    }

    func resolveFolderId(
        _ args: [String: Any], editor: EditorViewModel, fallbackReferences: [MediaAsset] = []
    ) throws -> String? {
        if let id = args.string("folderId") {
            guard editor.folder(id: id) != nil else {
                throw ToolError("folderId not found: \(id)")
            }
            return id
        }
        return fallbackReferences.last?.folderId
    }

    nonisolated static func jsonString(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func withUndoGroup<T>(_ editor: EditorViewModel, actionName: String, _ work: () throws -> T) rethrows -> T {
        editor.undoManager?.beginUndoGrouping()
        defer {
            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName(actionName)
        }
        return try work()
    }
}

private func validateToolInput(
    in value: Any,
    against schema: [String: Any],
    path: String
) throws {
    if let alternatives = schema["anyOf"] as? [[String: Any]] {
        var firstError: ToolError?
        var matchingTypeError: ToolError?
        var preferredError: ToolError?
        let preferredAlternative = preferredAnyOfAlternative(
            for: value,
            in: alternatives
        )
        var matches = false
        for (index, alternative) in alternatives.enumerated() {
            do {
                try validateToolInput(in: value, against: alternative, path: path)
                matches = true
                break
            } catch let error as ToolError {
                firstError = firstError ?? error
                if schemaTypeMatches(value, type: alternative["type"] as? String) {
                    matchingTypeError = matchingTypeError ?? error
                }
                if preferredAlternative == index {
                    preferredError = error
                }
            }
        }
        if !matches {
            throw preferredError ?? matchingTypeError ?? firstError
                ?? ToolError("\(path): does not match any allowed schema")
        }
    }

    let type = schema["type"] as? String
    switch type {
    case "object":
        guard let object = value as? [String: Any] else {
            throw ToolError("\(path): expected object")
        }
        let properties = objectSchemaProperties(schema["properties"])
        let additional = schema["additionalProperties"]
        let required = Set(schema["required"] as? [String] ?? [])
        let missing = required.subtracting(object.keys)
        if let key = missing.sorted().first {
            throw ToolError("\(path): missing required field '\(key)'")
        }

        for key in object.keys.sorted() {
            let childPath = path.isEmpty ? key : "\(path).\(key)"
            let childValue = object[key]!
            if let childSchema = properties[key] {
                try validateToolInput(in: childValue, against: childSchema, path: childPath)
            } else if let allowsAdditional = additional as? Bool {
                if !allowsAdditional {
                    throw ToolError("\(path): unknown field '\(key)'")
                }
            } else if let additionalSchema = additional as? [String: Any] {
                try validateToolInput(
                    in: childValue,
                    against: additionalSchema,
                    path: childPath
                )
            } else {
                throw ToolError("\(path): object schema has no additionalProperties policy")
            }
        }
    case "array":
        guard let values = value as? [Any] else {
            throw ToolError("\(path): expected array")
        }
        if let minimum = schema["minItems"] as? Int, values.count < minimum {
            throw ToolError("\(path): expected at least \(minimum) item(s)")
        }
        if let maximum = schema["maxItems"] as? Int, values.count > maximum {
            throw ToolError("\(path): expected at most \(maximum) item(s)")
        }
        guard let itemSchema = schema["items"] as? [String: Any] else {
            throw ToolError("\(path): array schema has no items policy")
        }
        for (index, item) in values.enumerated() {
            try validateToolInput(
                in: item,
                against: itemSchema,
                path: "\(path)[\(index)]"
            )
        }
    case "string":
        guard let string = value as? String else {
            throw ToolError("\(path): expected string")
        }
        if let minimum = schema["minLength"] as? Int,
           string.count < minimum {
            throw ToolError("\(path): expected at least \(minimum) character(s)")
        }
        if let maximum = schema["maxLength"] as? Int,
           string.count > maximum {
            throw ToolError("\(path): expected at most \(maximum) character(s)")
        }
        if let pattern = schema["pattern"] as? String,
           string.range(of: pattern, options: .regularExpression) == nil {
            throw ToolError("\(path): does not match required pattern")
        }
    case "integer":
        guard isJSONNumber(value, integerOnly: true) else {
            throw ToolError("\(path): expected integer")
        }
        try validateNumericBounds(value, schema: schema, path: path)
    case "number":
        guard isJSONNumber(value, integerOnly: false) else {
            if !(value is Bool), let number = value as? NSNumber,
               !number.doubleValue.isFinite {
                throw ToolError("\(path): expected finite number")
            }
            throw ToolError("\(path): expected number")
        }
        try validateNumericBounds(value, schema: schema, path: path)
    case "boolean":
        guard value is Bool else { throw ToolError("\(path): expected boolean") }
    case nil:
        break
    default:
        throw ToolError("\(path): unsupported schema type '\(type ?? "?")'")
    }

    if let allowed = schema["enum"] as? [String] {
        guard let string = value as? String, allowed.contains(string) else {
            throw ToolError(
                "\(path): expected one of \(allowed.joined(separator: ", ")) (got \(String(describing: value)))"
            )
        }
    }
}

private func preferredAnyOfAlternative(
    for value: Any,
    in alternatives: [[String: Any]]
) -> Int? {
    guard let object = value as? [String: Any] else { return nil }
    for key in object.keys.sorted() {
        guard let string = object[key] as? String else { continue }
        let matches = alternatives.indices.filter { index in
            let properties = objectSchemaProperties(
                alternatives[index]["properties"]
            )
            return (properties[key]?["enum"] as? [String])?.contains(string) == true
        }
        if matches.count == 1 { return matches[0] }
    }
    return nil
}

private func schemaTypeMatches(_ value: Any, type: String?) -> Bool {
    switch type {
    case "object": return value is [String: Any]
    case "array": return value is [Any]
    case "string": return value is String
    case "integer", "number": return !(value is Bool) && value is NSNumber
    case "boolean": return value is Bool
    case nil: return true
    default: return false
    }
}

private func isJSONNumber(_ value: Any, integerOnly: Bool) -> Bool {
    guard !(value is Bool), let number = value as? NSNumber else { return false }
    let double = number.doubleValue
    guard double.isFinite else { return false }
    if !integerOnly { return true }
    return double.isFinite && double.rounded(.towardZero) == double
}

private func validateNumericBounds(
    _ value: Any,
    schema: [String: Any],
    path: String
) throws {
    guard let number = value as? NSNumber else { return }
    let double = number.doubleValue
    if let minimum = schema["minimum"] as? NSNumber,
       double < minimum.doubleValue {
        throw ToolError("\(path): expected at least \(minimum)")
    }
    if let maximum = schema["maximum"] as? NSNumber,
       double > maximum.doubleValue {
        throw ToolError("\(path): expected at most \(maximum)")
    }
}

private func objectSchemaProperties(_ value: Any?) -> [String: [String: Any]] {
    if let properties = value as? [String: [String: Any]] {
        return properties
    }
    guard let properties = value as? [String: Any] else { return [:] }
    return properties.compactMapValues { $0 as? [String: Any] }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Throws if `entry` carries any keys outside `allowed`. `path` prefixes the error (e.g. "entries[3]").
func validateUnknownKeys(_ entry: [String: Any], allowed: Set<String>, path: String) throws {
    let unknown = Set(entry.keys).subtracting(allowed)
    guard unknown.isEmpty else {
        throw ToolError("\(path): unknown field(s) '\(unknown.sorted().joined(separator: "', '"))'. Allowed: \(allowed.sorted().joined(separator: ", ")).")
    }
}

protocol DecodableToolArgs: Decodable {
    static var allowedKeys: Set<String> { get }
}

func decodeToolArgs<T: DecodableToolArgs>(_ dict: [String: Any], path: String) throws -> T {
    try validateUnknownKeys(dict, allowed: T.allowedKeys, path: path)
    if let badPath = firstNonFiniteNumberPath(in: dict, path: path) {
        throw ToolError("\(badPath): value must be finite")
    }
    let data: Data
    do { data = try JSONSerialization.data(withJSONObject: dict) }
    catch { throw ToolError("\(path): could not re-serialize args (\(error.localizedDescription))") }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch let e as DecodingError {
        throw ToolError(formatDecodingError(e, path: path))
    } catch {
        throw ToolError("\(path): \(error.localizedDescription)")
    }
}

private func firstNonFiniteNumberPath(in value: Any, path: String) -> String? {
    if let d = value as? Double, !d.isFinite { return path }
    if let n = value as? NSNumber, !n.doubleValue.isFinite { return path }
    if let arr = value as? [Any] {
        for (i, v) in arr.enumerated() {
            if let p = firstNonFiniteNumberPath(in: v, path: "\(path)[\(i)]") { return p }
        }
    }
    if let dict = value as? [String: Any] {
        for (k, v) in dict {
            if let p = firstNonFiniteNumberPath(in: v, path: "\(path).\(k)") { return p }
        }
    }
    return nil
}

private func formatDecodingError(_ error: DecodingError, path: String) -> String {
    func prefix(_ ctx: DecodingError.Context) -> String {
        let trail = ctx.codingPath.map { k in
            k.intValue.map { "[\($0)]" } ?? ".\(k.stringValue)"
        }.joined()
        return path + trail
    }
    switch error {
    case .keyNotFound(let key, let ctx):
        return "\(prefix(ctx)): missing required field '\(key.stringValue)'"
    case .typeMismatch(let type, let ctx):
        return "\(prefix(ctx)): expected \(type), got something else"
    case .valueNotFound(let type, let ctx):
        return "\(prefix(ctx)): missing required \(type) value"
    case .dataCorrupted(let ctx):
        return "\(prefix(ctx)): \(ctx.debugDescription)"
    @unknown default:
        return "\(path): \(error.localizedDescription)"
    }
}

func parseColorHex(_ hex: String?, path: String) throws -> TextStyle.RGBA? {
    guard let hex else { return nil }
    guard let c = TextStyle.RGBA(hex: hex) else {
        throw ToolError("\(path): invalid color '\(hex)'. Expected '#RRGGBB' or '#RRGGBBAA'.")
    }
    return c
}

func parseAlignment(_ raw: String?, path: String) throws -> TextStyle.Alignment? {
    guard let raw else { return nil }
    guard let a = TextStyle.Alignment(rawValue: raw) else {
        throw ToolError("\(path): invalid alignment '\(raw)'. Expected 'left', 'center', or 'right'.")
    }
    return a
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let v = self[key] as? String, !v.isEmpty { return v }
        return nil
    }
    func int(_ key: String) -> Int? {
        if let v = self[key] as? Int { return v }
        if let v = self[key] as? Double { return Int(v) }
        if let v = self[key] as? NSNumber { return v.intValue }
        if let v = self[key] as? String { return Int(v) }
        return nil
    }
    func double(_ key: String) -> Double? {
        if let v = self[key] as? Double { return v }
        if let v = self[key] as? Int { return Double(v) }
        if let v = self[key] as? NSNumber { return v.doubleValue }
        if let v = self[key] as? String { return Double(v) }
        return nil
    }
    func bool(_ key: String) -> Bool? {
        if let v = self[key] as? Bool { return v }
        if let v = self[key] as? NSNumber { return v.boolValue }
        if let v = self[key] as? String { return Bool(v) }
        return nil
    }
    func stringArray(_ key: String) -> [String] {
        (self[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }
    func requireString(_ key: String) throws -> String {
        guard let v = self[key] as? String else { throw ToolError("Missing required argument: \(key)") }
        return v
    }
    func requireInt(_ key: String) throws -> Int {
        guard let v = int(key) else { throw ToolError("Missing required argument: \(key)") }
        return v
    }
}
