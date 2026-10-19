import Foundation
import NexGenEngine
import Observation

@MainActor @Observable
final class ColorReferenceComparisonStore {
    struct Source: Sendable, Equatable {
        let url: URL
        let hash: String
        nonisolated func requireCurrent() throws {
            guard try FileDigest.sha256(of: url) == hash else { throw ColorReferenceComparisonStore.changed() }
        }
    }
    struct Session: Sendable {
        let home: URL
        let key: String
        let generation: UUID
        let declaration: ProjectPackGate.MutationDeclaration
        let timeline: Timeline
        let manifest: MediaManifest
        let selection: Set<String>
        let clipID: String
        let referenceID: String
        let frame: Int
    }
    struct Snapshot: Sendable {
        let id: UUID
        let session: Session
        let sources: [Source]
        let measurements: ColorReferenceMeasurements
        let json: String
        let images: [Data]
        let referenceName: String
    }
    private struct TaskGuard {
        weak var editor: EditorViewModel?
        weak var store: ColorReferenceComparisonStore?
        let comparisonID: UUID
        let chatID: UUID
        let messageID: UUID
    }
    private static var taskGuards: [UUID: TaskGuard] = [:]
    private(set) var snapshot: Snapshot?
    private(set) var proposal: ColorReferenceProposal?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var message: String?
    private var awaitingProposal = false

    nonisolated static func changed() -> ToolError {
        ToolError("The clip, reference, playhead, or project changed. Measure a new comparison before applying a correction.")
    }

    static func refusal(tool: ToolName, editor: EditorViewModel, origin: ToolCallOrigin, turn: AgentHostTurnReference?) -> String? {
        taskGuards = taskGuards.filter { $0.value.editor != nil }
        guard let chat = origin.chatSessionID else { return nil }
        let inputID = turn?.inputMessageID ?? editor.agentService.messages.last(where: { $0.role == .user })?.id
        guard taskGuards.values.contains(where: { $0.editor === editor && $0.chatID == chat && $0.messageID == inputID }) else { return nil }
        return [.inspectColor, .proposeColorMatch].contains(tool) ? nil
            : "This native color-comparison turn can inspect_color and propose_color_match only. The user applies its staged proposal in the Inspector; direct mutation is unavailable."
    }

    static func receive(args: [String: Any], editor: EditorViewModel, origin: ToolCallOrigin) async throws -> ToolResult {
        let input = try JSONDecoder().decode(ColorReferenceProposal.self, from: JSONSerialization.data(withJSONObject: args))
        try input.validate()
        guard let turn = editor.agentService.captureHostTurnReference(origin: origin),
              let gate = taskGuards[turn.inputMessageID], gate.editor === editor,
              gate.chatID == turn.chatSessionID, gate.comparisonID == input.comparisonID,
              let store = gate.store, let expected = store.snapshot, expected.id == input.comparisonID,
              expected.session.clipID == input.clipID, expected.session.referenceID == input.referenceID,
              store.proposal == nil else { throw changed() }
        try await requireCurrent(expected, editor: editor, requireIdle: false)
        guard editor.agentService.captureHostTurnReference(origin: origin) == turn, store.snapshot?.id == expected.id, store.proposal == nil else { throw changed() }
        store.proposal = input
        store.awaitingProposal = false
        store.message = "AI proposal ready. Review its controls, then Apply or Discard."
        return .ok("Color proposal staged for native review. No clip was changed. Stop and wait for the user.")
    }

