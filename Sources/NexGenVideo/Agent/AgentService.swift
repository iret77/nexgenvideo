import Foundation
import NexGenEngine
import Observation

@Observable
@MainActor
final class AgentService {

    private var apiKey: String = ""
    private var apiKeyObserver: NSObjectProtocol?
    private var backendObserver: NSObjectProtocol?
    private var claudeStatusObserver: NSObjectProtocol?
    private var apiKeyGeneration = 0
    private let hostFollowUpReadinessOverride: (@MainActor () -> AgentStreamError?)?
    private let embeddedHostFollowUpSender: (@MainActor (String, [[String: Any]]) -> Bool)?

    private(set) var backend: AgentBackend
    private(set) var claudeStatus: ClaudeCodeLocator.Status?
    private(set) var isCheckingAPIKey = true
    private(set) var isCheckingClaude = false
    private var claudeStatusGeneration = 0

    init(
        backend: AgentBackend = AgentBackendPreference.selected,
        refreshBackendStatusOnInit: Bool = true,
        hostFollowUpReadinessOverride: (@MainActor () -> AgentStreamError?)? = nil,
        embeddedHostFollowUpSender: (@MainActor (String, [[String: Any]]) -> Bool)? = nil
    ) {
        self.backend = backend
        self.hostFollowUpReadinessOverride = hostFollowUpReadinessOverride
        self.embeddedHostFollowUpSender = embeddedHostFollowUpSender
        apiKeyObserver = NotificationCenter.default.addObserver(
            forName: .anthropicAPIKeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadAPIKey()
            }
        }
        backendObserver = NotificationCenter.default.addObserver(
            forName: .agentBackendChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancel()
                self.backend = AgentBackendPreference.selected
                self.claudeStatusGeneration &+= 1
                self.isCheckingClaude = false
                self.refreshBackendStatus()
            }
        }
        claudeStatusObserver = NotificationCenter.default.addObserver(
            forName: .claudeCodeStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let status = notification.object as? ClaudeCodeLocator.Status
            MainActor.assumeIsolated {
                guard let self,
                      self.backend == .claudeCode,
                      let status else { return }
                self.claudeStatusGeneration &+= 1
                self.claudeStatus = status
                self.isCheckingClaude = false
                if status.isAuthenticated, case .authenticationRequired? = self.streamError {
                    self.streamError = nil
                }
            }
        }
        if refreshBackendStatusOnInit {
            refreshBackendStatus()
        }
    }

    private func reloadAPIKey() {
        apiKeyGeneration &+= 1
        let generation = apiKeyGeneration
        isCheckingAPIKey = true
        Task { [weak self] in
            let key = await Task.detached(priority: .utility) {
                AnthropicKeychain.load() ?? ""
            }.value
            guard let self, self.apiKeyGeneration == generation else { return }
            self.apiKey = key
            self.isCheckingAPIKey = false
        }
    }

    isolated deinit {
        if let token = apiKeyObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = backendObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = claudeStatusObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    var hasApiKey: Bool { !apiKey.isEmpty }

    var isCheckingBackend: Bool {
        switch backend {
        case .anthropicAPI: return isCheckingAPIKey && !hasApiKey
        case .claudeCode: return isCheckingClaude && claudeStatus?.isAuthenticated != true
        }
    }

    var backendStatusCheckLabel: String {
        switch backend {
        case .anthropicAPI: return "Checking Anthropic API key…"
        case .claudeCode: return "Checking Claude Code…"
        }
    }

    var canStream: Bool {
        switch backend {
        case .anthropicAPI: return hasApiKey
        case .claudeCode: return claudeStatus?.isAuthenticated == true
        }
    }

    var setupPrompt: String {
        switch backend {
        case .anthropicAPI:
            return "Add an Anthropic API key in"
        case .claudeCode where isCheckingClaude:
            return "Checking Claude Code in"
        case .claudeCode where claudeStatus?.found != true:
            return "Install Claude Code in"
        case .claudeCode:
            return "Sign in to Claude Code in"
        }
    }

    var backendSetupMessage: String {
        switch backend {
        case .anthropicAPI:
            return "Add an Anthropic API key to use the AI chat."
        case .claudeCode where claudeStatus?.found != true:
            return "Install Claude Code to use the AI chat."
        case .claudeCode:
            return "Sign in to Claude Code to use the AI chat."
        }
    }

    func refreshBackendStatus() {
        switch backend {
        case .anthropicAPI:
            reloadAPIKey()
        case .claudeCode:
            isCheckingClaude = true
            Task { await refreshClaudeCodeStatus() }
        }
    }

    private func refreshClaudeCodeStatus() async {
        claudeStatusGeneration &+= 1
        let generation = claudeStatusGeneration
        isCheckingClaude = true
        let status = await Task.detached(priority: .utility) {
            ClaudeCodeLocator.status()
        }.value
        guard backend == .claudeCode, claudeStatusGeneration == generation else { return }
        claudeStatus = status
        isCheckingClaude = false
    }

    var availableModels: [AnthropicModel] { AnthropicModel.allCases }

    private func selectClient() -> (any AgentClient)? {
        guard hasApiKey else { return nil }
        return AnthropicClient(apiKey: apiKey, model: effectiveModel)
    }

    var effectiveModel: AnthropicModel {
        let available = availableModels
        if available.contains(model) { return model }
        return available.first ?? .sonnet46
    }

    var model: AnthropicModel = {
        if let raw = UserDefaults.standard.string(forKey: "agentModel"),
           let m = AnthropicModel(rawValue: raw) {
            return m
        }
        return .sonnet46
    }() {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "agentModel") }
    }

    var sessions: [ChatSession] = []
    var currentSessionId: UUID?
    var messages: [AgentMessage] = []
    var isStreaming: Bool = false {
        didSet {
            if oldValue, !isStreaming {
                // A turn finished: flush its messages into the active chat and mark the document edited
                // (`onSessionsChanged`) so ⌘S / the close-warning actually persists the transcript AND
                // the chat's claudeSessionId — the runtime backend has no post-turn sync of its own,
                // unlike kickOffStream. Then re-read the engine artifacts it may have written.
                syncMessagesIntoCurrentSession()
                onSessionsChanged?()
                Task { @MainActor [weak self] in await self?.editor?.refreshEngineState() }
            }
            if !isStreaming, !hostFollowUpStartInProgress,
               currentGateFollowUp != nil {
                Task { @MainActor [weak self] in await self?.preparePendingGateFollowUp() }
            }
            if !isStreaming, !hostFollowUpStartInProgress,
               currentSpendFollowUp != nil {
                Task { @MainActor [weak self] in self?.resumePendingSpendFollowUp() }
            }
        }
    }
    var streamError: AgentStreamError?
    var onSessionsChanged: (@MainActor () -> Void)?

    var draft: String = ""
    var mentions: [AgentMention] = []

    /// A starter or pack function staged in the composer as a colored pill: its full prompt is hidden
    /// from the text field, keeping the composer clean. On send the prompt is composed with any typed
    /// note into the outgoing message. Only one may be pending; staging another replaces it.
    var pendingFunction: PendingFunction?

    struct PendingFunction: Equatable {
        let title: String
        let systemImage: String
        let prompt: String
    }

    /// Builds the outgoing message from a staged function's full prompt and the free-typed note. A
    /// completion-style prompt (trailing space, e.g. "Generate an AI video of ") absorbs the note
    /// inline to finish the sentence; a full-instruction prompt takes the note as a trailing line.
    nonisolated static func composedFunctionMessage(prompt: String, note: String) -> String {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.hasSuffix(" ") {
            return (prompt + trimmedNote).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmedNote.isEmpty else { return prompt }
        return prompt + "\n\n" + trimmedNote
    }

    /// The one dialog currently owning the composer input surface.
    private(set) var pendingDialog: AgentDialog? {
        didSet {
            guard oldValue?.id != pendingDialog?.id else { return }
            dialogChoiceSelections = [:]
            dialogSubmissionError = nil
            submittingDialogID = nil
        }
    }

    @ObservationIgnored
    private var dialogOrigins: [String: ToolCallOrigin] = [:]

    func presentDialog(
        _ dialog: AgentDialog,
        origin: ToolCallOrigin = .direct
    ) throws {
        guard pendingDialog == nil,
              pendingSpendApproval == nil,
              pendingSpendOperation == nil,
              pendingGateApproval == nil,
              nativeGateMutationID == nil else {
            throw ToolError(
                "The composer already has a host-owned decision. Do not replace or duplicate it; stop and wait for the user."
            )
        }
        dialogOrigins[dialog.id] = origin
        suspendToolCalls(from: origin)
        pendingDialog = dialog
        editor?.agentPanelVisible = true
    }

    func abandonDialog() {
        if let dialog = pendingDialog,
           let origin = dialogOrigins.removeValue(forKey: dialog.id) {
            prepareToolCallsForFollowUp(from: origin)
        }
        pendingDialog = nil
    }

    private func abandonSessionDialog() {
        guard pendingDialog?.purpose != .workflowIntake else { return }
        abandonDialog()
    }

    @ObservationIgnored
    private var nativeGateMutationID: UUID?

    func beginNativeGateMutation() -> UUID? {
        guard nativeGateMutationID == nil, !isComposerBlocked else { return nil }
        let id = UUID()
        nativeGateMutationID = id
        return id
    }

    func endNativeGateMutation(_ id: UUID) {
        guard nativeGateMutationID == id else { return }
        nativeGateMutationID = nil
    }

    private(set) var dialogSubmissionError: String?
    private(set) var submittingDialogID: String?

    /// Choice selection for the pending dialog, shared so the compact card AND the canvas projection
    /// (A3, #124 — highlighted timeline ranges) read and write the SAME state: a click on a projected
    /// range selects its choice here, and the card's chip reflects it. Keyed by sectionId → option ids.
    var dialogChoiceSelections: [String: Set<String>] = [:]

    /// The pending dialog's canvas projection, or nil when there's nothing to project (plain card).
    var pendingDialogProjection: AgentDialog.Projection? {
        guard let p = pendingDialog?.projection, !p.isEmpty else { return nil }
        return p
    }

    /// Round-trip from the timeline: a click on a projected candidate range selects the choice whose
    /// `rangeRef` matches it (single-select — one range picked at a time). No-op if no section
    /// references this range.
    func selectDialogRange(_ rangeId: String) {
        guard let dialog = pendingDialog else { return }
        for section in dialog.sections {
            guard case .choices(let options, _) = section.kind,
                  let choice = options.first(where: { $0.rangeRef == rangeId }) else { continue }
            dialogChoiceSelections[section.id] = [choice.id]
        }
    }

    /// The range id currently selected via a projected choice, if any — the timeline draws it as the
    /// active candidate.
    var selectedDialogRangeId: String? {
        guard let dialog = pendingDialog else { return nil }
        for section in dialog.sections {
            guard case .choices(let options, _) = section.kind else { continue }
            let picked = dialogChoiceSelections[section.id] ?? []
            if let choice = options.first(where: { picked.contains($0.id) && $0.rangeRef != nil }) {
                return choice.rangeRef
            }
        }
        return nil
    }

    /// The ONE dialog-submit handler (audit #3): every presented `AgentDialog` routes here and is
    /// dispatched by its `purpose`. `.chatClarification` composes the structured chat message (the
    /// existing path); `.generationIntent` composes the result into an intent line and hands it to the
    /// generation handler (the music-shaping dialog is this purpose — its bespoke path collapses into
    /// this one). Kept on `AgentService` so no surface re-implements dialog submission.
    func submitDialog(_ dialog: AgentDialog, result: AgentDialogResult) {
        if dialog.purpose == .generationIntent {
            submitGenerationIntent(dialog, result: result)
            return
        }
        guard submittingDialogID == nil, pendingDialog?.id == dialog.id else { return }
        if dialog.purpose == .workflowIntake,
           let role = dialog.fileIntake?.attachAs,
           let conflict = intakeRoleConflict(role, urls: result.fileURLs) {
            dialogSubmissionError = "\(conflict.name) is already assigned as \(Self.intakeRoleLabel(conflict.role))."
            return
        }
        if dialog.purpose == .workflowIntake, let editor {
            do {
                try editor.pipelineAgentHarness.validateWorkflowIntake(
                    dialogID: dialog.id,
                    editor: editor
                )
            } catch {
                dialogSubmissionError = error.localizedDescription
                return
            }
        }
        submittingDialogID = dialog.id
        dialogSubmissionError = nil
        if dialog.purpose == .chatClarification {
            pendingDialog = nil
        }
        // Host workflow inputs never become individual chat turns.
        switch dialog.fileIntake?.attachAs {
        case "lyrics", "script":
            attachTextSidecar(dialog.fileIntake!.attachAs!, dialog: dialog, result: result)
            return
        case "character", "location":
            attachIdentityAssets(dialog.fileIntake!.attachAs!, dialog: dialog, result: result)
            return
        case "style":
            attachStyleRefs(dialog: dialog, result: result)
            return
        case "song":
            Task {
                await attachSongFromDialog(dialog: dialog, result: result)
            }
            return
        default:
            break
        }
        switch dialog.purpose {
        case .chatClarification:
            guard !result.fileURLs.isEmpty else {
                sendDialogResponse(dialog, result: result)
                return
            }
            Task { [weak self] in
                guard let self else { return }
                let imported = await self.importDialogFiles(result.fileURLs)
                self.sendDialogResponse(
                    dialog,
                    result: result,
                    attached: imported.mentions,
                    presentedAttachmentNames: imported.mentions.map(\.displayName),
                    userNotice: imported.failureNotice,
                    agentContext: imported.failureContext
                )
            }
        case .generationIntent:
            break
        case .workflowIntake:
            completeWorkflowIntake(
                dialog,
                result: result,
                didProvideMaterial: Self.didProvideWorkflowMaterial(result)
            )
        }
    }

    private func submitGenerationIntent(_ dialog: AgentDialog, result: AgentDialogResult) {
        guard let sink = onGenerationDialogIntent else { return }
        sink(Self.intentLine(from: dialog, result: result))
    }

    func completeDialog(_ dialog: AgentDialog) {
        guard pendingDialog?.id == dialog.id,
              submittingDialogID == nil,
              dialog.purpose == .workflowIntake,
              dialog.fileIntake?.required != true,
              dialog.fileIntake?.completionLabel != nil else { return }
        dialogSubmissionError = nil
        completeWorkflowIntake(dialog, result: nil, didProvideMaterial: false)
    }

    /// Write a copied text-sidecar intake into its deterministic project location.
    private func attachTextSidecar(_ kind: String, dialog: AgentDialog, result: AgentDialogResult) {
        // Resolve the pipeline DATA ROOT the same way the workflow tools do (workingRoot may be the
        // package home; the sidecar dirs live under <home>/pipeline). No project ⇒ don't drop the answer.
        guard let editor, let workingRoot = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: workingRoot)
        else {
            sendDialogFailure(
                dialog,
                result: result,
                notice: "Save the project before attaching \(kind)."
            )
            return
        }
        // Accept either an uploaded file or pasted text; neither means the optional step was skipped.
        let content: String
        if let src = result.fileURLs.first {
            guard let text = try? String(contentsOf: src, encoding: .utf8) else {
                sendDialogFailure(
                    dialog,
                    result: result,
                    notice: "Couldn't read \(userFacingFilename(for: src)). Use a UTF-8 .txt or .md file.",
                    agentContext: "The host couldn't read the \(kind) file because it isn't UTF-8 text. Ask for a .txt or .md file."
                )
                return
            }
            content = text
        } else {
            let pasted = result.direction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pasted.isEmpty else {
                sendDialogResponse(
                    dialog,
                    result: result,
                    agentContext: "No \(kind) was provided; the user skipped it. Proceed without \(kind)."
                )
                return
            }
            content = pasted
        }
        let relDir: String, filename: String
        switch kind {
        case "lyrics": (relDir, filename) = ("lyrics", "lyrics.txt")
        default: (relDir, filename) = ("import", "script.md")  // "script"
        }
        let dir = dataRoot.appendingPathComponent(relDir, isDirectory: true)
        do {
            if let key = editor.openWorkingCopyKey {
                try ProjectWorkingCopy.markDirty(key: key)
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: dir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        } catch {
            sendDialogFailure(
                dialog,
                result: result,
                notice: "Couldn't attach \(kind): \(error.localizedDescription)",
                agentContext: "The host couldn't attach the \(kind): \(error.localizedDescription)."
            )
            return
        }
        assignIntakeRole(kind, urls: result.fileURLs)
        editor.onPipelineChanged?()
        sendDialogResponse(
            dialog,
            result: result,
            presentedAttachmentNames: result.fileURLs.map { userFacingFilename(for: $0) }
        )
    }

    /// Copy prepared character/location reference images into the bible-anchor convention
    /// `import/<characters|locations>/<slug>/` (copy, never move), keyed by the identity name the user
    /// typed. This is the brownfield path: the bible-agent (K5) adopts these as identity anchors, so the
    /// pipeline stays consistent with the user's prepared assets instead of inventing new ones.
    private func attachIdentityAssets(_ kind: String, dialog: AgentDialog, result: AgentDialogResult) {
        guard !result.fileURLs.isEmpty else {
            sendDialogFailure(
                dialog,
                result: result,
                notice: "Choose at least one reference image."
            )
            return
        }
        guard let editor, let workingRoot = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: workingRoot) else {
            sendDialogFailure(
                dialog,
                result: result,
                notice: "Save the project before attaching \(kind) references."
            )
            return
        }
        let name = result.direction.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Self.identitySlug(name)
        guard !slug.isEmpty else {
            sendDialogFailure(
                dialog,
                result: result,
                notice: "Enter a usable \(kind) name before attaching references.",
                agentContext: "The host couldn't attach the \(kind) because no usable name was given. Ask for its name, then re-present the dialog."
            )
            return
        }
        let category = kind == "location" ? "locations" : "characters"
        let dir = dataRoot.appendingPathComponent("import").appendingPathComponent(category).appendingPathComponent(slug)
        do {
            if let key = editor.openWorkingCopyKey {
                try ProjectWorkingCopy.markDirty(key: key)
            }
        } catch {
            sendDialogFailure(
                dialog,
                result: result,
                notice: "Couldn't attach \(kind) references: \(error.localizedDescription)",
                agentContext: "The host couldn't attach the \(kind) \"\(name)\": \(error.localizedDescription)."
            )
            return
        }
        let urls = result.fileURLs
        let preferred = preferredFilenames(for: urls)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let copied = try await Task.detached(priority: .userInitiated) {
                    try Self.copyFilesUniquely(
                        urls,
                        into: dir,
                        preferredFilenames: preferred
                    )
                }.value
                self.assignIntakeRole(kind, urls: urls)
                editor.onPipelineChanged?()
                let noun = kind == "location" ? "Location" : "Character"
                self.sendDialogResponse(
                    dialog,
                    result: result,
                    presentedAttachmentNames: urls.map { self.userFacingFilename(for: $0) },
                    agentContext: "\(noun) \"\(name)\" attached: \(copied.count) reference image\(copied.count == 1 ? "" : "s") "
                        + "in import/\(category)/\(slug)/. This is a BROWNFIELD anchor — the bible-agent adopts it; "
                        + "keep this identity consistent across the pipeline and don't invent a different one."
                )
            } catch {
                self.sendDialogFailure(
                    dialog,
                    result: result,
                    notice: "Couldn't attach \(kind) references: \(error.localizedDescription)",
                    agentContext: "The host couldn't attach the \(kind) \"\(name)\": \(error.localizedDescription)."
                )
            }
        }
    }

    /// A filesystem-safe slug for an identity folder name: lowercased, non-alphanumerics collapsed to
    /// single hyphens, trimmed. "Claude Mouse" -> "claude-mouse".
    nonisolated static func identitySlug(_ name: String) -> String {
        var out = ""
        var lastDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func attachSongFromDialog(
        dialog: AgentDialog,
        result: AgentDialogResult
    ) async {
        guard let src = result.fileURLs.first else {
            sendDialogFailure(
                dialog,
                result: result,
                notice: "Choose a track before continuing."
            )
            return
        }
        guard let editor, let workingRoot = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: workingRoot) else {
            sendDialogFailure(
                dialog,
                result: result,
                notice: "Save the project before attaching a song."
            )
            return
        }
        guard AudioProjectLayout.audioExtensions.contains(src.pathExtension.lowercased()) else {
            sendDialogFailure(
                dialog,
                result: result,
                notice: "Choose a .wav, .mp3, .m4a, .aiff, .flac, or .aac audio file.",
                agentContext: "The selected song isn't a supported audio file; use .wav, .mp3, .m4a, .aiff, .flac, or .aac."
            )
            return
        }
        do {
            let filename = userFacingFilename(for: src)
            let attached = try await editor.attachProjectSong(
                from: src,
                dataRoot: dataRoot,
                replace: true,
                originalFilename: filename
            )
            let routing: String
            if let next = editor.projectState?.nextPhaseName, next != "analysis" {
                routing = "The pipeline is still on \"\(next)\" — settle that and get it approved first; "
                    + "analysis is gated behind it."
            } else {
                routing = "Run run_phase(\"analysis\") to measure it."
            }
            sendDialogResponse(
                dialog,
                result: result,
                presentedAttachmentNames: [attached.filename],
                agentContext: "Song placed in audio/ (\(attached.filename)). \(routing)"
            )
        } catch {
            sendDialogFailure(
                dialog,
                result: result,
                notice: "Couldn't attach the song: \(error.localizedDescription)",
                agentContext: "The host couldn't place the song in audio/: \(error.localizedDescription)."
            )
        }
    }

    /// Copy loose style-reference images into the project's `import/` — a brownfield look source the
    /// production-design agent (K2) curates. No name: these are unstructured mood/style refs.
    private func attachStyleRefs(dialog: AgentDialog, result: AgentDialogResult) {
        guard !result.fileURLs.isEmpty else {
            sendDialogResponse(
                dialog,
                result: result,
                agentContext: "No style references were provided; the user skipped them. Production design can develop the look from the brief."
            )
            return
        }
        guard let editor, let workingRoot = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: workingRoot)
        else {
            sendDialogFailure(
                dialog,
                result: result,
                notice: "Save the project before attaching style references."
            )
            return
        }
        let dir = dataRoot.appendingPathComponent("import", isDirectory: true)
        do {
            if let key = editor.openWorkingCopyKey {
                try ProjectWorkingCopy.markDirty(key: key)
            }
        } catch {
            sendDialogFailure(
                dialog,
                result: result,
                notice: "Couldn't attach style references: \(error.localizedDescription)",
                agentContext: "The host couldn't attach the style references: \(error.localizedDescription)."
            )
            return
        }
        let urls = result.fileURLs
        let preferred = preferredFilenames(for: urls)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let copied = try await Task.detached(priority: .userInitiated) {
                    try Self.copyFilesUniquely(
                        urls,
                        into: dir,
                        preferredFilenames: preferred
                    )
                }.value
                self.assignIntakeRole("style", urls: urls)
                editor.onPipelineChanged?()
                self.sendDialogResponse(
                    dialog,
                    result: result,
                    presentedAttachmentNames: urls.map { self.userFacingFilename(for: $0) },
                    agentContext: "\(copied.count) style reference\(copied.count == 1 ? "" : "s") attached in import/. "
                        + "The production-design agent (K2) curates these as the style source."
                )
            } catch {
                self.sendDialogFailure(
                    dialog,
                    result: result,
                    notice: "Couldn't attach style references: \(error.localizedDescription)",
                    agentContext: "The host couldn't attach the style references: \(error.localizedDescription)."
                )
            }
        }
    }

    private func intakeRoleConflict(
        _ requestedRole: String,
        urls: [URL]
    ) -> (name: String, role: String)? {
        guard let editor, !urls.isEmpty else { return nil }
        let selected = Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        for asset in editor.mediaAssets where selected.contains(
            asset.url.standardizedFileURL.resolvingSymlinksInPath()
        ) {
            guard let assigned = editor.mediaManifest.intakeRoleByAssetID[asset.id],
                  assigned != requestedRole else { continue }
            return (asset.name, assigned)
        }
        return nil
    }

    private func assignIntakeRole(_ role: String, urls: [URL]) {
        guard let editor, !urls.isEmpty else { return }
        let selected = Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        for asset in editor.mediaAssets where selected.contains(
            asset.url.standardizedFileURL.resolvingSymlinksInPath()
        ) {
            editor.mediaManifest.intakeRoleByAssetID[asset.id] = role
        }
    }

    private func userFacingFilename(for url: URL) -> String {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        return editor?.mediaAssets.first {
            $0.url.standardizedFileURL.resolvingSymlinksInPath() == target
        }?.userFacingFilename ?? MediaFilename.display(
            originalFilename: nil,
            name: "",
            storageURL: url
        )
    }

    private func preferredFilenames(for urls: [URL]) -> [URL: String] {
        Dictionary(urls.map { ($0, userFacingFilename(for: $0)) }) { first, _ in first }
    }

    nonisolated private static func intakeRoleLabel(_ role: String) -> String {
        switch role {
        case "song": "the project track"
        case "lyrics": "lyrics"
        case "script": "existing story"
        case "character": "a character reference"
        case "location": "a location reference"
        case "style": "a style reference"
        default: role
        }
    }

    /// Copy files into `dir` (copy, never move), choosing a free name for each so nothing is ever
    /// overwritten — collisions with files ALREADY in `dir` (e.g. a reference from an earlier session)
    /// and within this batch both get a `-2`/`-3` suffix. A file already sitting at its destination is
    /// kept as-is. Returns the destination names. One routine for every image intake.
    nonisolated static func copyFilesUniquely(
        _ urls: [URL],
        into dir: URL,
        preferredFilenames: [URL: String] = [:]
    ) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var used = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        var copied: [String] = []
        var created: [URL] = []
        do {
            for src in urls {
                let preferred = MediaFilename.storageFilename(
                    preferredFilenames[src] ?? src.lastPathComponent,
                    matchingExtension: src.pathExtension
                ) ?? src.lastPathComponent
                let inPlace = dir.appendingPathComponent(preferred)
                if src.standardizedFileURL == inPlace.standardizedFileURL {
                    used.insert(preferred)
                    copied.append(preferred)
                    continue
                }
                let ext = src.pathExtension
                let base = URL(fileURLWithPath: preferred)
                    .deletingPathExtension().lastPathComponent
                var name = preferred
                var n = 2
                while used.contains(name) {
                    name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
                    n += 1
                }
                let destination = dir.appendingPathComponent(name)
                try fm.copyItem(at: src, to: destination)
                used.insert(name)
                copied.append(name)
                created.append(destination)
            }
        } catch {
            for url in created.reversed() { try? fm.removeItem(at: url) }
            throw error
        }
        return copied
    }

    /// Extract `[Section]` markers (one per line, e.g. `[Chorus]`) from lyrics text, in order.
    nonisolated static func lyricsSectionMarkers(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count > 2, t.hasPrefix("["), t.hasSuffix("]") else { return nil }
            let inner = t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            return inner.isEmpty ? nil : inner
        }
    }

    /// Captures durable dialog-file imports and their visible failures.
    private struct DialogFileImport {
        var mentions: [AgentMention] = []
        var failures: [String] = []

        var failureContext: String? {
            guard !failures.isEmpty else { return nil }
            return "The host couldn't import: \(failures.joined(separator: "; ")). These files were not attached."
        }

        var failureNotice: String? {
            guard !failures.isEmpty else { return nil }
            return failures.joined(separator: "\n")
        }
    }

    private func importDialogFiles(_ urls: [URL]) async -> DialogFileImport {
        guard let editor, !urls.isEmpty else { return DialogFileImport() }
        var imported = DialogFileImport()
        var mentions: [AgentMention] = []
        var assets: [MediaAsset] = []
        var pendingURLs: [URL] = []
        for url in urls {
            let target = url.standardizedFileURL.resolvingSymlinksInPath()
            if let existing = editor.mediaAssets.first(where: {
                $0.url.standardizedFileURL.resolvingSymlinksInPath() == target
            }) {
                assets.append(existing)
            } else {
                pendingURLs.append(url)
            }
        }
        if !pendingURLs.isEmpty {
            let summary = await editor.importFinderItems(pendingURLs, into: nil)
            for assetID in summary.assetIDs {
                if let asset = editor.mediaAssets.first(where: { $0.id == assetID }) {
                    assets.append(asset)
                }
            }
            if let failure = summary.failure {
                imported.failures.append(failure)
            } else if summary.assetIDs.count != pendingURLs.count {
                imported.failures.append("One or more files couldn't be copied into the project.")
            }
        }
        for asset in assets {
            let displayName = Self.disambiguatedMentionName(for: asset, existing: mentions)
            mentions.append(AgentMention(displayName: displayName, mediaRef: asset.id, type: asset.type))
        }
        imported.mentions = mentions
        return imported
    }

    /// Surface-owned generation sink; stale deliveries are discarded instead of entering agent chat.
    var onGenerationDialogIntent: (@MainActor (String) -> Void)?

    struct DialogResponse: Equatable {
        let agentText: String
        let presentation: AgentUserPresentation
    }

    /// Builds separate model semantics and user-facing dialog presentation.
    static func dialogResponse(
        from dialog: AgentDialog,
        result: AgentDialogResult,
        attached: [AgentMention] = [],
        presentedAttachmentNames: [String]? = nil,
        userNotice: String? = nil
    ) -> DialogResponse {
        var selections: [AgentChoiceRecord.Selection] = []
        var agentLines = ["The user submitted the \(dialog.title) dialog."]
        for section in dialog.sections {
            var semanticValues = result.labels(section.id)
            var presentedValues = semanticValues.map { section.transcriptValue(for: $0) }
            if let custom = result.customValues[section.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !custom.isEmpty {
                semanticValues.append(custom)
                presentedValues.append(custom)
            }
            if case .toggle = section.kind {
                semanticValues = [(result.toggles[section.id] ?? false) ? "Yes" : "No"]
                presentedValues = semanticValues
            }
            if !semanticValues.isEmpty {
                selections.append(.init(label: section.shortLabel, values: presentedValues))
                agentLines.append("\(section.label): \(semanticValues.joined(separator: ", "))")
            }
        }
        let direction = result.direction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direction.isEmpty { agentLines.append("Direction: \(direction)") }
        let attachmentNames = presentedAttachmentNames ?? (attached.isEmpty
            ? result.fileURLs.map {
                MediaFilename.display(
                    originalFilename: nil,
                    name: "",
                    storageURL: $0
                )
            }
            : attached.map(\.displayName))
        if !attachmentNames.isEmpty {
            let values = attached.isEmpty
                ? attachmentNames.joined(separator: ", ")
                : attached.map { "@\($0.displayName)" }.joined(separator: " ")
            agentLines.append("Attached \(attachmentNames.count == 1 ? "file" : "files"): \(values)")
        }
        let confirmed = selections.isEmpty && attachmentNames.isEmpty && result.fileURLs.isEmpty
        let needsRecord = !selections.isEmpty || !attachmentNames.isEmpty || (direction.isEmpty && confirmed)
        let record = needsRecord ? AgentChoiceRecord(
            selections: selections,
            attachmentNames: attachmentNames,
            confirmed: confirmed
        ) : nil
        return DialogResponse(
            agentText: agentLines.joined(separator: "\n"),
            presentation: AgentUserPresentation(
                choiceRecord: record,
                typedText: direction.isEmpty ? nil : direction,
                notice: userNotice
            )
        )
    }

    private func sendDialogResponse(
        _ dialog: AgentDialog,
        result: AgentDialogResult,
        attached: [AgentMention] = [],
        presentedAttachmentNames: [String]? = nil,
        userNotice: String? = nil,
        agentContext: String? = nil
    ) {
        var resolvedAttachmentNames = presentedAttachmentNames
        if resolvedAttachmentNames == nil, attached.isEmpty {
            resolvedAttachmentNames = result.fileURLs.map { userFacingFilename(for: $0) }
        }
        if dialog.purpose == .workflowIntake {
            completeWorkflowIntake(
                dialog,
                result: result,
                presentedAttachmentNames: resolvedAttachmentNames ?? [],
                didProvideMaterial: Self.didProvideWorkflowMaterial(result)
            )
            return
        }
        let response = Self.dialogResponse(
            from: dialog,
            result: result,
            attached: attached,
            presentedAttachmentNames: resolvedAttachmentNames,
            userNotice: userNotice
        )
        let text = [response.agentText, agentContext].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: "\n\nHost result: ")
        let origin = dialogOrigins.removeValue(forKey: dialog.id) ?? .direct
        sendDialogTurn(
            text: text,
            mentions: attached,
            presentation: response.presentation,
            origin: origin
        )
    }

    private func sendDialogTurn(
        text: String,
        mentions: [AgentMention],
        hidden: Bool = false,
        presentation: AgentUserPresentation? = nil,
        origin: ToolCallOrigin
    ) {
        switch origin {
        case .externalMCP:
            return
        case .inAppChat(let sessionID),
             .embeddedRuntime(let sessionID, _):
            guard sessions.contains(where: { $0.id == sessionID }) else { return }
            if currentSessionId != sessionID {
                selectSession(sessionID)
            }
            prepareToolCallsForFollowUp(from: origin)
        case .direct:
            break
        }
        send(
            text: text,
            mentions: mentions,
            hidden: hidden,
            presentation: presentation
        )
    }

    private func sendDialogFailure(
        _ dialog: AgentDialog,
        result: AgentDialogResult,
        notice: String,
        agentContext: String? = nil
    ) {
        if dialog.purpose == .workflowIntake {
            submittingDialogID = nil
            dialogSubmissionError = notice
            return
        }
        sendDialogResponse(
            dialog,
            result: result,
            presentedAttachmentNames: [],
            userNotice: notice,
            agentContext: agentContext ?? "The host couldn't complete the requested file attachment."
        )
    }

    nonisolated private static func didProvideWorkflowMaterial(
        _ result: AgentDialogResult
    ) -> Bool {
        !result.fileURLs.isEmpty
            || !result.direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func completeWorkflowIntake(
        _ dialog: AgentDialog,
        result: AgentDialogResult?,
        presentedAttachmentNames: [String] = [],
        didProvideMaterial: Bool
    ) {
        guard pendingDialog?.id == dialog.id else { return }
        submittingDialogID = nil
        pendingDialog = nil
        guard let editor else {
            pendingDialog = dialog
            dialogSubmissionError = "The project is unavailable. Reopen it and try again."
            return
        }
        let phase = editor.pipelineAgentHarness.workflowIntakePhase(
            dialogID: dialog.id
        )
        let reconciliation = editor.pipelineAgentHarness.resolveWorkflowIntake(
            dialogID: dialog.id,
            didProvideMaterial: didProvideMaterial,
            editor: editor
        )
        if let failure = reconciliation.failure {
            pendingDialog = dialog
            dialogSubmissionError = failure
            return
        }
        appendWorkflowRecord(
            dialog: dialog,
            result: result,
            attachmentNames: presentedAttachmentNames,
            phase: phase,
            didProvideMaterial: didProvideMaterial
        )
        if let origin = dialogOrigins.removeValue(forKey: dialog.id) {
            prepareToolCallsForFollowUp(from: origin)
        }
        Task { @MainActor [weak self] in
            await self?.editor?.refreshEngineState()
        }
    }

    private func appendWorkflowRecord(
        dialog: AgentDialog,
        result: AgentDialogResult?,
        attachmentNames: [String],
        phase: String?,
        didProvideMaterial: Bool
    ) {
        let direction = result?.direction.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail: String?
        if dialog.fileIntake?.namePrompt != nil, !direction.isEmpty {
            detail = direction
        } else if didProvideMaterial, attachmentNames.isEmpty {
            detail = "Text provided"
        } else {
            detail = nil
        }
        let outcome: AgentWorkflowRecord.Outcome
        if didProvideMaterial {
            outcome = attachmentNames.isEmpty ? .provided : .attached
        } else if dialog.fileIntake?.completionLabel?.lowercased() == "done" {
            outcome = .completed
        } else {
            outcome = .skipped
        }
        let message = AgentMessage(
            role: .user,
            blocks: [],
            userPresentation: AgentUserPresentation(
                choiceRecord: nil,
                typedText: nil,
                workflowRecord: AgentWorkflowRecord(
                    title: dialog.title,
                    symbol: dialog.symbol,
                    phase: phase,
                    detail: detail,
                    attachmentNames: attachmentNames,
                    outcome: outcome
                )
            )
        )
        if claudeRuntimeEnabled, let runtime = _claudeRuntime {
            runtime.appendTranscriptOnly(message)
            messages = runtime.messages
        } else {
            messages.append(message)
        }
        checkpointCurrentSession()
    }

    /// The compact intent line for a generation dialog — picked chip labels then the free-text
    /// direction, comma-joined (matches the music tab's original composition).
    private static func intentLine(from dialog: AgentDialog, result: AgentDialogResult) -> String {
        var parts = result.allLabels + result.customValues.values.sorted()
        if !result.direction.isEmpty { parts.append(result.direction) }
        return parts.joined(separator: ", ")
    }

    /// Dismissing a dialog must not leave the agent waiting forever (it STOP-and-waits after show_dialog).
    /// A dismissed chat-clarification dialog tells the agent it was skipped so it can move on.
    func cancelDialog() {
        let dialog = pendingDialog
        if let dialog, dialog.purpose == .workflowIntake {
            guard dialog.fileIntake?.required != true, submittingDialogID == nil else { return }
            completeWorkflowIntake(dialog, result: nil, didProvideMaterial: false)
            return
        }
        let origin = dialog.flatMap { dialogOrigins.removeValue(forKey: $0.id) } ?? .direct
        pendingDialog = nil
        if let dialog, dialog.purpose == .chatClarification {
            sendDialogTurn(
                text: "The user dismissed the \u{201C}\(dialog.title)\u{201D} dialog without answering. Ask in prose or move on.",
                mentions: [],
                hidden: true,
                origin: origin
            )
        }
    }

    /// A card owns the composer dock — a pending dialog, a spend approval, or a gate approval — so the
    /// input can't send. UI reads this to disable Send AND to hide the selection scope chip, which acts
    /// only on a targeted instruction the user can't dispatch until the card is answered.
    var isComposerBlocked: Bool {
        pendingDialog != nil
            || pendingSpendApproval != nil
            || currentSpendFollowUp != nil
            || pendingGateApproval != nil
            || currentGateFollowUp != nil
    }

    // MARK: - Spend approval (Cost-Guard, M7)

    /// The ONE pending spend confirmation (locked provider architecture — user has the final word on
    /// paid agent renders). Set while an agent render waits for approval; the composer dock renders a
    /// `SpendApprovalCard` above the input, exactly where the generative dialog lives (never a modal).
    private(set) var pendingSpendApproval: SpendApproval?
    private(set) var spendApprovalError: String?
    private(set) var runningSpendStatus: SpendRunStatus?

    var spendApprovalIsRunning: Bool { runningSpendStatus != nil }

    var currentSpendRun: SpendRunStatus? {
        guard let status = runningSpendStatus,
              status.chatSessionID == nil || status.chatSessionID == currentSessionId else {
            return nil
        }
        return status
    }

    @ObservationIgnored
    private var pendingSpendOperation: PendingSpendOperation?

    @ObservationIgnored
    private var spendApprovalRefresh: (@MainActor () -> SpendApproval)?

    @ObservationIgnored
    private var pendingSpendFollowUps: [SpendFollowUp] = []

    @ObservationIgnored
    private var runningSpendTask: Task<Void, Never>?

    @ObservationIgnored
    private var runningSpendCancel: (@MainActor () -> Void)?

    @ObservationIgnored
    private var hostFollowUpStartInProgress = false

    private struct PendingSpendOperation {
        let origin: ToolCallOrigin
        let execute: @MainActor (SpendOption) async throws -> ToolResult
        let cancel: @MainActor () -> Void
    }

    struct SpendRunStatus: Equatable, Sendable {
        let id: String
        let chatSessionID: UUID?
        let actionLabel: String
        let modelName: String
        let providerName: String
        var cancellationRequested: Bool
    }

    private struct SpendFollowUp {
        let origin: ToolCallOrigin
        let text: String
        let imageBlocks: [[String: Any]]
    }

    private var currentSpendFollowUp: SpendFollowUp? {
        guard let currentSessionId else { return nil }
        return pendingSpendFollowUps.first {
            $0.origin.chatSessionID == currentSessionId
        }
    }

    private static let spendSuspensionText =
        "The spend approval card is open. End this turn and wait for the host result; do not retry this tool call."

    /// Register the exact operation behind the approval and end the current agent turn immediately.
    /// Human wait time never holds an MCP request open: the card starts the stored operation in a
    /// fresh host task, then reports its result to the originating chat as a semantic follow-up.
    func requestSpendApproval(
        _ approval: SpendApproval,
        origin: ToolCallOrigin,
        editor: EditorViewModel,
        refresh: (@MainActor () -> SpendApproval)? = nil,
        cancel: @escaping @MainActor (EditorViewModel) -> Void = { _ in },
        execute: @escaping @MainActor (EditorViewModel, SpendOption) async throws -> ToolResult
    ) throws -> ToolResult {
        if case .externalMCP = origin {
            throw ToolError(
                "External MCP sessions cannot own an in-app spend approval. Start the request from an in-app chat."
            )
        }
        guard pendingDialog == nil else {
            throw ToolError("A host-owned dialog is already waiting for the user.")
        }
        guard nativeGateMutationID == nil else {
            throw ToolError("A native pipeline gate change is already being applied.")
        }
        guard pendingGateApproval == nil else {
            throw ToolError("A gate approval is already waiting for the user.")
        }
        guard pendingSpendOperation == nil, pendingSpendApproval == nil else {
            throw ToolError("A spend approval is already waiting for the user.")
        }
        guard runningSpendTask == nil else {
            throw ToolError(
                "An approved generation is already running. Wait for it to finish or cancel it before starting another paid request."
            )
        }
        editor.agentPanelVisible = true
        spendApprovalError = nil
        spendApprovalRefresh = refresh
        pendingSpendOperation = PendingSpendOperation(
            origin: origin,
            execute: { [weak editor] option in
                guard let editor else {
                    throw ToolError("The project closed before the approved operation could start.")
                }
                return try await execute(editor, option)
            },
            cancel: { [weak editor] in
                guard let editor else { return }
                cancel(editor)
            }
        )
        suspendToolCalls(from: origin)
        pendingSpendApproval = approval
        return .suspended(Self.spendSuspensionText)
    }

    func refreshSpendApproval() {
        guard let current = pendingSpendApproval,
              let refresh = spendApprovalRefresh else { return }
        let updated = refresh()
        guard updated.id == current.id else { return }
        pendingSpendApproval = updated
    }

    func approveSpend(_ option: SpendOption) async {
        guard runningSpendTask == nil else { return }
        guard let approval = pendingSpendApproval,
              approval.options.contains(option) else {
            spendApprovalError = "This provider and model are no longer part of the pending approval."
            return
        }
        guard option.isCurrentlyAvailable else {
            spendApprovalError = "This provider or model is no longer available. Choose another valid option."
            return
        }
        guard let operation = pendingSpendOperation else {
            spendApprovalError = "The approved operation is no longer available. Decline it and try again."
            return
        }
        pendingSpendApproval = nil
        spendApprovalRefresh = nil
        pendingSpendOperation = nil
        spendApprovalError = nil
        runningSpendStatus = SpendRunStatus(
            id: approval.id,
            chatSessionID: operation.origin.chatSessionID,
            actionLabel: approval.actionLabel,
            modelName: option.modelName,
            providerName: option.providerLabel,
            cancellationRequested: false
        )
        runningSpendCancel = operation.cancel
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executeApprovedSpend(
                approvalID: approval.id,
                option: option,
                operation: operation
            )
        }
        runningSpendTask = task
    }

    private func executeApprovedSpend(
        approvalID: String,
        option: SpendOption,
        operation: PendingSpendOperation
    ) async {
        guard runningSpendStatus?.id == approvalID else { return }
        if runningSpendStatus?.cancellationRequested == true || Task.isCancelled {
            let cancelled = ToolResult.error("Generation cancelled.")
            settleRunningSpend(
                approvalID: approvalID,
                "Generation cancelled.",
                origin: operation.origin,
                result: cancelled
            )
            return
        }
        do {
            let result = try await operation.execute(option)
            guard runningSpendStatus?.id == approvalID else { return }
            let message = result.content.compactMap { block -> String? in
                guard case .text(let text) = block else { return nil }
                return text
            }.joined(separator: "\n")
            settleRunningSpend(
                approvalID: approvalID,
                result.isError
                    ? "The approved operation failed: \(message)"
                    : message,
                origin: operation.origin,
                result: result
            )
        } catch {
            guard runningSpendStatus?.id == approvalID else { return }
            let wasCancelled = runningSpendStatus?.cancellationRequested == true
                || Task.isCancelled
                || error is CancellationError
            let message: String
            if wasCancelled, error is CancellationError {
                message = "Generation cancelled."
            } else if wasCancelled {
                message = error.localizedDescription
            } else {
                message = "The approved operation failed: \(error.localizedDescription)"
            }
            let result = ToolResult.error(message)
            invokeRunningSpendCancellation()
            settleRunningSpend(
                approvalID: approvalID,
                message,
                origin: operation.origin,
                result: result
            )
        }
    }

    private func settleRunningSpend(
        approvalID: String,
        _ text: String,
        origin: ToolCallOrigin,
        result: ToolResult
    ) {
        guard runningSpendStatus?.id == approvalID else { return }
        runningSpendStatus = nil
        runningSpendTask = nil
        runningSpendCancel = nil
        replacePendingSpendToolResult(result, origin: origin)
        enqueueSpendFollowUp(text, origin: origin, result: result)
    }

    func cancelRunningSpend() {
        guard var status = currentSpendRun,
              !status.cancellationRequested else { return }
        status.cancellationRequested = true
        runningSpendStatus = status
        invokeRunningSpendCancellation()
        runningSpendTask?.cancel()
    }

    private func invokeRunningSpendCancellation() {
        let cancel = runningSpendCancel
        runningSpendCancel = nil
        cancel?()
    }

    func declineSpend(reason: String = "The user declined the spend request.") {
        guard let operation = pendingSpendOperation else {
            clearSpendApproval(cancelling: true)
            return
        }
        let result = ToolResult.error(reason)
        replacePendingSpendToolResult(result, origin: operation.origin)
        clearSpendApproval(cancelling: true)
        enqueueSpendFollowUp(reason, origin: operation.origin, result: result)
    }

    private func clearSpendApproval(cancelling: Bool) {
        let operation = pendingSpendOperation
        pendingSpendApproval = nil
        spendApprovalRefresh = nil
        pendingSpendOperation = nil
        spendApprovalError = nil
        if cancelling { operation?.cancel() }
    }

    private func abandonSpendApproval() {
        let operation = pendingSpendOperation
        let abandonedApproval = pendingSpendApproval != nil || operation != nil
        if let operation {
            replacePendingSpendToolResult(
                .error("Generation approval was cancelled before it ran."),
                origin: operation.origin
            )
        }
        clearSpendApproval(cancelling: true)
        if abandonedApproval {
            if let operation { resumeToolCalls(from: operation.origin) }
        }
    }

    private func abandonRunningSpend() {
        invokeRunningSpendCancellation()
        runningSpendTask?.cancel()
        runningSpendStatus = nil
        runningSpendTask = nil
    }

    private func enqueueSpendFollowUp(
        _ text: String,
        origin: ToolCallOrigin,
        result: ToolResult? = nil
    ) {
        guard origin.chatSessionID != nil else { return }
        let imageBlocks: [[String: Any]] = result?.content.compactMap { block in
            guard case .image(let base64, let mediaType) = block else { return nil }
            return [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": base64,
                ],
            ]
        } ?? []
        pendingSpendFollowUps.append(SpendFollowUp(
            origin: origin,
            text: text,
            imageBlocks: imageBlocks
        ))
        Task { @MainActor [weak self] in self?.resumePendingSpendFollowUp() }
    }

    private func replacePendingSpendToolResult(
        _ result: ToolResult,
        origin: ToolCallOrigin
    ) {
        guard let sessionID = origin.chatSessionID else { return }
        if sessionID == currentSessionId {
            guard Self.replacePendingSpendToolResult(result, in: &messages) else { return }
            syncMessagesIntoCurrentSession()
            onSessionsChanged?()
            return
        }
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              Self.replacePendingSpendToolResult(
                  result,
                  in: &sessions[sessionIndex].messages
              ) else { return }
        sessions[sessionIndex].updatedAt = Date()
        onSessionsChanged?()
    }

    private static func replacePendingSpendToolResult(
        _ result: ToolResult,
        in messages: inout [AgentMessage]
    ) -> Bool {
        for messageIndex in messages.indices.reversed() {
            for blockIndex in messages[messageIndex].blocks.indices.reversed() {
                guard case .toolResult(let toolUseId, let content, _) =
                    messages[messageIndex].blocks[blockIndex],
                    content.contains(where: {
                        guard case .text(let text) = $0 else { return false }
                        return text == Self.spendSuspensionText
                    })
                else { continue }
                messages[messageIndex].blocks[blockIndex] = .toolResult(
                    toolUseId: toolUseId,
                    content: result.content,
                    isError: result.isError
                )
                return true
            }
        }
        return false
    }

    @discardableResult
    func resumePendingSpendFollowUp() -> Bool {
        guard !isStreaming, !hostFollowUpStartInProgress,
              let followUpIndex = pendingSpendFollowUps.firstIndex(where: {
                  $0.origin.chatSessionID == currentSessionId
              }) else { return false }
        let followUp = pendingSpendFollowUps[followUpIndex]
        guard pendingDialog == nil,
              pendingSpendApproval == nil,
              pendingGateApproval == nil else { return false }
        if let sessionID = followUp.origin.chatSessionID {
            guard sessions.contains(where: { $0.id == sessionID }) else {
                pendingSpendFollowUps.remove(at: followUpIndex)
                resumeToolCalls(from: followUp.origin)
                return false
            }
            guard currentSessionId == sessionID else { return false }
        }
        guard prepareHostFollowUp() else { return false }
        hostFollowUpStartInProgress = true
        defer { hostFollowUpStartInProgress = false }
        prepareToolCallsForFollowUp(from: followUp.origin)
        let followUpText = "Host generation result: \(followUp.text) Continue from this result; do not request the same spend approval again."
        let started: Bool
        if claudeRuntimeEnabled {
            streamError = nil
            started = embeddedHostFollowUpSender?(
                followUpText,
                followUp.imageBlocks
            ) ?? claudeRuntime.send(
                    text: followUpText,
                    imageBlocks: followUp.imageBlocks,
                    hidden: true
                )
            checkpointCurrentSession()
        } else {
            started = send(
                text: followUpText,
                mentions: [],
                hidden: true,
                allowWhileBlocked: true
            )
        }
        if started {
            pendingSpendFollowUps.remove(at: followUpIndex)
        } else if streamError == nil {
            streamError = .upstream(
                "Couldn't resume the agent after generation. Retry the host follow-up."
            )
        }
        return started
    }

    private func prepareHostFollowUp() -> Bool {
        guard canStream else {
            streamError = backend == .claudeCode
                ? .authenticationRequired
                : .upstream("Add an Anthropic API key in Settings to continue the agent.")
            return false
        }
        if let error = hostFollowUpReadinessOverride?() {
            streamError = error
            return false
        }
        return prepareWorkingCopyForTurn()
    }

    // MARK: - Gate approval (HAX G11 — a phase gate is the user's decision)

    /// The one gate decision currently waiting in the composer.
    private(set) var pendingGateApproval: GateApproval?
    private(set) var gateApprovalIsWriting = false
    private(set) var gateApprovalError: String?

    @ObservationIgnored
    private var pendingGateFollowUp: GateFollowUp?

    @ObservationIgnored
    private var pendingGateOrigin: ToolCallOrigin?

    @ObservationIgnored
    private var suspendedToolOrigins: Set<ToolCallOrigin.SuspensionKey> = []

    private struct GateFollowUp {
        let origin: ToolCallOrigin
        let text: String
        let includeNextPhaseInstructions: Bool
    }

    private var currentGateFollowUp: GateFollowUp? {
        guard let currentSessionId,
              let pendingGateFollowUp,
              pendingGateFollowUp.origin.chatSessionID == currentSessionId else { return nil }
        return pendingGateFollowUp
    }

    func toolCallBlockReason(
        tool: ToolName,
        args: [String: Any],
        origin: ToolCallOrigin
    ) -> String? {
        guard let key = origin.suspensionKey,
              suspendedToolOrigins.contains(key) else { return nil }
        let requestedState = args.string("state").flatMap {
            GateState(rawValue: $0)
        }
        let isApprovalRetry = tool == .approveGate
            || (tool == .setGateState
                && requestedState.map(GateApproval.isApproval) == true)
        if isApprovalRetry,
           pendingGateApproval != nil,
           pendingGateOrigin?.suspensionKey == key {
            return nil
        }
        return "This logical agent turn is suspended at a host decision. "
            + "Do not run more tools from it; wait for the host follow-up or start a fresh MCP session."
    }

    private func suspendToolCalls(from origin: ToolCallOrigin) {
        if let key = origin.suspensionKey {
            suspendedToolOrigins.insert(key)
        }
    }

    private func resumeToolCalls(from origin: ToolCallOrigin) {
        if let key = origin.suspensionKey {
            suspendedToolOrigins.remove(key)
        }
    }

    private func prepareToolCallsForFollowUp(from origin: ToolCallOrigin) {
        switch origin {
        case .inAppChat:
            resumeToolCalls(from: origin)
        case .embeddedRuntime:
            let preservedMessages = messages
            _claudeRuntime?.stop()
            messages = preservedMessages
            _claudeRuntime = nil
        case .direct, .externalMCP:
            break
        }
    }

    /// Keeps retries idempotent while one approval card is open.
    func requestGateApproval(
        _ approval: GateApproval,
        origin: ToolCallOrigin = .direct
    ) throws -> GateApprovalRequest {
        let scoped = approval.scoped(to: origin.chatSessionID)
        if let pending = pendingGateApproval {
            suspendToolCalls(from: origin)
            return GateApprovalRequest(
                approval: pending,
                isNew: false,
                matchesRequestedApproval: pending.matchesRequest(scoped)
            )
        }
        guard pendingDialog == nil,
              pendingSpendApproval == nil,
              pendingSpendOperation == nil,
              nativeGateMutationID == nil else {
            throw ToolError(
                "The composer already has a host-owned decision. Do not replace or duplicate it; stop and wait for the user."
            )
        }
        editor?.agentPanelVisible = true
        gateApprovalError = nil
        suspendToolCalls(from: origin)
        pendingGateOrigin = origin
        pendingGateApproval = scoped
        return GateApprovalRequest(approval: scoped, isNew: true, matchesRequestedApproval: true)
    }

    /// Applies the decision locally and resumes its originating in-app turn when possible.
    @discardableResult
    func resolveGate(_ decision: GateDecision) async -> ToolResult? {
        guard let approval = pendingGateApproval else { return nil }
        let origin = pendingGateOrigin ?? .direct
        switch decision {
        case .declined:
            pendingGateApproval = nil
            pendingGateOrigin = nil
            gateApprovalError = nil
            let message = "The user chose Not yet for \(approval.phaseLabel). Keep working on this phase. "
                + "Do not advance or claim the gate was approved."
            enqueueGateFollowUp(message, origin: origin)
            return .ok("The user did not approve \(approval.phaseLabel).")
        case .approved:
            guard !gateApprovalIsWriting else {
                return .error("The approval is already being applied.")
            }
            guard let toolExecutor else {
                let message = "The gate writer is unavailable. The approval request remains open."
                gateApprovalError = message
                return .error(message)
            }
            gateApprovalIsWriting = true
            defer { gateApprovalIsWriting = false }
            do {
                let payload = try await toolExecutor.commitGateApproval(approval)
                pendingGateApproval = nil
                pendingGateOrigin = nil
                gateApprovalError = nil
                if approval.sessionId != nil {
                    enqueueGateFollowUp(
                        "The user approved \(approval.phaseLabel), and the host wrote the gate successfully: \(payload) "
                            + "Continue from the updated project state; do not request this approval again.",
                        origin: origin,
                        includeNextPhaseInstructions: true
                    )
                } else {
                    Task { @MainActor [weak self] in await self?.editor?.refreshEngineState() }
                }
                return .ok(payload)
            } catch let error as ToolError {
                return recordGateApprovalFailure(error.message, approval: approval)
            } catch {
                return recordGateApprovalFailure(error.localizedDescription, approval: approval)
            }
        }
    }

    private func recordGateApprovalFailure(_ reason: String, approval: GateApproval) -> ToolResult {
        let message = "Couldn't approve \(approval.phaseLabel): \(reason)"
        gateApprovalError = message
        enqueueGateFollowUp(
            "The user approved \(approval.phaseLabel), but the host could not write the gate: \(reason) "
                + "The approval card remains open. Address the stated cause without claiming approval, "
                + "inventing a support team, or asking the user to restart the app.",
            origin: pendingGateOrigin ?? .direct
        )
        return .error(message)
    }

    private func enqueueGateFollowUp(
        _ text: String,
        origin: ToolCallOrigin,
        includeNextPhaseInstructions: Bool = false
    ) {
        guard origin.chatSessionID != nil else { return }
        pendingGateFollowUp = GateFollowUp(
            origin: origin,
            text: text,
            includeNextPhaseInstructions: includeNextPhaseInstructions
        )
        Task { @MainActor [weak self] in await self?.preparePendingGateFollowUp() }
    }

    private func preparePendingGateFollowUp() async {
        guard !isStreaming, currentGateFollowUp != nil else { return }
        await editor?.refreshEngineState()
    }

    @discardableResult
    func resumePendingGateFollowUp(nextPhasePrompt: String? = nil) -> Bool {
        guard !isStreaming, !hostFollowUpStartInProgress,
              let followUp = pendingGateFollowUp else { return false }
        guard pendingDialog == nil,
              pendingSpendApproval == nil,
              pendingGateApproval == nil else { return false }
        if let sessionId = followUp.origin.chatSessionID {
            guard sessions.contains(where: { $0.id == sessionId }) else {
                pendingGateFollowUp = nil
                resumeToolCalls(from: followUp.origin)
                return false
            }
            guard sessionId == currentSessionId else { return false }
        }
        guard prepareHostFollowUp() else { return false }
        hostFollowUpStartInProgress = true
        defer { hostFollowUpStartInProgress = false }
        prepareToolCallsForFollowUp(from: followUp.origin)
        let phasePrompt = followUp.includeNextPhaseInstructions
            ? nextPhasePrompt
            : nil
        let text = [followUp.text, phasePrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let started = send(
            text: text,
            mentions: [],
            hidden: true,
            allowWhileBlocked: true
        )
        if started {
            pendingGateFollowUp = nil
        } else if streamError == nil {
            streamError = .upstream(
                "Couldn't resume the agent after approval. Retry the host follow-up."
            )
        }
        return started
    }

    var hasPendingHostFollowUp: Bool {
        currentSpendFollowUp != nil
            || currentGateFollowUp != nil
    }

    func retryPendingHostFollowUp() {
        guard hasPendingHostFollowUp, !isStreaming else { return }
        streamError = nil
        if currentSpendFollowUp != nil {
            _ = resumePendingSpendFollowUp()
        } else {
            Task { @MainActor [weak self] in
                await self?.preparePendingGateFollowUp()
            }
        }
    }

    private func abandonGateApproval() {
        pendingGateApproval = nil
        pendingGateOrigin = nil
        gateApprovalError = nil
        pendingGateFollowUp = nil
        suspendedToolOrigins.removeAll()
    }

    private static let clipMentionLabelMaxLength = 24

    /// Bumped to ask the input field to take focus (e.g. after the plugin launcher inserts a command
    /// that still needs an argument). `AgentInputBox` observes this and focuses its editor.
    private(set) var focusInputRequestTick = 0

    /// Insert `text` into the input field and focus it — used by the plugin launcher for commands that
    /// still need an argument, so the user lands in the field ready to type rather than sending an
    /// incomplete command. Clears mentions (a slash-command carries no media references).
    func prefillInput(_ text: String) {
        editor?.agentPanelVisible = true
        draft = text
        mentions.removeAll()
        pendingFunction = nil
        focusInputRequestTick &+= 1
    }

    func attachMention(for asset: MediaAsset) {
        editor?.agentPanelVisible = true
        pruneDetachedMentions()
        guard !mentions.contains(where: { $0.mediaRef == asset.id && !$0.referencesTimelineContext }) else { return }
        let displayName = Self.disambiguatedMentionName(for: asset, existing: mentions)
        appendMentionToken(displayName)
        mentions.append(AgentMention(displayName: displayName, mediaRef: asset.id, type: asset.type))
    }

    func attachMentions(forClipIds clipIds: [String]) {
        guard let editor, !clipIds.isEmpty else { return }
        editor.agentPanelVisible = true
        pruneDetachedMentions()

        let existingClipIds = Set(mentions.compactMap(\.clipId))
        for ref in Self.clipMentionReferences(for: clipIds, editor: editor) where !existingClipIds.contains(ref.clip.id) {
            let displayName = Self.disambiguatedClipMentionName(
                for: ref.clip,
                label: ref.label,
                trackLabel: ref.trackLabel,
                fps: editor.timeline.fps,
                existing: mentions
            )
            appendMentionToken(displayName)
            mentions.append(AgentMention(
                displayName: displayName,
                mediaRef: ref.clip.mediaRef,
                type: ref.clip.mediaType,
                clipId: ref.clip.id
            ))
        }
    }

    func attachSelectedTimelineRangeMention() {
        guard let editor, let range = editor.validSelectedTimelineRange else { return }
        editor.agentPanelVisible = true
        pruneDetachedMentions()

        let timelineRange = AgentTimelineRangeMention(range: range, fps: editor.timeline.fps)
        guard !mentions.contains(where: { $0.timelineRange == timelineRange }) else { return }

        let displayName = Self.disambiguatedTimelineRangeMentionName(for: timelineRange, existing: mentions)
        appendMentionToken(displayName)
        mentions.append(AgentMention(displayName: displayName, timelineRange: timelineRange))
    }

    private func pruneDetachedMentions() {
        mentions.removeAll { !draft.contains("@\($0.displayName)") }
    }

    private func appendMentionToken(_ displayName: String) {
        let needsSpace = !draft.isEmpty && !draft.hasSuffix(" ") && !draft.hasSuffix("\n")
        draft += (needsSpace ? " " : "") + "@\(displayName) "
    }

    static func disambiguatedMentionName(for asset: MediaAsset, existing: [AgentMention]) -> String {
        let base = asset.mentionDisplayName
        if !existing.contains(where: { $0.displayName == base && $0.mediaRef != asset.id }) {
            return base
        }
        let short = String(asset.id.prefix(6))
        return "\(base)#\(short)"
    }

    static func disambiguatedClipMentionName(
        for clip: Clip,
        label: String,
        trackLabel: String,
        fps: Int,
        existing: [AgentMention]
    ) -> String {
        let shortLabel = compactClipMentionLabel(label)
        let base = AgentMention.makeDisplayName(
            from: "\(shortLabel)-\(trackLabel)-\(formatTimecode(frame: clip.startFrame, fps: fps))"
        )
        let fallback = "Clip-\(String(clip.id.prefix(6)))"
        let candidate = base.isEmpty ? fallback : base
        if !existing.contains(where: { $0.displayName == candidate && $0.clipId != clip.id }) {
            return candidate
        }
        let short = String(clip.id.prefix(6))
        return "\(candidate)#\(short)"
    }

    private static func compactClipMentionLabel(_ label: String) -> String {
        let display = AgentMention.makeDisplayName(from: label)
        guard display.count > clipMentionLabelMaxLength else { return display }
        let end = display.index(display.startIndex, offsetBy: clipMentionLabelMaxLength)
        return String(display[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func disambiguatedTimelineRangeMentionName(
        for range: AgentTimelineRangeMention,
        existing: [AgentMention]
    ) -> String {
        let base = AgentMention.makeDisplayName(from: "Range-\(range.startTimecode)-\(range.endTimecode)")
        let fallback = "Range-\(range.startFrame)-\(range.endFrame)"
        let candidate = base.isEmpty ? fallback : base
        if !existing.contains(where: { $0.displayName == candidate && $0.timelineRange != range }) {
            return candidate
        }
        return "\(candidate)#\(range.startFrame)-\(range.endFrame)"
    }

    private struct ClipMentionReference {
        let clip: Clip
        let label: String
        let trackLabel: String
    }

    private static func clipMentionReferences(for clipIds: [String], editor: EditorViewModel) -> [ClipMentionReference] {
        let requested = Set(clipIds)
        var refs: [ClipMentionReference] = []
        for (trackIndex, track) in editor.timeline.tracks.enumerated() {
            let trackLabel = editor.timelineTrackDisplayLabel(at: trackIndex)
            for clip in track.clips where requested.contains(clip.id) {
                refs.append(ClipMentionReference(
                    clip: clip,
                    label: editor.clipDisplayLabel(for: clip),
                    trackLabel: trackLabel
                ))
            }
        }
        return refs
    }

    weak var editor: EditorViewModel? {
        didSet { toolExecutor = editor.map { ToolExecutor(editor: $0) } }
    }
    private var toolExecutor: ToolExecutor?
    private var currentTask: Task<Void, Never>?

    func loadSessions(from projectURL: URL?) {
        // Opening a project tears down any runtime from the previous one: its `claude` process has the
        // OLD working directory, so reusing it would run the new project's turns against the wrong folder.
        abandonDialog()
        dialogOrigins.removeAll()
        abandonGateApproval()
        abandonSpendApproval()
        abandonRunningSpend()
        pendingSpendFollowUps.removeAll()
        currentTask?.cancel()
        currentTask = nil
        _claudeRuntime?.stop()
        _claudeRuntime = nil
        sessions = ChatSessionStore.load(from: projectURL)
            .filter { !$0.messages.isEmpty }
            .map {
                var session = $0
                session.isOpen = false
                return session
            }
            .sorted { $0.updatedAt > $1.updatedAt }

        let session = ChatSession()
        sessions.insert(session, at: 0)
        currentSessionId = session.id
        messages = []
        isStreaming = false
        draft = ""
        mentions.removeAll()
        pendingFunction = nil
        streamError = nil
        toolExecutor?.resetFeedbackState()
    }

    func newChat() {
        currentTask?.cancel()
        abandonSessionDialog()
        abandonSpendApproval()
        // The runtime process IS a single conversation kept alive for the whole session — a fresh chat
        // must therefore START a fresh process, or it would silently continue the previous conversation.
        _claudeRuntime?.stop()
        _claudeRuntime = nil
        syncMessagesIntoCurrentSession()
        if let id = currentSessionId,
           let idx = sessions.firstIndex(where: { $0.id == id }),
           sessions[idx].messages.isEmpty {
            sessions.remove(at: idx)
        }
        let session = ChatSession()
        sessions.insert(session, at: 0)
        currentSessionId = session.id
        messages = []
        isStreaming = false          // a cancelled first-send encode never had a runtime to stop
        draft = ""
        mentions = []
        pendingFunction = nil
        streamError = nil
        toolExecutor?.resetFeedbackState()
        onSessionsChanged?()
    }

    var openSessions: [ChatSession] { sessions.filter { $0.isOpen } }

    func selectSession(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        currentTask?.cancel()
        abandonSessionDialog()
        abandonSpendApproval()
        syncMessagesIntoCurrentSession()
        if !sessions[idx].isOpen {
            sessions[idx].isOpen = true
            onSessionsChanged?()
        }
        // Rotate to this chat's runtime: change current FIRST so the old runtime's late callbacks no-op
        // (they're bound to the previous chat), then tear it down. The next send rebuilds + `--resume`s
        // the selected chat, reseeded from its transcript.
        currentSessionId = id
        messages = sessions[idx].messages
        isStreaming = false
        _claudeRuntime?.stop()
        _claudeRuntime = nil
        streamError = nil
        if currentSpendFollowUp != nil {
            Task { @MainActor [weak self] in self?.resumePendingSpendFollowUp() }
        } else if currentGateFollowUp != nil {
            Task { @MainActor [weak self] in
                await self?.preparePendingGateFollowUp()
            }
        }
    }

    func closeTab(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isOpen = false
        if currentSessionId == id {
            // Closing the active tab mid-stream: stop the stream and keep its partial reply with
            // THIS session — otherwise the still-running task appends into the next tab's messages.
            currentTask?.cancel()
            abandonSessionDialog()
            abandonSpendApproval()
            isStreaming = false
            syncMessagesIntoCurrentSession()
            if let next = sessions.first(where: { $0.isOpen }) {
                currentSessionId = next.id
                messages = next.messages
                _claudeRuntime?.stop()
                _claudeRuntime = nil
            } else {
                newChat()
                return
            }
        }
        onSessionsChanged?()
    }

    func deleteSession(_ id: UUID) {
        let deletingActive = currentSessionId == id
        if runningSpendStatus?.chatSessionID == id {
            abandonRunningSpend()
        }
        let discardedSpendFollowUps = pendingSpendFollowUps.filter {
            $0.origin.chatSessionID == id
        }
        pendingSpendFollowUps.removeAll { $0.origin.chatSessionID == id }
        for followUp in discardedSpendFollowUps {
            resumeToolCalls(from: followUp.origin)
        }
        if let followUp = pendingGateFollowUp,
           followUp.origin.chatSessionID == id {
            pendingGateFollowUp = nil
            resumeToolCalls(from: followUp.origin)
        }
        sessions.removeAll { $0.id == id }
        if deletingActive {
            currentTask?.cancel()
            abandonSessionDialog()
            abandonSpendApproval()
            currentSessionId = sessions.first(where: { $0.isOpen })?.id
            messages = currentSessionId
                .flatMap { id in sessions.first { $0.id == id }?.messages }
                ?? []
            isStreaming = false
            _claudeRuntime?.stop()      // its process belonged to the deleted chat
            _claudeRuntime = nil
        }
        if openSessions.isEmpty { newChat(); return }
        onSessionsChanged?()
    }

    /// `hidden` seeds the agent's first turn without a visible user bubble — for kickoffs the user
    /// never typed (Start production, a pack starter). The model sees it; the transcript does not.
    @discardableResult
    func send(
        text: String,
        mentions: [AgentMention],
        hidden: Bool = false,
        presentation: AgentUserPresentation? = nil,
        allowWhileBlocked: Bool = false
    ) -> Bool {
        guard allowWhileBlocked || !isComposerBlocked else { return false }
        if claudeRuntimeEnabled {
            guard canStream else {
                streamError = .upstream(setupPrompt + " Agent settings.")
                return false
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            guard prepareWorkingCopyForTurn() else { return false }
            streamError = nil
            return sendViaClaudeRuntime(
                trimmed,
                mentions: mentions,
                hidden: hidden,
                presentation: presentation
            )
        }
        guard canStream else {
            streamError = .upstream("Add an Anthropic API key in Settings to start.")
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard prepareWorkingCopyForTurn() else { return false }
        let referencedMentions = AgentMentionContext.referencedMentions(mentions, in: trimmed)
        let mentionHint = referencedMentions.isEmpty
            ? nil
            : AgentMentionContext.hint(referencedMentions, editor: editor)
        let hints = [mentionHint, Self.selectionHint(editor: editor)].compactMap(\.self)
        let contextHint = hints.isEmpty ? nil : hints.joined(separator: " ")

        resolveOrphanToolUses()
        messages.append(AgentMessage(
            role: .user, blocks: [.text(trimmed)],
            mentions: referencedMentions, contextHint: contextHint, hidden: hidden,
            userPresentation: presentation
        ))
        checkpointCurrentSession()
        streamError = nil
        kickOffStream()
        return true
    }

    func send(controlTurn: AgentControlTurn) {
        send(
            text: controlTurn.command,
            mentions: [],
            presentation: controlTurn.presentation
        )
    }

    private func prepareWorkingCopyForTurn() -> Bool {
        guard let key = editor?.openWorkingCopyKey else { return true }
        do {
            try ProjectWorkingCopy.markDirty(key: key)
            return true
        } catch {
            streamError = .upstream(error.localizedDescription)
            return false
        }
    }

    private func checkpointCurrentSession() {
        syncMessagesIntoCurrentSession()
        onSessionsChanged?()
    }

    /// Grounds scoped prose ("make this warmer") in the user's current selection — the app tells the
    /// agent what "this" is, instead of the agent guessing (docs/UI_UX_CONCEPT.md §4).
    private static func selectionHint(editor: EditorViewModel?) -> String? {
        let pluginLine: String
        if let active = editor?.activePluginName {
            pluginLine = "Active format plugin for this project: \(active)."
        } else {
            pluginLine = "No format plugin is active \u{2014} this project uses the generic production workflow."
        }
        guard let description = editor?.selectionContextHint else { return pluginLine }
        return pluginLine + " The user is currently inspecting \(description); unscoped references like \u{201C}this\u{201D} refer to it."
    }

    func cancel() {
        // Gate approval remains open because its tool call has already returned.
        abandonSpendApproval()
        if claudeRuntimeEnabled {
            currentTask?.cancel()          // a pending attachment encode
            currentTask = nil
            _claudeRuntime?.stop()
            _claudeRuntime = nil           // next send rebuilds + `--resume`s this chat
            isStreaming = false
            return
        }
        currentTask?.cancel()
        currentTask = nil
        isStreaming = false
    }

    // MARK: - Claude Code runtime (Stufe B)

    private var claudeRuntimeEnabled: Bool {
        backend == .claudeCode
    }

    @ObservationIgnored
    private var _claudeRuntime: ClaudeCodeRuntime?

    /// The embedded Claude Code runtime for the CURRENT chat, built lazily so its seed + `--resume`
    /// reflect that chat. Alive across the chat's turns; a switch / cancel / reload rotates it.
    private var claudeRuntime: ClaudeCodeRuntime {
        _claudeRuntime ?? makeClaudeRuntime()
    }

    @discardableResult
    private func makeClaudeRuntime() -> ClaudeCodeRuntime {
        let boundSessionId = currentSessionId
        let chat = boundSessionId.flatMap { id in sessions.first { $0.id == id } }
        let runtime = ClaudeCodeRuntime(
            pluginDirectories: configuredPluginDirectories(),
            mcpPort: Int(MCPService.port),
            appSessionId: boundSessionId,
            resumeSessionId: chat?.claudeSessionId,
            seedMessages: messages,
            resolveWorkingDirectory: { [weak self] in
                Self.configuredWorkingDirectory(projectURL: self?.editor?.workingRoot)
            },
            onSessionId: { [weak self] sid in
                self?.storeClaudeSessionId(sid, for: boundSessionId)
            },
            onResumeFailed: { [weak self] in
                self?.clearClaudeSessionId(for: boundSessionId)
            },
            onAuthenticationRequired: { [weak self] in
                self?.requireClaudeAuthentication(for: boundSessionId)
            },
            onUpdate: { [weak self] messages, isStreaming in
                guard let self, self.currentSessionId == boundSessionId else { return }
                self.messages = messages
                self.isStreaming = isStreaming
            }
        )
        _claudeRuntime = runtime
        return runtime
    }

    private func requireClaudeAuthentication(for sessionId: UUID?) {
        guard currentSessionId == sessionId else { return }
        let status = ClaudeCodeLocator.Status(
            executableURL: claudeStatus?.executableURL,
            version: claudeStatus?.version,
            isAuthenticated: false
        )
        claudeStatusGeneration &+= 1
        claudeStatus = status
        isCheckingClaude = false
        streamError = .authenticationRequired
        _claudeRuntime = nil
        NotificationCenter.default.post(name: .claudeCodeStatusChanged, object: status)
    }

    /// Persist `claude`'s confirmed session id onto its chat so a later tab switch / reload can resume it.
    private func storeClaudeSessionId(_ sid: String, for sessionId: UUID?) {
        guard let sessionId,
              let idx = sessions.firstIndex(where: { $0.id == sessionId }),
              sessions[idx].claudeSessionId != sid else { return }
        sessions[idx].claudeSessionId = sid
    }

    /// `claude` reported this chat's `--resume` id as unknown: forget it so the next send starts fresh,
    /// and drop the failed runtime if it's still the active one so the rebuild omits `--resume`.
    private func clearClaudeSessionId(for sessionId: UUID?) {
        guard let sessionId, let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[idx].claudeSessionId = nil
        if currentSessionId == sessionId { _claudeRuntime = nil }
    }

    /// Route a message to the embedded Claude Code runtime. Mirrors the API path's attachment handling
    /// (`apiMessages`/`inlineImageBlocks`) so uploaded images actually REACH the subprocess instead of
    /// being dropped: referenced image mentions are inlined as base64 image blocks, and the mention JSON
    /// + each asset's on-disk path go into the app-context so the agent can Read / inspect_media a
    /// non-image too.
    @discardableResult
    private func sendViaClaudeRuntime(
        _ trimmed: String,
        mentions: [AgentMention],
        hidden: Bool = false,
        presentation: AgentUserPresentation? = nil
    ) -> Bool {
        // One turn at a time per chat: the composer disables send while streaming, but programmatic
        // callers (kickoffs, pack starters) don't — without this a second send could jump ahead of a
        // first turn still encoding its attachments, delivering the two out of order. Marking busy NOW
        // also means a synchronous launch failure (no binary / no project dir) still transitions
        // true→false, so its error note + the user message get flushed into the chat and the doc dirtied.
        guard !isStreaming else { return false }
        isStreaming = true
        let referenced = AgentMentionContext.referencedMentions(mentions, in: trimmed)
        guard !referenced.isEmpty else {
            // No attachments — send synchronously (the selection/plugin context only).
            let context = Self.selectionHint(editor: editor).map { "<app-context>\($0)</app-context>" }
            let started = claudeRuntime.send(
                text: trimmed,
                context: context,
                hidden: hidden,
                presentation: presentation
            )
            checkpointCurrentSession()
            return started
        }
        let selection = Self.selectionHint(editor: editor)
        let mentionHint = AgentMentionContext.hint(referenced, editor: editor)
        let pathNote = Self.mentionPathNote(referenced, editor: editor)
        // Encoding is async: fence the turn to the chat that sent it, so a switch / new-chat / second
        // send during encode can't deliver this turn into a different chat's process.
        let turn = currentSessionId
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            let inlined = await self.inlineImageBlocks(for: referenced)  // base64-encodes off the main actor
            guard !Task.isCancelled, self.currentSessionId == turn else { return }
            var parts: [String] = []
            if let selection { parts.append(selection) }
            parts.append(mentionHint)
            if let pathNote { parts.append(pathNote) }
            if let note = AgentMentionContext.inlineNote(for: inlined) { parts.append(note) }
            let context = "<app-context>\(parts.joined(separator: " "))</app-context>"
            self.claudeRuntime.send(
                text: trimmed,
                context: context,
                imageBlocks: inlined.blocks,
                hidden: hidden,
                presentation: presentation
            )
            self.checkpointCurrentSession()
        }
        return true
    }

    /// The on-disk path of each mentioned library asset, so the runtime agent (which has native Read over
    /// the project) can open a NON-image attachment (audio/video/document) it wasn't handed inline.
    private static func mentionPathNote(_ mentions: [AgentMention], editor: EditorViewModel?) -> String? {
        guard let editor else { return nil }
        let lines: [String] = mentions.compactMap { mention in
            guard let ref = mention.mediaRef,
                  let asset = editor.mediaAssets.first(where: { $0.id == ref }) else { return nil }
            return "@\(mention.displayName) → \(asset.url.path)"
        }
        guard !lines.isEmpty else { return nil }
        return "Attached files live in content-addressed project storage. Its path basename is an "
            + "opaque internal hash, never a title or filename. Read a non-image attachment at: "
            + lines.joined(separator: "; ") + ". Use the fileName metadata above for its original name."
    }

    private func configuredPluginDirectories() -> [URL] {
        #if DEBUG
        guard let path = UserDefaults.standard.string(forKey: "claudeRuntimePluginDir"), !path.isEmpty else {
            return []
        }
        return [URL(fileURLWithPath: path)]
        #else
        return []
        #endif
    }

    private static func configuredWorkingDirectory(projectURL: URL?) -> URL? {
        projectURL
    }

    private func kickOffStream() {
        currentTask?.cancel()
        isStreaming = true
        currentTask = Task { [weak self] in
            defer {
                self?.isStreaming = false
                self?.syncMessagesIntoCurrentSession()
                self?.onSessionsChanged?()
            }
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        guard let client = selectClient() else {
            streamError = .upstream("No backend available.")
            return
        }
        let origin = currentSessionId.map {
            ToolCallOrigin.inAppChat(sessionID: $0)
        } ?? .direct
        let tools = ToolDefinitions.all.map {
            AnthropicToolSchema(name: $0.name.rawValue, description: $0.description, inputSchema: $0.inputSchema)
        }

        loop: while !Task.isCancelled {
            resolveOrphanToolUses()
            let apiMsgs = await apiMessages()
            let assistant = AgentMessage(role: .assistant, blocks: [])
            messages.append(assistant)
            let assistantID = assistant.id

            do {
                let stream = client.stream(
                    system: AgentInstructions.serverInstructions,
                    tools: tools,
                    messages: apiMsgs
                )

                var stopReason: AnthropicStopReason = .endTurn

                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let chunk):
                        appendTextDelta(chunk, toAssistant: assistantID)
                    case .toolUseComplete(let id, let name, let inputJSON):
                        appendToolUse(id: id, name: name, inputJSON: inputJSON, toAssistant: assistantID)
                    case .messageStop(let reason):
                        stopReason = reason
                    }
                }

                if stopReason == .toolUse {
                    if await runPendingToolUses(
                        assistantID: assistantID,
                        origin: origin
                    ) {
                        break loop
                    }
                    continue loop
                }
                break loop
            } catch is CancellationError {
                dropEmptyAssistantTurn(id: assistantID)
                break loop
            } catch let err as AgentStreamError {
                dropEmptyAssistantTurn(id: assistantID)
                streamError = err
                break loop
            } catch {
                dropEmptyAssistantTurn(id: assistantID)
                streamError = .upstream(error.localizedDescription)
                break loop
            }
        }
    }

    private func assistantMessageIndex(id: UUID) -> Int? {
        messages.firstIndex { $0.id == id && $0.role == .assistant }
    }

    private func dropEmptyAssistantTurn(id: UUID) {
        guard let index = assistantMessageIndex(id: id),
              messages[index].blocks.isEmpty else { return }
        messages.remove(at: index)
    }

    private func appendTextDelta(_ chunk: String, toAssistant id: UUID) {
        guard let index = assistantMessageIndex(id: id) else { return }
        if case .text(let existing)? = messages[index].blocks.last {
            messages[index].blocks[messages[index].blocks.count - 1] = .text(existing + chunk)
        } else {
            messages[index].blocks.append(.text(chunk))
        }
    }

    private func appendToolUse(id toolUseID: String, name: String, inputJSON: String, toAssistant assistantID: UUID) {
        guard let index = assistantMessageIndex(id: assistantID) else { return }
        messages[index].blocks.append(.toolUse(id: toolUseID, name: name, inputJSON: inputJSON))
    }

    @discardableResult
    func runPendingToolUses(
        assistantID: UUID,
        origin: ToolCallOrigin
    ) async -> Bool {
        guard let assistantIndex = assistantMessageIndex(id: assistantID) else { return false }
        let toolUses: [(id: String, name: String, input: String)] = messages[assistantIndex].blocks.compactMap {
            if case let .toolUse(id, name, input) = $0 { return (id, name, input) }
            return nil
        }
        guard let executor = toolExecutor else {
            messages.append(AgentMessage(
                role: .user,
                blocks: toolUses.map {
                    .toolResult(
                        toolUseId: $0.id,
                        content: [.text("Tool executor unavailable.")],
                        isError: true
                    )
                }
            ))
            return false
        }
        let alreadyResolved = resolvedToolUseIds(afterAssistantAt: assistantIndex)

        var resultBlocks: [AgentContentBlock] = []
        var turnSuspended = false
        for use in toolUses where !alreadyResolved.contains(use.id) {
            if turnSuspended {
                resultBlocks.append(.toolResult(
                    toolUseId: use.id,
                    content: [.text(
                        "Not executed: an earlier tool opened a host decision and suspended this turn."
                    )],
                    isError: true
                ))
                continue
            }
            if Task.isCancelled {
                resultBlocks.append(.toolResult(toolUseId: use.id, content: [.text("Cancelled")], isError: true))
                continue
            }
            let result = await executor.execute(
                name: use.name,
                args: Self.parseJSONObject(use.input),
                origin: origin
            )
            resultBlocks.append(.toolResult(toolUseId: use.id, content: result.content, isError: result.isError))
            turnSuspended = result.turnDisposition == .suspendTurn
        }
        if !resultBlocks.isEmpty {
            messages.append(AgentMessage(role: .user, blocks: resultBlocks))
        }
        return turnSuspended
    }

    private func resolvedToolUseIds(afterAssistantAt index: Int) -> Set<String> {
        let next = index + 1
        guard next < messages.count, messages[next].role == .user else { return [] }
        return Set(messages[next].blocks.compactMap {
            if case let .toolResult(id, _, _) = $0 { return id }
            return nil
        })
    }

    private func resolveOrphanToolUses(reason: String = "Cancelled") {
        var i = 0
        while i < messages.count {
            defer { i += 1 }
            guard messages[i].role == .assistant else { continue }
            let toolUseIds: [String] = messages[i].blocks.compactMap {
                if case let .toolUse(id, _, _) = $0 { return id }
                return nil
            }
            guard !toolUseIds.isEmpty else { continue }

            let next = i + 1
            let nextIsToolResult = next < messages.count
                && messages[next].role == .user
                && messages[next].blocks.contains(where: {
                    if case .toolResult = $0 { return true }
                    return false
                })
            let resolved: Set<String> = nextIsToolResult
                ? Set(messages[next].blocks.compactMap {
                    if case let .toolResult(id, _, _) = $0 { return id }
                    return nil
                })
                : []

            let orphans = toolUseIds.filter { !resolved.contains($0) }
            guard !orphans.isEmpty else { continue }

            let synthetic: [AgentContentBlock] = orphans.map {
                .toolResult(toolUseId: $0, content: [.text(reason)], isError: true)
            }
            if nextIsToolResult {
                messages[next].blocks.insert(contentsOf: synthetic, at: 0)
            } else {
                messages.insert(AgentMessage(role: .user, blocks: synthetic), at: next)
            }
        }
    }

    private static func parseJSONObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func syncMessagesIntoCurrentSession() {
        guard let id = currentSessionId,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].messages = messages
        sessions[idx].updatedAt = Date()
        // Title from the first message the user actually typed — never a hidden kickoff (that would
        // put the behind-the-scenes prompt on the tab/history).
        if sessions[idx].title == "New chat",
           let first = messages.first(where: {
               $0.role == .user && !$0.hidden
                   && ($0.userPresentation == nil || $0.userPresentation?.typedText?.isEmpty == false)
           }) {
            sessions[idx].title = Self.title(from: first)
        }
    }

    private func apiMessages() async -> [AnthropicMessage] {
        var result: [AnthropicMessage] = []
        for msg in messages {
            var content = msg.blocks.compactMap(Self.contentBlockJSON)
            if msg.role == .user, !msg.mentions.isEmpty || msg.contextHint != nil {
                let inlined = await inlineImageBlocks(for: msg.mentions)
                var hint = msg.contextHint ?? AgentMentionContext.hint(msg.mentions, editor: editor)
                if let note = AgentMentionContext.inlineNote(for: inlined) { hint += " " + note }
                content.insert(contentsOf: inlined.blocks, at: 0)
                content.insert(["type": "text", "text": hint], at: 0)
            }
            guard !content.isEmpty else { continue }
            result.append(AnthropicMessage(role: msg.role == .user ? .user : .assistant, content: content))
        }
        return result
    }

    private func inlineImageBlocks(for mentions: [AgentMention]) async -> AgentMentionContext.InlinedMentions {
        var out = AgentMentionContext.InlinedMentions()
        guard let editor else {
            for mention in mentions where mention.type == .image {
                if let mediaRef = mention.mediaRef { out.failures[mediaRef] = "editor unavailable" }
            }
            return out
        }
        // Resolve mention -> URL on the main actor, then encode off it.
        var pending: [(mediaRef: String, url: URL)] = []
        for mention in mentions where mention.type == .image {
            guard let mediaRef = mention.mediaRef else { continue }
            guard let asset = editor.mediaAssets.first(where: { $0.id == mediaRef }) else {
                out.failures[mediaRef] = "asset not in media library"
                continue
            }
            pending.append((mediaRef, asset.url))
        }
        let jobs = pending
        let encoded = await Task.detached(priority: .userInitiated) {
            jobs.map { job in
                (job.mediaRef, ImageEncoder.encode(url: job.url).map { ($0.mime, $0.data.base64EncodedString()) })
            }
        }.value
        for (mediaRef, result) in encoded {
            guard let (mime, base64) = result else {
                out.failures[mediaRef] = "could not read or decode image file"
                continue
            }
            out.blocks.append([
                "type": "image",
                "source": ["type": "base64", "media_type": mime, "data": base64],
            ])
            out.inlinedIds.insert(mediaRef)
        }
        return out
    }

    private static func contentBlockJSON(_ block: AgentContentBlock) -> [String: Any]? {
        switch block {
        case .text(let s):
            guard !s.isEmpty else { return nil }
            return ["type": "text", "text": s]
        case .toolUse(let id, let name, let inputJSON):
            return [
                "type": "tool_use", "id": id, "name": name,
                "input": parseJSONObject(inputJSON),
            ]
        case .toolResult(let toolUseId, let content, let isError):
            let contentJSON: [[String: Any]] = content.map {
                switch $0 {
                case .text(let s): return ["type": "text", "text": s]
                case .image(let base64, let mime):
                    return ["type": "image", "source": ["type": "base64", "media_type": mime, "data": base64]]
                }
            }
            return [
                "type": "tool_result", "tool_use_id": toolUseId,
                "content": contentJSON, "is_error": isError,
            ]
        }
    }

    private static func title(from message: AgentMessage) -> String {
        if let presentation = message.userPresentation {
            if let typed = presentation.typedText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !typed.isEmpty {
                return String(typed.prefix(40))
            }
            if let summary = presentation.choiceRecord?.summary, !summary.isEmpty {
                return String(summary.prefix(40))
            }
            return "New chat"
        }
        for block in message.blocks {
            if case let .text(s) = block {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return String(trimmed.prefix(40)) }
            }
        }
        return "New chat"
    }
}

