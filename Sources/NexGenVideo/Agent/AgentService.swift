import Foundation
import Observation

@Observable
@MainActor
final class AgentService {

    private var apiKey: String = ""
    private var apiKeyObserver: NSObjectProtocol?

    init() {
        reloadAPIKey()
        apiKeyObserver = NotificationCenter.default.addObserver(
            forName: .anthropicAPIKeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadAPIKey()
            }
        }
    }

    private func reloadAPIKey() {
        Task { [weak self] in
            let key = await Task.detached(priority: .utility) {
                AnthropicKeychain.load() ?? ""
            }.value
            self?.apiKey = key
        }
    }

    isolated deinit {
        if let token = apiKeyObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    var hasApiKey: Bool { !apiKey.isEmpty }

    /// The agent can run with EITHER a BYO Anthropic key OR the embedded Claude Code runtime
    /// (`claude -p`, uses the user's subscription — no API key needed). `send()` routes to the
    /// runtime first when it's enabled.
    var canStream: Bool { hasApiKey || claudeRuntimeEnabled }

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
            // A finished agent turn may have written engine artifacts (brief, treatment, ledger,
            // gates, frames) — re-read them so the cockpit reflects the work without a window switch.
            if oldValue, !isStreaming {
                Task { @MainActor [weak self] in await self?.editor?.refreshEngineState() }
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

    /// The ONE pending generative dialog (#96, composer-dock architecture). Set by the show_dialog
    /// tool; the card renders above the input. Submitting composes a single structured message —
    /// the compact transcript record — and clears; cancel clears silently (the agent was told to
    /// wait for the next user message either way).
    var pendingDialog: AgentDialog? {
        didSet {
            guard oldValue?.id != pendingDialog?.id else { return }
            dialogChoiceSelections = [:]
        }
    }

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
        pendingDialog = nil
        switch dialog.purpose {
        case .chatClarification:
            send(text: Self.chatMessage(from: dialog, result: result), mentions: [])
        case .generationIntent:
            if let sink = onGenerationDialogIntent {
                sink(Self.intentLine(from: dialog, result: result))
            } else {
                send(text: Self.chatMessage(from: dialog, result: result), mentions: [])
            }
        }
    }

    /// Sink for a `.generationIntent` dialog's composed intent, set by the surface that owns the
    /// generation (e.g. the music tab). When unset the intent is composed into a chat message so the
    /// answer is never dropped.
    var onGenerationDialogIntent: (@MainActor (String) -> Void)?

    /// The structured chat-message form of a dialog answer — labeled sections + free-text direction.
    private static func chatMessage(from dialog: AgentDialog, result: AgentDialogResult) -> String {
        var parts: [String] = []
        for section in dialog.sections {
            let picked = result.labels(section.id)
            if !picked.isEmpty { parts.append("\(section.label): \(picked.joined(separator: ", "))") }
            if case .toggle = section.kind {
                parts.append("\(section.label): \((result.toggles[section.id] ?? false) ? "yes" : "no")")
            }
        }
        var line = "Dialog \u{201C}\(dialog.title)\u{201D} \u{2014} " + (parts.isEmpty ? "confirmed" : parts.joined(separator: "; "))
        if !result.direction.isEmpty { line += ". Direction: \(result.direction)" }
        return line
    }

    /// The compact intent line for a generation dialog — picked chip labels then the free-text
    /// direction, comma-joined (matches the music tab's original composition).
    private static func intentLine(from dialog: AgentDialog, result: AgentDialogResult) -> String {
        var parts = result.allLabels
        if !result.direction.isEmpty { parts.append(result.direction) }
        return parts.joined(separator: ", ")
    }

    func cancelDialog() {
        pendingDialog = nil
    }

    // MARK: - Spend approval (Cost-Guard, M7)

    /// The ONE pending spend confirmation (locked provider architecture — user has the final word on
    /// paid agent renders). Set while an agent render waits for approval; the composer dock renders a
    /// `SpendApprovalCard` above the input, exactly where the generative dialog lives (never a modal).
    private(set) var pendingSpendApproval: SpendApproval?

    @ObservationIgnored
    private var spendContinuation: CheckedContinuation<SpendDecision, Never>?

    /// Suspend the agent's render tool-call until the user taps Approve/Decline. This is what makes it
    /// user-clicks-to-confirm and not agent-self-asserted: the continuation resolves ONLY from
    /// `resolveSpend`, which the card's buttons call. A prior pending approval (should not happen —
    /// one tool call at a time) is declined so no continuation leaks.
    func requestSpendApproval(_ approval: SpendApproval) async -> SpendDecision {
        if spendContinuation != nil { resolveSpend(.declined) }
        editor?.agentPanelVisible = true
        return await withCheckedContinuation { continuation in
            spendContinuation = continuation
            pendingSpendApproval = approval
        }
    }

    /// Resolve the pending approval (from the card's buttons, or teardown). Clears the card and
    /// resumes the suspended tool call exactly once.
    func resolveSpend(_ decision: SpendDecision) {
        pendingSpendApproval = nil
        guard let continuation = spendContinuation else { return }
        spendContinuation = nil
        continuation.resume(returning: decision)
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
        draft = ""
        mentions.removeAll()
        pendingFunction = nil
        streamError = nil
        toolExecutor?.resetFeedbackState()
    }

    func newChat() {
        currentTask?.cancel()
        resolveSpend(.declined)
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
        resolveSpend(.declined)
        syncMessagesIntoCurrentSession()
        if !sessions[idx].isOpen {
            sessions[idx].isOpen = true
            onSessionsChanged?()
        }
        currentSessionId = id
        messages = sessions[idx].messages
        streamError = nil
    }

    func closeTab(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isOpen = false
        if currentSessionId == id {
            // Closing the active tab mid-stream: stop the stream and keep its partial reply with
            // THIS session — otherwise the still-running task appends into the next tab's messages.
            currentTask?.cancel()
            resolveSpend(.declined)
            isStreaming = false
            syncMessagesIntoCurrentSession()
            if let next = sessions.first(where: { $0.isOpen }) {
                currentSessionId = next.id
                messages = next.messages
            } else {
                newChat()
                return
            }
        }
        onSessionsChanged?()
    }

    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if currentSessionId == id {
            currentSessionId = sessions.first(where: { $0.isOpen })?.id
            messages = currentSessionId
                .flatMap { id in sessions.first { $0.id == id }?.messages }
                ?? []
        }
        if openSessions.isEmpty { newChat(); return }
        onSessionsChanged?()
    }

    /// `hidden` seeds the agent's first turn without a visible user bubble — for kickoffs the user
    /// never typed (Start production, a pack starter). The model sees it; the transcript does not.
    func send(text: String, mentions: [AgentMention], hidden: Bool = false) {
        if claudeRuntimeEnabled {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            streamError = nil
            sendViaClaudeRuntime(trimmed, hidden: hidden)
            return
        }
        guard canStream else {
            streamError = .upstream("Add an Anthropic API key in Settings to start.")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let referencedMentions = AgentMentionContext.referencedMentions(mentions, in: trimmed)
        let mentionHint = referencedMentions.isEmpty
            ? nil
            : AgentMentionContext.hint(referencedMentions, editor: editor)
        let hints = [mentionHint, Self.selectionHint(editor: editor)].compactMap(\.self)
        let contextHint = hints.isEmpty ? nil : hints.joined(separator: " ")

        resolveOrphanToolUses()
        messages.append(AgentMessage(
            role: .user, blocks: [.text(trimmed)],
            mentions: referencedMentions, contextHint: contextHint, hidden: hidden
        ))
        streamError = nil
        kickOffStream()
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
        // A render awaiting spend approval is part of this turn — stopping declines it.
        resolveSpend(.declined)
        if claudeRuntimeEnabled {
            _claudeRuntime?.stop()
            isStreaming = false
            return
        }
        currentTask?.cancel()
        currentTask = nil
        isStreaming = false
    }

    // MARK: - Claude Code runtime (Stufe B)

    private var claudeRuntimeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "useClaudeCodeRuntime")
    }

    @ObservationIgnored
    private var _claudeRuntime: ClaudeCodeRuntime?
    /// The active pack the cached runtime was built with — a change rebuilds on the next send so the
    /// session's context line names the current pack.
    @ObservationIgnored
    private var claudeRuntimeBuiltWithPlugin: String?

    /// The embedded Claude Code runtime, lazily built and cached. Rebuilt (only when safe — never
    /// mid-stream) when the active pack changes, so the next session picks up the current context.
    /// Rebuilding stops the old runtime's process; the fresh one starts on the next `send`.
    private var claudeRuntime: ClaudeCodeRuntime {
        if let runtime = _claudeRuntime {
            let pluginChanged = claudeRuntimeBuiltWithPlugin != editor?.activePluginName
            if pluginChanged, !isStreaming {
                runtime.stop()
                return makeClaudeRuntime()
            }
            return runtime
        }
        return makeClaudeRuntime()
    }

    @discardableResult
    private func makeClaudeRuntime() -> ClaudeCodeRuntime {
        let runtime = ClaudeCodeRuntime(
            pluginDirectories: configuredPluginDirectories(),
            mcpPort: Int(MCPService.port),
            permissionMode: Self.configuredPermissionMode(),
            resolveWorkingDirectory: { [weak self] in
                Self.configuredWorkingDirectory(projectURL: self?.editor?.projectURL)
            },
            onUpdate: { [weak self] messages, isStreaming in
                self?.messages = messages
                self?.isStreaming = isStreaming
            }
        )
        claudeRuntimeBuiltWithPlugin = editor?.activePluginName
        _claudeRuntime = runtime
        return runtime
    }

    /// Route a message to the embedded Claude Code runtime. The engine is native and in-process, so
    /// there's nothing to bootstrap — the session starts immediately with NexGenVideo's MCP.
    private func sendViaClaudeRuntime(_ trimmed: String, hidden: Bool = false) {
        let context = Self.selectionHint(editor: editor).map { "<app-context>\($0)</app-context>" }
        claudeRuntime.send(text: trimmed, context: context, hidden: hidden)
    }

    private static func configuredPermissionMode() -> String {
        let value = UserDefaults.standard.string(forKey: "claudeRuntimePermissionMode")
        return (value?.isEmpty == false) ? value! : "bypassPermissions"
    }

    /// External `--plugin-dir` overrides for the embedded runtime. First-party packs are native (no
    /// on-disk plugin layer), so this is only the dev "extra plugin folder" for developing an external
    /// Claude-Code plugin — not pack activation, which is native and needs no dir.
    private func configuredPluginDirectories() -> [URL] {
        guard let path = UserDefaults.standard.string(forKey: "claudeRuntimePluginDir"), !path.isEmpty else {
            return []
        }
        return [URL(fileURLWithPath: path)]
    }

    private static func configuredWorkingDirectory(projectURL: URL?) -> URL? {
        // The embedded runtime's cwd is the open project package — never a global override, which
        // used to redirect every project's engine data to one shared folder.
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
                    await runPendingToolUses(assistantID: assistantID)
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

    private func runPendingToolUses(assistantID: UUID) async {
        guard let assistantIndex = assistantMessageIndex(id: assistantID) else { return }
        guard let executor = toolExecutor else {
            messages.append(AgentMessage(role: .user, blocks: [.text("Tool executor unavailable.")]))
            return
        }

        let toolUses: [(id: String, name: String, input: String)] = messages[assistantIndex].blocks.compactMap {
            if case let .toolUse(id, name, input) = $0 { return (id, name, input) }
            return nil
        }
        let alreadyResolved = resolvedToolUseIds(afterAssistantAt: assistantIndex)

        var resultBlocks: [AgentContentBlock] = []
        for use in toolUses where !alreadyResolved.contains(use.id) {
            if Task.isCancelled {
                resultBlocks.append(.toolResult(toolUseId: use.id, content: [.text("Cancelled")], isError: true))
                continue
            }
            let result = await executor.execute(name: use.name, args: Self.parseJSONObject(use.input))
            resultBlocks.append(.toolResult(toolUseId: use.id, content: result.content, isError: result.isError))
        }
        if !resultBlocks.isEmpty {
            messages.append(AgentMessage(role: .user, blocks: resultBlocks))
        }
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
           let first = messages.first(where: { $0.role == .user && !$0.hidden }) {
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

    init(id: UUID = UUID(), role: Role, blocks: [AgentContentBlock], mentions: [AgentMention] = [], contextHint: String? = nil, hidden: Bool = false) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.mentions = mentions
        self.contextHint = contextHint
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey { case id, role, blocks, mentions, contextHint, hidden }

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
