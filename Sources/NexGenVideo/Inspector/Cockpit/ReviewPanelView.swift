import SwiftUI

// The frames review gallery (docs/UI_UX_CONCEPT.md §4, ladder rung 2): per shot, the generated
// candidates as tiles with two structured decisions — Use (select as keyframe) and Redo with a
// reason chip + optional note. Both compose a structured agent command; the agent runs the pipeline
// work and the Agent tab opens to show it. Read-only against `read frames`; no state is invented.

struct ReviewPanelView: View {
    @Environment(EditorViewModel.self) private var editor

    private enum LoadState: Equatable {
        case idle
        case loading
        case loaded(FramesData?)
        case failed(CockpitError)
    }

    /// Reject reasons (concept §4) — a cheap structured "why", so a regeneration isn't a lottery.
    enum ReviewReason: String, CaseIterable, Identifiable {
        case continuity = "Continuity"
        case performance = "Performance"
        case style = "Style"
        case composition = "Composition"
        case promptDrift = "Prompt-Drift"
        case technical = "Technical"
        var id: String { rawValue }
    }

    private struct RedoTarget: Identifiable {
        let shotId: String
        let frameName: String
        var id: String { "\(shotId)/\(frameName)" }
    }

    @State private var state: LoadState = .idle
    @State private var loadToken = 0
    @State private var redoTarget: RedoTarget?
    @State private var redoReason: ReviewReason = .continuity
    @State private var redoNote = ""
    /// Remix selection per shot: candidate names marked as sources for a combined regeneration.
    @State private var remixSelection: [String: Set<String>] = [:]
    @State private var remixShot: String?
    @State private var remixTakes: [String: String] = [:]
    @State private var remixTakesShot: String?
    @State private var remixNote = ""

    var body: some View {
        layout
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task(id: editor.projectURL) { await load() }
            .onChange(of: editor.engineStateRevision) { _, _ in
                Task { await load() }
            }
    }