struct AgentMessage: Identifiable, Codable {
    enum Role: String, Codable { case user, assistant }
    let id: UUID
    let role: Role
    var blocks: [AgentContentBlock]
    var mentions: [AgentMention]
    var contextHint: String?
    /// A kickoff/starter turn the USER never typed — sent to the model to start the agent working,
    /// but NOT rendered in the transcript (showing it would be a fake, uneditable user message —
    /// a look into the kitchen). Default false; decodes as false for pre-existing sessions.
    var hidden: Bool = false
    /// Optional rendering for a structured user action whose blocks remain model-facing.
    var userPresentation: AgentUserPresentation?

    init(
        id: UUID = UUID(),
        role: Role,
        blocks: [AgentContentBlock],
        mentions: [AgentMention] = [],
        contextHint: String? = nil,
        hidden: Bool = false,
        userPresentation: AgentUserPresentation? = nil
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.mentions = mentions
        self.contextHint = contextHint
        self.hidden = hidden
        self.userPresentation = userPresentation
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, blocks, mentions, contextHint, hidden, userPresentation
    }

    // Custom decode so `hidden` (added later) is optional: synthesized Codable would REQUIRE the key
    // and fail to decode pre-existing saved sessions, silently losing their chat history.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        blocks = try c.decode([AgentContentBlock].self, forKey: .blocks)
        mentions = try c.decodeIfPresent([AgentMention].self, forKey: .mentions) ?? []
        contextHint = try c.decodeIfPresent(String.self, forKey: .contextHint)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        userPresentation = try c.decodeIfPresent(AgentUserPresentation.self, forKey: .userPresentation)
    }
}

enum AgentContentBlock: Codable {
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(toolUseId: String, content: [ToolResult.Block], isError: Bool)

    private enum Kind: String, Codable { case text, toolUse, toolResult }
    private enum CodingKeys: String, CodingKey {
        case kind, text, id, name, input, toolUseId, content, isError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try c.decode(String.self, forKey: .text))
        case .toolUse:
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                inputJSON: try c.decode(String.self, forKey: .input)
            )
        case .toolResult:
            self = .toolResult(
                toolUseId: try c.decode(String.self, forKey: .toolUseId),
                content: try c.decode([ToolResult.Block].self, forKey: .content),
                isError: try c.decode(Bool.self, forKey: .isError)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(s, forKey: .text)
        case .toolUse(let id, let name, let inputJSON):
            try c.encode(Kind.toolUse, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(inputJSON, forKey: .input)
        case .toolResult(let toolUseId, let content, let isError):
            try c.encode(Kind.toolResult, forKey: .kind)
            try c.encode(toolUseId, forKey: .toolUseId)
            try c.encode(content, forKey: .content)
            try c.encode(isError, forKey: .isError)
        }
    }
}