    func measure(clipID: String, referenceID: String, editor: EditorViewModel) async {
        guard !busy else { return }
        busy = true; error = nil; proposal = nil; message = nil; snapshot = nil
        defer { busy = false }
        do {
            try Self.requireIdle(editor)
            let session = try Self.capture(clipID: clipID, referenceID: referenceID, editor: editor)
            let resolver = editor.mediaResolver.snapshot()
            let sources = try await Task.detached(priority: .userInitiated) { try Self.sources(session: session, resolver: resolver) }.value
            try Self.requireSession(session, editor: editor)
            let result = await ToolExecutor(editor: editor).execute(name: "inspect_color",
                args: ["clipId": clipID, "reference": referenceID, "atFrame": session.frame])
            guard !result.isError else { throw ToolError(result.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")) }
            let texts = result.content.compactMap { if case .text(let t) = $0 { t } else { nil } }
            let images = result.content.compactMap { block -> Data? in
                if case .image(let bytes, _) = block { return Data(base64Encoded: bytes) }; return nil
            }
            guard let json = texts.last, images.count == 2 else { throw ToolError("The comparison could not decode both actual frames. Choose an available image or video reference.") }
            let values = try JSONDecoder().decode(ColorReferenceMeasurements.self, from: Data(json.utf8))
            try await Task.detached(priority: .userInitiated) { for source in sources { try source.requireCurrent() } }.value
            try Self.requireSession(session, editor: editor)
            try Self.requireIdle(editor)
            snapshot = Snapshot(id: UUID(), session: session, sources: sources, measurements: values, json: json,
                images: images, referenceName: editor.mediaResolver.displayName(for: referenceID))
        } catch { self.error = error.localizedDescription }
    }

    func requestProposal(editor: EditorViewModel) async {
        guard !busy, let expected = snapshot else { return }
        busy = true; error = nil; proposal = nil; message = nil
        defer { busy = false }
        do {
            try await Self.requireCurrent(expected, editor: editor, requireIdle: true)
            let scope = ["comparisonID": expected.id.uuidString, "clipID": expected.session.clipID, "referenceID": expected.session.referenceID]
            let scopeJSON = String(decoding: try JSONSerialization.data(withJSONObject: scope, options: [.sortedKeys]), as: UTF8.self)
            let command = "Native comparison scope: " + scopeJSON + "\nPropose a reference-based color correction for this native Inspector comparison. "
                + "Use propose_color_match with comparisonID \(expected.id.uuidString), clipID \(expected.session.clipID), referenceID \(expected.session.referenceID). "
                + "Actual clip frame \(expected.session.frame); reference is the raw source midpoint. Actual inspect_color measurements:\n\(expected.json)\n"
                + "Attached images are current graded clip, then raw reference. Explain creative interpretation separately from measured values. "
                + "Propose supported controls only; native Apply owns mutation."
            let accepted = editor.agentService.send(text: command, mentions: [], hidden: true,
                presentation: .init(choiceRecord: AgentChoiceRecord(selections: [.init(label: "Task", values: ["Compare clip color to reference"])], attachmentNames: [], confirmed: true), typedText: nil),
                runtimeImages: expected.images.map { .init(mediaType: "image/jpeg", base64: $0.base64EncodedString()) })
            guard accepted, let chat = editor.agentService.currentSessionId,
                  let input = editor.agentService.messages.last(where: { $0.role == .user }) else {
                throw ToolError("The agent could not start this color comparison. Check its connection and try again.")
            }
            awaitingProposal = true
            Self.taskGuards[input.id] = .init(editor: editor, store: self, comparisonID: expected.id, chatID: chat, messageID: input.id)
            message = "Preparing an AI proposal for this clip and reference…"
        } catch { self.error = error.localizedDescription }
    }

    func apply(editor: EditorViewModel) async {
        guard !busy, let expected = snapshot, let proposed = proposal else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await Self.requireCurrent(expected, editor: editor, requireIdle: true)
            guard snapshot?.id == expected.id, proposal == proposed else { throw Self.changed() }
            let result = await ToolExecutor(editor: editor).execute(name: "apply_color", args: proposed.applyArguments)
            guard !result.isError else { throw ToolError(result.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")) }
            proposal = nil; snapshot = nil; message = "Color correction applied. Undo restores the previous grade. Measure again to compare the result."
        } catch { self.error = error.localizedDescription }
    }

    func discard() { awaitingProposal = false; proposal = nil; snapshot = nil; message = "Color proposal discarded. Measure again for a new comparison." }

    func agentFinished(editor: EditorViewModel) {
        guard awaitingProposal, !editor.agentService.isStreaming else { return }
        awaitingProposal = false
        if proposal == nil {
            message = nil
            error = "The agent did not return a valid color proposal. Check the Agent task, then try again."
        }
    }

    static func requireCurrent(_ expected: Snapshot, editor: EditorViewModel, requireIdle: Bool) async throws {
        if requireIdle { try Self.requireIdle(editor) }
        try Self.requireSession(expected.session, editor: editor)
        let resolver = editor.mediaResolver.snapshot()
        try await Task.detached(priority: .userInitiated) {
            guard try sources(session: expected.session, resolver: resolver) == expected.sources else { throw changed() }
        }.value
        try Task.checkCancellation()
        try Self.requireSession(expected.session, editor: editor)
        if requireIdle { try Self.requireIdle(editor) }
    }

    private static func requireIdle(_ editor: EditorViewModel) throws {
        guard !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked else {
            throw ToolError("Wait for the current agent task or decision before comparing color.")
        }
        if let root = editor.workingRoot.flatMap(DataRootResolver.dataRoot),
           editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) != nil {
            throw ToolError("Wait for the current production action before comparing color.")
        }
    }

    private static func capture(clipID: String, referenceID: String, editor: EditorViewModel) throws -> Session {
        guard let home = editor.workingRoot, let key = editor.openWorkingCopyKey, let generation = editor.openWorkingCopyGeneration,
              let clip = editor.clipFor(id: clipID), [.video, .image].contains(clip.mediaType),
              let reference = editor.mediaAssets.first(where: { $0.id == referenceID }), [.video, .image].contains(reference.type),
              editor.selectedClipIds == [clipID], clip.durationFrames > 0 else { throw changed() }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: declaration.packName,
            declaredBinding: declaration.binding, declaredProductionContract: declaration.productionContract)
        let frame = min(clip.endFrame - 1, max(clip.startFrame, editor.currentFrame))
        return .init(home: home, key: key, generation: generation, declaration: declaration, timeline: editor.timeline,
            manifest: editor.mediaManifest, selection: editor.selectedClipIds, clipID: clipID, referenceID: referenceID, frame: frame)
    }

    private static func requireSession(_ expected: Session, editor: EditorViewModel) throws {
        guard editor.workingRoot == expected.home, editor.openWorkingCopyKey == expected.key,
              editor.openWorkingCopyGeneration == expected.generation, editor.timeline == expected.timeline,
              editor.mediaManifest == expected.manifest, editor.selectedClipIds == expected.selection,
              editor.clipFor(id: expected.clipID).map({ min($0.endFrame - 1, max($0.startFrame, editor.currentFrame)) }) == expected.frame,
              editor.declaredPluginName == expected.declaration.packName, editor.declaredPluginBinding == expected.declaration.binding,
              editor.declaredProductionContract == expected.declaration.productionContract else { throw changed() }
        _ = try ProjectPackGate.requireLiveMutation(projectURL: expected.home, declaredPack: expected.declaration.packName,
            declaredBinding: expected.declaration.binding, declaredProductionContract: expected.declaration.productionContract)
    }

    nonisolated private static func sources(session: Session, resolver: MediaResolver) throws -> [Source] {
        guard let clip = session.timeline.tracks.flatMap(\.clips).first(where: { $0.id == session.clipID }) else { throw changed() }
        let urls = try [clip.mediaRef, session.referenceID].map { id -> URL in
            guard let url = resolver.resolveURL(for: id) else { throw ToolError("The clip or reference is offline. Relink it and measure again.") }
            return url.standardizedFileURL.resolvingSymlinksInPath()
        }
        var subject = session.timeline; subject.tracks = [.init(type: .video, clips: [clip])]
        let resources = try ProjectEffectResources.capture(timeline: subject, resolver: resolver).map(\.url)
        return try Set(urls + resources).sorted { $0.path < $1.path }.map { .init(url: $0, hash: try FileDigest.sha256(of: $0)) }
    }
}
