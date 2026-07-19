import Foundation
import NexGenEngine
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
        // Pipeline inputs (not media clips) are written deterministically into the project by the host,
        // then the agent is briefed — rather than importing to the media library. Unknown/absent
        // attachAs falls through to the normal media-asset path.
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
            attachSongFromDialog(dialog: dialog, result: result)
            return
        default:
            break
        }
        switch dialog.purpose {
        case .chatClarification:
            let attached = importDialogFiles(result.fileURLs)
            send(text: Self.chatMessage(from: dialog, result: result, attached: attached), mentions: attached)
        case .generationIntent:
            if let sink = onGenerationDialogIntent {
                sink(Self.intentLine(from: dialog, result: result))
            } else {
                let attached = importDialogFiles(result.fileURLs)
                send(text: Self.chatMessage(from: dialog, result: result, attached: attached), mentions: attached)
            }
        }
    }

    /// Write a text-sidecar intake (lyrics / story script) deterministically into the project (copied,
    /// never moved), then brief the agent on what arrived — so the pipeline works FROM the user's
    /// material (brownfield) instead of inventing it. Kept host-side and deterministic, matching the
    /// hard-gate philosophy: the file placement is a fact, not something the agent narrates.
    private func attachTextSidecar(_ kind: String, dialog: AgentDialog, result: AgentDialogResult) {
        // Resolve the pipeline DATA ROOT the same way the workflow tools do (workingRoot may be the
        // package home; the sidecar dirs live under <home>/pipeline). No project ⇒ don't drop the answer.
        guard let editor, let workingRoot = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: workingRoot)
        else {
            send(text: Self.chatMessage(from: dialog, result: result), mentions: [])
            return
        }
        // Accept EITHER an uploaded file OR pasted text (the dialog's textField). Neither ⇒ the user
        // skipped this optional step; tell the agent so it moves on instead of waiting forever.
        let content: String
        if let src = result.fileURLs.first {
            guard let text = try? String(contentsOf: src, encoding: .utf8) else {
                send(text: "Couldn't read the \(kind) file — it isn't UTF-8 text. Ask the user for a .txt/.md.", mentions: [])
                return
            }
            content = text
        } else {
            let pasted = result.direction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pasted.isEmpty else {
                send(text: "No \(kind) provided — the user skipped it. Proceed without \(kind).", mentions: [])
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
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: dir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        } catch {
            send(text: "Couldn't attach the \(kind): \(error.localizedDescription).", mentions: [])
            return
        }
        editor.onPipelineChanged?()
        send(text: sidecarBrief(kind, relPath: "\(relDir)/\(filename)", content: content), mentions: [])
    }

    /// The agent-facing brief after a sidecar lands: what to do with it. Lyrics → label measured
    /// sections; script → build the treatment/bible FROM it (brownfield), don't invent a new story.
    private func sidecarBrief(_ kind: String, relPath: String, content: String) -> String {
        switch kind {
        case "lyrics":
            let markers = Self.lyricsSectionMarkers(content)
            if markers.isEmpty {
                return "Lyrics attached to \(relPath). No [Section] markers found — label the measured "
                    + "analysis sections yourself and keep their measured start/end boundaries; never invent timing."
            }
            return "Lyrics attached to \(relPath). Section markers, in order: \(markers.joined(separator: ", ")). "
                + "Use them to LABEL the measured analysis sections (lyrics give labels/order; the measured "
                + "downbeat-snapped boundaries stay the source of truth for timing)."
        default:
            return "Story script attached to \(relPath). This is a BROWNFIELD project: build the treatment, "
                + "bible, and shots FROM this script — its characters, locations, and beats are the source of "
                + "truth. Confirm your reading with the user; don't invent a different story."
        }
    }

    /// Copy prepared character/location reference images into the bible-anchor convention
    /// `import/<characters|locations>/<slug>/` (copy, never move), keyed by the identity name the user
    /// typed. This is the brownfield path: the bible-agent (K5) adopts these as identity anchors, so the
    /// pipeline stays consistent with the user's prepared assets instead of inventing new ones.
    private func attachIdentityAssets(_ kind: String, dialog: AgentDialog, result: AgentDialogResult) {
        guard let editor, let workingRoot = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: workingRoot),
              !result.fileURLs.isEmpty
        else {
            send(text: Self.chatMessage(from: dialog, result: result), mentions: [])
            return
        }
        let name = result.direction.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Self.identitySlug(name)
        guard !slug.isEmpty else {
            send(text: "Couldn't attach the \(kind) — no usable name was given. Ask the user for the "
                + "\(kind)'s name, then re-present the dialog.", mentions: [])
            return
        }
        let category = kind == "location" ? "locations" : "characters"
        let dir = dataRoot.appendingPathComponent("import").appendingPathComponent(category).appendingPathComponent(slug)
        let copied: [String]
        do {
            copied = try Self.copyFilesUniquely(result.fileURLs, into: dir)
        } catch {
            send(text: "Couldn't attach the \(kind) \"\(name)\": \(error.localizedDescription).", mentions: [])
            return
        }
        editor.onPipelineChanged?()
        let noun = kind == "location" ? "Location" : "Character"
        send(text: "\(noun) \"\(name)\" attached: \(copied.count) reference image\(copied.count == 1 ? "" : "s") "
            + "in import/\(category)/\(slug)/. This is a BROWNFIELD anchor — the bible-agent adopts it; "
            + "keep this identity consistent across the pipeline and don't invent a different one.", mentions: [])
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

    /// Place the picked song straight into the project's `audio/` (copy, never move) and hold the
    /// one-song contract — no separate `attach_song` step for the agent to forget. Copies the new song
    /// in first, THEN clears any other audio file, so a failure never leaves audio/ empty.
    private func attachSongFromDialog(dialog: AgentDialog, result: AgentDialogResult) {
        guard let editor, let workingRoot = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: workingRoot),
              let src = result.fileURLs.first
        else {
            send(text: Self.chatMessage(from: dialog, result: result), mentions: [])
            return
        }
        guard AudioProjectLayout.audioExtensions.contains(src.pathExtension.lowercased()) else {
            send(text: "That isn't an audio file — the song must be .wav / .mp3 / .m4a / .aiff / .flac / .aac.", mentions: [])
            return
        }
        let audioDir = dataRoot.appendingPathComponent("audio", isDirectory: true)
        let dest = audioDir.appendingPathComponent(src.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
            if src.standardizedFileURL != dest.standardizedFileURL {
                // Stage next to the destination, then swap in — a failed copy never destroys an existing
                // same-named song (copy-before-delete).
                let staging = audioDir.appendingPathComponent(".song-\(UUID().uuidString).\(src.pathExtension)")
                try FileManager.default.copyItem(at: src, to: staging)
                if FileManager.default.fileExists(atPath: dest.path) {
                    _ = try FileManager.default.replaceItemAt(dest, withItemAt: staging)
                } else {
                    try FileManager.default.moveItem(at: staging, to: dest)
                }
            }
            // One-song contract: retire any OTHER audio file only after the new one is safely in place.
            for other in AudioProjectLayout.songFiles(dataRoot: dataRoot)
            where other.lastPathComponent != dest.lastPathComponent {
                try? FileManager.default.removeItem(at: other)
            }
        } catch {
            send(text: "Couldn't place the song in audio/: \(error.localizedDescription).", mentions: [])
            return
        }
        editor.onPipelineChanged?()
        anchorSongOnTimeline(dest, editor: editor)
        send(text: "Song placed in audio/ (\(src.lastPathComponent)). Now run run_phase(\"analysis\") to measure it.", mentions: [])
    }

    /// Put the song on the timeline the moment it arrives. It is the project's spine — every cut keys
    /// to its beats — so an empty timeline until the final assembly leaves the user unable to hear or
    /// scrub the one thing the whole project is built around. `assemble_timeline` reuses this exact
    /// asset and skips its own placement when the anchor is already at frame 0.
    func anchorSongOnTimeline(_ fileURL: URL, editor: EditorViewModel) {
        let target = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let existing = editor.mediaAssets.first {
            $0.url.standardizedFileURL.resolvingSymlinksInPath() == target
        }
        guard let asset = existing ?? editor.addMediaAsset(from: fileURL) else { return }
        Task { @MainActor in
            // Duration comes from the file, not the analysis — the anchor must not wait for a phase
            // that may not run for a while.
            if asset.duration <= 0 { await asset.loadMetadata() }
            guard asset.duration > 0 else { return }
            let anchored = editor.timeline.tracks.contains { track in
                track.type == .audio && track.clips.contains { $0.mediaRef == asset.id && $0.startFrame == 0 }
            }
            guard !anchored else { return }
            let trackIndex = editor.timeline.tracks.firstIndex { $0.type == .audio }
                ?? editor.insertTrack(at: editor.timeline.tracks.count, type: .audio)
            let frames = max(1, Int((asset.duration * Double(editor.timeline.fps)).rounded()))
            _ = editor.placeClip(
                asset: asset, trackIndex: trackIndex, startFrame: 0,
                durationFrames: frames, addLinkedAudio: false)
        }
    }

    /// Copy loose style-reference images into the project's `import/` — a brownfield look source the
    /// production-design agent (K2) curates. No name: these are unstructured mood/style refs.
    private func attachStyleRefs(dialog: AgentDialog, result: AgentDialogResult) {
        guard let editor, let workingRoot = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: workingRoot)
        else {
            send(text: Self.chatMessage(from: dialog, result: result), mentions: [])
            return
        }
        guard !result.fileURLs.isEmpty else {
            send(text: "No style references provided — skipped. Proceed; production-design can develop the look from the brief.", mentions: [])
            return
        }
        let dir = dataRoot.appendingPathComponent("import", isDirectory: true)
        let copied: [String]
        do { copied = try Self.copyFilesUniquely(result.fileURLs, into: dir) }
        catch {
            send(text: "Couldn't attach the style references: \(error.localizedDescription).", mentions: [])
            return
        }
        editor.onPipelineChanged?()
        send(text: "\(copied.count) style reference\(copied.count == 1 ? "" : "s") attached in import/. "
            + "The production-design agent (K2) curates these as the style source.", mentions: [])
    }

    /// Copy files into `dir` (copy, never move), choosing a free name for each so nothing is ever
    /// overwritten — collisions with files ALREADY in `dir` (e.g. a reference from an earlier session)
    /// and within this batch both get a `-2`/`-3` suffix. A file already sitting at its destination is
    /// kept as-is. Returns the destination names. One routine for every image intake.
    nonisolated static func copyFilesUniquely(_ urls: [URL], into dir: URL) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var used = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        var copied: [String] = []
        for src in urls {
            let inPlace = dir.appendingPathComponent(src.lastPathComponent)
            if src.standardizedFileURL == inPlace.standardizedFileURL {
                used.insert(src.lastPathComponent)
                copied.append(src.lastPathComponent)
                continue
            }
            let ext = src.pathExtension
            let base = src.deletingPathExtension().lastPathComponent
            var name = src.lastPathComponent
            var n = 2
            while used.contains(name) {
                name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
                n += 1
            }
            used.insert(name)
            try fm.copyItem(at: src, to: dir.appendingPathComponent(name))
            copied.append(name)
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

    /// Import a file-intake dialog's dropped/picked files as media assets, so the answer reaches the
    /// agent as @mentioned assets it references by id (e.g. `attach_song media:`) — never a typed
    /// path. Mirrors the composer's paperclip/drag path (`addMediaAsset` + a mention).
    private func importDialogFiles(_ urls: [URL]) -> [AgentMention] {
        guard let editor, !urls.isEmpty else { return [] }
        var mentions: [AgentMention] = []
        for url in urls {
            guard let asset = editor.addMediaAsset(from: url) else { continue }
            let displayName = Self.disambiguatedMentionName(for: asset, existing: mentions)
            mentions.append(AgentMention(displayName: displayName, mediaRef: asset.id, type: asset.type))
        }
        return mentions
    }

    /// Sink for a `.generationIntent` dialog's composed intent, set by the surface that owns the
    /// generation (e.g. the music tab). When unset the intent is composed into a chat message so the
    /// answer is never dropped.
    var onGenerationDialogIntent: (@MainActor (String) -> Void)?

    /// The structured chat-message form of a dialog answer — labeled sections, free-text direction,
    /// and any files the user brought in (as @mention tokens so `send` carries them as real mentions).
    private static func chatMessage(from dialog: AgentDialog, result: AgentDialogResult,
                                    attached: [AgentMention] = []) -> String {
        var parts: [String] = []
        for section in dialog.sections {
            let picked = result.values(section.id)  // includes the section's "Other…" text
            if !picked.isEmpty { parts.append("\(section.label): \(picked.joined(separator: ", "))") }
            if case .toggle = section.kind {
                parts.append("\(section.label): \((result.toggles[section.id] ?? false) ? "yes" : "no")")
            }
        }
        var line = "Dialog \u{201C}\(dialog.title)\u{201D} \u{2014} " + (parts.isEmpty ? "confirmed" : parts.joined(separator: "; "))
        if !result.direction.isEmpty { line += ". Direction: \(result.direction)" }
        if !attached.isEmpty {
            let tokens = attached.map { "@\($0.displayName)" }.joined(separator: " ")
            line += ". Attached \(attached.count == 1 ? "file" : "files"): \(tokens)"
        }
        return line
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
        pendingDialog = nil
        if let dialog, dialog.purpose == .chatClarification {
            send(text: "Dismissed the \u{201C}\(dialog.title)\u{201D} dialog without answering — ask in prose or move on.", mentions: [])
        }
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
