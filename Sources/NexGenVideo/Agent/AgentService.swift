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
    var isStreaming: Bool = false
    var streamError: AgentStreamError?
    var onSessionsChanged: (@MainActor () -> Void)?

    var draft: String = ""
    var mentions: [AgentMention] = []
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
        streamError = nil
        toolExecutor?.resetFeedbackState()
    }

    func newChat() {
        currentTask?.cancel()
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
        streamError = nil
        toolExecutor?.resetFeedbackState()
        onSessionsChanged?()
    }

    var openSessions: [ChatSession] { sessions.filter { $0.isOpen } }

    func selectSession(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        currentTask?.cancel()
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

    func send(text: String, mentions: [AgentMention]) {
        if claudeRuntimeEnabled {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            streamError = nil
            sendViaClaudeRuntime(trimmed)
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
            mentions: referencedMentions, contextHint: contextHint
        ))
        streamError = nil
        kickOffStream()
    }

    /// Grounds scoped prose ("make this warmer") in the user's current selection — the app tells the
    /// agent what "this" is, instead of the agent guessing (docs/UI_UX_CONCEPT.md §4).
    private static func selectionHint(editor: EditorViewModel?) -> String? {
        guard let description = editor?.selectionContextHint else { return nil }
        return "The user is currently inspecting \(description); unscoped references like \u{201C}this\u{201D} refer to it."
    }

    func cancel() {
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

    /// Whether the embedded Claude Code runtime is on — the only runtime where plugin slash-commands
    /// actually load. The plugin launcher gates its affordance on this (in the BYO-key agent a
    /// `/plugin:cmd` string is just literal text).
    var useClaudeCodeRuntime: Bool { claudeRuntimeEnabled }

    @ObservationIgnored
    private var _claudeRuntime: ClaudeCodeRuntime?
    /// Whether the cached `_claudeRuntime` was built while the engine MCP was available. When the
    /// engine becomes available *after* the runtime was first built engine-less (the post-bootstrap
    /// case this fix addresses), the cached runtime is stale and must be rebuilt so the next session
    /// includes the `engine` MCP — without an app restart. See the `claudeRuntime` accessor.
    @ObservationIgnored
    private var claudeRuntimeBuiltWithEngine = false

    /// The embedded Claude Code runtime, lazily built and cached. Rebuilt (only when safe — never
    /// mid-stream) once the engine becomes available after the cached runtime was created engine-less,
    /// so the engine MCP attaches to the next session. Rebuilding stops the old runtime's process; the
    /// fresh one starts a new process (with the engine MCP) on the next `send`.
    private var claudeRuntime: ClaudeCodeRuntime {
        let engineAvailable = Self.engineAvailable
        if let runtime = _claudeRuntime {
            if engineAvailable, !claudeRuntimeBuiltWithEngine, !isStreaming {
                runtime.stop()
                return makeClaudeRuntime(engineAvailable: engineAvailable)
            }
            return runtime
        }
        return makeClaudeRuntime(engineAvailable: engineAvailable)
    }

    /// True when the engine venv is bootstrapped and its python key resolves — i.e. exactly when
    /// `ClaudeCodeRuntime.engineMcpServers()` would register the `engine` MCP server.
    private static var engineAvailable: Bool {
        if case .ready = EngineRuntime.status() { return true }
        return false
    }

    @discardableResult
    private func makeClaudeRuntime(engineAvailable: Bool) -> ClaudeCodeRuntime {
        ensureEngineBootstrapped()
        let runtime = ClaudeCodeRuntime(
            pluginDirectories: Self.configuredPluginDirectories(),
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
        _claudeRuntime = runtime
        claudeRuntimeBuiltWithEngine = engineAvailable
        return runtime
    }

    /// Route a message to the embedded Claude Code runtime. If the bundled engine is still
    /// bootstrapping (or not yet started), await it first so the session starts WITH the engine MCP
    /// rather than racing the bootstrap and silently coming up engine-less. A `.failed` bootstrap is
    /// surfaced via `streamError` and the message is not sent. Without a bundled engine
    /// (`.unavailable`) or once `.ready`, sends immediately.
    private func sendViaClaudeRuntime(_ trimmed: String) {
        let context = Self.selectionHint(editor: editor).map { "<app-context>\($0)</app-context>" }
        if case .notBootstrapped = EngineRuntime.status() {
            let task = startEngineBootstrap()
            isStreaming = true
            Task { @MainActor [weak self] in
                let status = await task?.value ?? EngineRuntime.status()
                guard let self else { return }
                self.isStreaming = false
                if case .failed = status { return }  // streamError already set by the bootstrap task
                guard self.claudeRuntimeEnabled else { return }
                self.claudeRuntime.send(text: trimmed, context: context)
            }
            return
        }
        claudeRuntime.send(text: trimmed, context: context)
    }

    private static func configuredPermissionMode() -> String {
        let value = UserDefaults.standard.string(forKey: "claudeRuntimePermissionMode")
        return (value?.isEmpty == false) ? value! : "bypassPermissions"
    }

    /// Auto-discovered plugin dirs (bundled + user import dir) unioned with the optional manual
    /// "Plugin folder" override, de-duped by path. The manual entry leads so an explicit pick wins
    /// ordering; discovery fills in everything installed on disk without the user pointing at a folder.
    private static func configuredPluginDirectories() -> [URL] {
        var ordered: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            if seen.insert(url.standardizedFileURL.path).inserted { ordered.append(url) }
        }
        if let path = UserDefaults.standard.string(forKey: "claudeRuntimePluginDir"), !path.isEmpty {
            add(URL(fileURLWithPath: path))
        }
        for dir in PluginManager.discoveredPluginDirectories() { add(dir) }
        return ordered
    }

    private static func configuredWorkingDirectory(projectURL: URL?) -> URL? {
        if let override = UserDefaults.standard.string(forKey: "claudeRuntimeWorkingDir"), !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return projectURL
    }

    /// In-flight bootstrap, awaited by `send()` so a message can't silently proceed engine-less while
    /// the engine is still being set up. Holds the bootstrap's resulting `Status`. Its presence is the
    /// idempotency guard — at most one bootstrap runs per service.
    @ObservationIgnored
    private var engineBootstrapTask: Task<EngineRuntime.Status, Never>?

    /// True while the engine venv is being bootstrapped — the panel shows a "Setting up engine…"
    /// note via `send()` instead of starting a session without the engine MCP.
    private(set) var isBootstrappingEngine = false

    /// Kick off the engine venv bootstrap (uv) without blocking. Idempotent; on success it sets
    /// `claudeRuntimeEnginePython`, which `ClaudeCodeRuntime` registers as the `engine` MCP server.
    /// No-op without a bundled engine (dev builds).
    ///
    /// When the engine is already bootstrapped, re-check the discovered plugin packs instead — a
    /// plugin imported into the user dir after first setup still gets its pack installed (idempotent).
    private func ensureEngineBootstrapped() {
        switch EngineRuntime.status() {
        case .notBootstrapped:
            startEngineBootstrap()
        case .ready:
            Task.detached { await EngineRuntime.installDiscoveredPacks() }
        case .unavailable, .failed:
            break
        }
    }

    /// Begin the engine bootstrap if one isn't already running, exposing it as an awaitable task so a
    /// concurrent `send()` can wait for readiness. Drives `isBootstrappingEngine` and surfaces a
    /// `.failed` result through `streamError`.
    @discardableResult
    private func startEngineBootstrap() -> Task<EngineRuntime.Status, Never>? {
        if let existing = engineBootstrapTask { return existing }
        guard case .notBootstrapped = EngineRuntime.status() else { return nil }
        isBootstrappingEngine = true
        let task = Task { @MainActor [weak self] in
            let status = await EngineRuntime.bootstrap()
            if let self {
                self.isBootstrappingEngine = false
                self.engineBootstrapTask = nil
                if case .failed(let msg) = status {
                    self.streamError = .upstream("Engine setup failed: \(msg)")
                }
            }
            return status
        }
        engineBootstrapTask = task
        return task
    }

    /// Proactively bootstrap the engine when the Claude Code runtime is enabled, so the `engine` MCP
    /// is ready before the first message (rather than racing it). Called on app launch.
    func prepareEngineIfRuntimeEnabled() {
        guard claudeRuntimeEnabled else { return }
        if case .notBootstrapped = EngineRuntime.status() {
            startEngineBootstrap()
        } else {
            ensureEngineBootstrapped()
        }
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
        if sessions[idx].title == "New chat",
           let first = messages.first(where: { $0.role == .user }) {
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

    init(id: UUID = UUID(), role: Role, blocks: [AgentContentBlock], mentions: [AgentMention] = [], contextHint: String? = nil) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.mentions = mentions
        self.contextHint = contextHint
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