    @ViewBuilder
    private var layout: some View {
        if case .failed(.notInitialized) = state {
            // No pipeline yet: the whole pane is one "Start production" call to action. Stacking the
            // Sanity strip below would render a second, identical "No production pipeline" block —
            // Sanity has nothing to gate before a shotlist exists — a doubled, half-clipped message.
            content
        } else {
            VStack(spacing: AppTheme.Spacing.none) {
                content
                    .frame(minHeight: AppTheme.Spacing.none)
                    .clipped()
                AppDivider()
                // Sanity lives here in EVERY pipeline state — findings gate progress before frames
                // even exist (§3: no panel is ever locked away). Fixed height: predictable galleries.
                SanityPanelView()
                    .frame(height: AppTheme.ComponentSize.reviewSanityStripHeight)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            CockpitStateView.error(error, title: "Couldn't load frames",
                                   subject: "the frames",
                                   activePack: InstalledPack.named(editor.activePluginName),
                                   startProduction: { editor.startProduction() },
                                   isStarting: editor.productionStarted) { Task { await load() } }
        case .loaded(let data):
            if let data, !data.shots.isEmpty {
                loadedBody(data)
            } else {
                CockpitStateView.empty(icon: "photo.on.rectangle.angled", title: "Nothing to review",
                                       message: "The frames phase hasn't produced candidates yet.")
            }
        }
    }

    private func loadedBody(_ data: FramesData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                ForEach(data.shots) { shot in
                    shotSection(shot)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Shot section

    private func shotSection(_ shot: FrameShot) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Button {
                    editor.inspectedObject = .shot(shot.shotId)
                } label: {
                    Text(shot.shotId)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold).monospaced())
                        .foregroundStyle(AppTheme.Text.primaryColor)
                }
                .buttonStyle(.plain)
                .help("Inspect this shot")
                if let status = shot.auditStatus, !status.isEmpty {
                    Text("audit: \(status)")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(status == "pass" ? AppTheme.Status.successColor : AppTheme.Status.errorColor)
                }
                Spacer(minLength: 0)
                if let picked = remixSelection[shot.shotId], !picked.isEmpty {
                    Text("\(picked.count) picked")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Button("Clear") { remixSelection[shot.shotId] = [] }
                        .controlSize(.small)
                }
                if (remixSelection[shot.shotId]?.count ?? 0) >= 2 {
                    Button("Remix…") {
                        // Reset only when switching shots — reopening the popover keeps typed takes.
                        if remixTakesShot != shot.shotId {
                            remixTakes = [:]
                            remixNote = ""
                            remixTakesShot = shot.shotId
                        }
                        remixShot = shot.shotId
                    }
                    .controlSize(.small)
                    .popover(isPresented: remixPopoverBinding(shot.shotId)) {
                        remixPopover(shot.shotId)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
                    ForEach(shot.frames) { frame in
                        frameTile(frame, shotId: shot.shotId)
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private func frameTile(_ frame: FrameCandidate, shotId: String) -> some View {
        let isPicked = remixSelection[shotId]?.contains(frame.name) == true
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            SheetThumbnailView(
                label: frame.name,
                path: frame.path,
                projectDir: editor.workingRoot,
                tileHeight: 90
            )
            .overlay(alignment: .topTrailing) {
                if isPicked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Accent.primary)
                        .padding(AppTheme.Spacing.xxs)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Tap picks the tile as a remix source ("composition of 2 + lighting of 4").
                var set = remixSelection[shotId] ?? []
                if !set.insert(frame.name).inserted { set.remove(frame.name) }
                remixSelection[shotId] = set
            }
            HStack(spacing: AppTheme.Spacing.xs) {
                Button("Use") { accept(frame, shotId: shotId) }
                    .controlSize(.small)
                Button("Redo…") {
                    redoReason = .continuity
                    redoNote = ""
                    redoTarget = RedoTarget(shotId: shotId, frameName: frame.name)
                }
                .controlSize(.small)
            }
        }
        .frame(width: AppTheme.ComponentSize.reviewThumbnailWidth)
        .popover(item: bindingRedoTarget(matching: frame, shotId: shotId)) { target in
            redoPopover(target)
        }
    }

    /// Per-tile popover anchoring: only the tile that opened the popover presents it.
    private func bindingRedoTarget(matching frame: FrameCandidate, shotId: String) -> Binding<RedoTarget?> {
        Binding(
            get: {
                guard let t = redoTarget, t.shotId == shotId, t.frameName == frame.name else { return nil }
                return t
            },
            set: { newValue in
                if let newValue {
                    redoTarget = newValue
                } else if redoTarget?.shotId == shotId, redoTarget?.frameName == frame.name {
                    // A dismissing popover may fire after ANOTHER one opened — only clear our own.
                    redoTarget = nil
                }
            }
        )
    }

    // MARK: - Decisions → structured agent commands

    private func redoPopover(_ target: RedoTarget) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Why regenerate?")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], alignment: .leading, spacing: AppTheme.Spacing.xs) {
                ForEach(ReviewReason.allCases) { reason in
                    let selected = redoReason == reason
                    Button {
                        redoReason = reason
                    } label: {
                        Text(reason.rawValue)
                            .font(.system(size: AppTheme.FontSize.xs, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                            .padding(.horizontal, AppTheme.Spacing.sm)
                            .padding(.vertical, AppTheme.Spacing.xxs)
                            .background {
                                Capsule().fill(selected ? AppTheme.Background.surfaceColor : AppTheme.Background.clearColor)
                            }
                            .overlay(Capsule().strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("Optional note…", text: $redoNote)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm))
            HStack {
                Spacer()
                Button("Regenerate") { regenerate(target) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(width: AppTheme.ComponentSize.reviewRedoPopoverWidth)
    }

    private func remixPopoverBinding(_ shotId: String) -> Binding<Bool> {
        Binding(
            get: { remixShot == shotId },
            // A dismissing popover may fire after ANOTHER one opened — only clear our own state.
            set: { if !$0, remixShot == shotId { remixShot = nil } }
        )
    }

    private func remixPopover(_ shotId: String) -> some View {
        let picked = (remixSelection[shotId] ?? []).sorted()
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("What to take from each")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            ForEach(picked, id: \.self) { name in
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(name)
                        .font(.system(size: AppTheme.FontSize.xxs).monospaced())
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                        .frame(width: AppTheme.ComponentSize.reviewSourceLabelWidth, alignment: .leading)
                    TextField("composition, lighting, …", text: Binding(
                        get: { remixTakes[name] ?? "" },
                        set: { remixTakes[name] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppTheme.FontSize.sm))
                }
            }
            TextField("Optional note…", text: $remixNote)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm))
            HStack {
                Spacer()
                Button("Remix") { remix(shotId, picked: picked) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.allSatisfy { (remixTakes[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(width: AppTheme.ComponentSize.reviewRemixPopoverWidth)
    }

    private func remix(_ shotId: String, picked: [String]) {
        // Every picked candidate travels — with its "take" when given, as a general reference
        // otherwise. Dropping a pick silently would lose the combine intent (§4 rung 2).
        let parts = picked.map { name -> String in
            let take = (remixTakes[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return take.isEmpty
                ? "\u{201C}\(name)\u{201D}: general reference"
                : "\u{201C}\(name)\u{201D}: \(take)"
        }
        var command = "Remix the keyframe for shot \(shotId), combining these candidates — "
            + parts.joined(separator: "; ")
            + ". Use them as reference images for the stated aspects."
        let note = remixNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { command += " Note: \(note)" }
        remixShot = nil
        remixSelection[shotId] = []
        remixTakes = [:]
        remixTakesShot = nil
        remixNote = ""
        send(AgentControlTurn(
            command: command,
            selections: [
                .init(label: "Action", values: ["Remix"]),
                .init(label: "Shot", values: [shotId]),
                .init(label: "Frames", values: picked),
            ],
            typedText: note
        ))
    }

    private func accept(_ frame: FrameCandidate, shotId: String) {
        send(Self.acceptTurn(frameName: frame.name, shotId: shotId))
    }

    private func regenerate(_ target: RedoTarget) {
        let note = redoNote.trimmingCharacters(in: .whitespacesAndNewlines)
        var command = "Regenerate the keyframe for shot \(target.shotId) "
            + "(rejected candidate: \u{201C}\(target.frameName)\u{201D}). Reason: \(redoReason.rawValue)."
        if !note.isEmpty { command += " Note: \(note)" }
        redoTarget = nil
        send(Self.regenerateTurn(
            command: command,
            frameName: target.frameName,
            shotId: target.shotId,
            reason: redoReason.rawValue,
            note: note
        ))
    }

    static func acceptTurn(frameName: String, shotId: String) -> AgentControlTurn {
        AgentControlTurn(
            command: "For shot \(shotId), use the frame candidate \u{201C}\(frameName)\u{201D} as the selected keyframe.",
            selections: [
                .init(label: "Keyframe", values: [frameName]),
                .init(label: "Shot", values: [shotId]),
            ]
        )
    }

    static func regenerateTurn(
        command: String,
        frameName: String,
        shotId: String,
        reason: String,
        note: String
    ) -> AgentControlTurn {
        AgentControlTurn(
            command: command,
            selections: [
                .init(label: "Action", values: ["Regenerate"]),
                .init(label: "Shot", values: [shotId]),
                .init(label: "Reason", values: [reason]),
                .init(label: "Frame", values: [frameName]),
            ],
            typedText: note
        )
    }

    private func send(_ turn: AgentControlTurn) {
        editor.agentService.send(controlTurn: turn)
        editor.agentPanelVisible = true
    }

    // MARK: - Load

    private func load() async {
        guard let dir = editor.workingRoot else {
            state = .failed(.noProject)
            return
        }
        loadToken += 1
        let token = loadToken
        // Silent when already populated: a post-agent-turn refresh must not dismiss open popovers
        // or drop the remix selection's visual context.
        if case .loaded = state {} else { state = .loading }
        let result = await CockpitDataService.frames(projectDir: dir)
        guard token == loadToken else { return }
        switch result {
        case .success(let data): state = .loaded(data)
        case .failure(let error): state = .failed(error)
        }
    }
}
