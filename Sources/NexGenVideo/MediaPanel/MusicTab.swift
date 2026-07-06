import SwiftUI

struct MusicTab: View {
    @Environment(EditorViewModel.self) var editor

    @State private var selectedModelId: String?
    @State private var mode: MusicGenerationSubmission.Mode = .videoToMusic
    @State private var prompt: String = ""
    @State private var textDuration: Double = 90
    @State private var isGenerating = false
    @State private var generatingLabel = "Generating..."
    /// Runtime feedback distinct from the calm validation guidance below the field: a failed render
    /// (error) or a finished one (success). Auto-clears; never shown in alarm-red for a mere "not
    /// ready yet" state.
    @State private var banner: Banner?
    /// The generative shaping dialog (#96): opened when the intent is too thin to compile, so the
    /// user shapes mood/character with clicks — the panel path enters the same generative flow the
    /// agent uses, never a silent render.
    @State private var genDialog: AgentDialog?
    /// Seeds genDialog's mood section when opened from the Mood submenu.
    @State private var dialogPreselected: [String: Set<String>] = [:]

    private struct Banner: Equatable { let text: String; let kind: Kind; enum Kind { case success, error } }

    // Every music model belongs here — filtering on a video input hid text-to-music models
    // entirely and showed "No music models available" although the catalog had them.
    private var models: [AudioModelConfig] {
        AudioModelConfig.allModels.filter { $0.category == .music }
    }

    private var model: AudioModelConfig? {
        if let id = selectedModelId, let m = models.first(where: { $0.id == id }) { return m }
        return models.first
    }

    private func supportsTextMode(_ m: AudioModelConfig) -> Bool {
        m.category == .music && m.inputs.contains(.text)
    }

    private func supportsVideoMode(_ m: AudioModelConfig) -> Bool {
        m.inputs.contains(.video)
    }

    /// The chosen mode, clamped to what the selected model can actually do.
    private var effectiveMode: MusicGenerationSubmission.Mode {
        guard let model else { return mode }
        if mode == .videoToMusic, !supportsVideoMode(model) { return .textToMusic }
        if mode == .textToMusic, !supportsTextMode(model) { return .videoToMusic }
        return mode
    }
    private var isTextMode: Bool { effectiveMode == .textToMusic }

    private var source: EditorViewModel.TimelineSpan? { editor.selectedTimelineSpan() }

    private var spanSeconds: Double {
        guard let source else { return 0 }
        return Double(source.frameCount) / Double(max(1, editor.timeline.fps))
    }

    /// Where a text-to-music clip lands: the marked range start, else the playhead.
    private var textPlacementFrame: Int {
        editor.validSelectedTimelineRange?.startFrame ?? editor.currentFrame
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var costDuration: Int {
        isTextMode ? Int(textDuration.rounded()) : Int(spanSeconds.rounded())
    }

    private var estimatedCost: Int? {
        guard let model, costDuration > 0 else { return nil }
        return CostEstimator.audioCost(model: model, prompt: trimmedPrompt, durationSeconds: costDuration)
    }

    private var validationNote: String? {
        guard let model else { return "No music models available." }
        if isTextMode {
            if trimmedPrompt.isEmpty { return "Describe the music — or tap Generate to shape it." }
        } else {
            guard source != nil else {
                return "Add video to the timeline, then mark a range to score only part of it."
            }
            if let issue = model.validate(spanSeconds: spanSeconds) { return issue }
        }
        return nil
    }

    private var canGenerate: Bool {
        guard let model, !isGenerating else { return false }
        // Text mode is always actionable: an empty intent opens the generative shaping dialog
        // rather than blocking. Video mode still needs a valid source span.
        if isTextMode { return true }
        return source != nil && model.validate(spanSeconds: spanSeconds) == nil
    }

    private var generateLabel: String {
        if let cost = estimatedCost, cost > 0 { return "Generate · \(CostEstimator.format(cost))" }
        return "Generate"
    }

    private var sourceSummary: String {
        guard let source else { return "No video" }
        let scope = editor.validSelectedTimelineRange != nil ? "" : "Whole timeline · "
        return "\(scope)\(clock(source.startFrame)) – \(clock(source.startFrame + source.frameCount)) · \(String(format: "%.1fs", spanSeconds))"
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
                        sourceSection
                        modelSection
                        promptSection
                    }
                    .padding(.horizontal, AppTheme.Spacing.lgXl)
                    .padding(.top, AppTheme.Spacing.md)
                    .padding(.bottom, AppTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if let dialog = genDialog {
                    AgentDialogCard(
                        dialog: dialog,
                        preselected: dialogPreselected,
                        onSubmit: { result in runGeneration(from: result) },
                        onCancel: { genDialog = nil; dialogPreselected = [:] }
                    )
                    .padding(.bottom, AppTheme.Spacing.sm)
                }
                generateBar
            }
            if isGenerating {
                AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                GeneratingOverlay(label: generatingLabel, size: .preview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
    }

    private var sourceSection: some View {
        InspectorSection("Source") {
            if let model, supportsTextMode(model), supportsVideoMode(model) {
                InspectorRow(icon: "slider.horizontal.3", label: "Input") {
                    Menu {
                        Button("Video to Music") { mode = .videoToMusic }
                        Button("Text to Music") { mode = .textToMusic }
                    } label: { menuValueLabel(modeLabel(effectiveMode)) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
                }
            }
            if isTextMode {
                InspectorRow(
                    icon: "clock",
                    label: "Duration",
                    labelHelp: "Length of the generated music. It's placed at the playhead, or at the marked range start."
                ) {
                    ScrubbableNumberField(
                        value: textDuration,
                        range: Double(model?.minSeconds ?? 1)...Double(model?.maxSeconds ?? 600),
                        format: "%.0f",
                        valueSuffix: " s",
                        onChanged: { textDuration = $0 }
                    ) { textDuration = $0 }
                }
            } else {
                InspectorRow(
                    icon: "film",
                    label: "Video",
                    labelHelp: "Uses the whole timeline by default. Mark a range on the timeline to score only that span."
                ) { valueText(sourceSummary) }
            }
        }
    }

    private func modeLabel(_ m: MusicGenerationSubmission.Mode) -> String {
        switch m {
        case .videoToMusic: "Video to Music"
        case .textToMusic: "Text to Music"
        }
    }

    private func menuValueLabel(_ text: String) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: AppTheme.FontSize.xxs))
        }
        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
        .foregroundStyle(AppTheme.Text.tertiaryColor)
        .lineLimit(1)
    }

    private var modelSection: some View {
        InspectorSection("Model") {
            InspectorRow(icon: "music.note", label: "Model") {
                Menu {
                    ForEach(models, id: \.id) { m in
                        Button(m.displayName) { selectedModelId = m.id }
                    }
                } label: {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Text(model?.displayName ?? "None")
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: AppTheme.FontSize.xxs))
                    }
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
            }
        }
    }

    private var promptSection: some View {
        InspectorSection("Direction") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                TextField("Mood, genre, energy, instruments…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...5)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .padding(AppTheme.Spacing.smMd)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(AppTheme.Background.raisedColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                    )
                // Names the contract: this is intent, not the literal model prompt — NexGenVideo
                // compiles it (translate, context, model dialect) before anything is generated.
                Text("NexGenVideo writes the model prompt from this.")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
    }

    private var generateBar: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            if let banner {
                Text(banner.text)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(banner.kind == .error ? AppTheme.Status.errorColor : AppTheme.Status.successColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let guidance = validationNote {
                // Calm guidance, not an error — an empty field is "not ready yet", not a failure.
                Text(guidance)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Button(action: generate) {
                    Text(generateLabel)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Background.baseColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.smMd)
                        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Accent.primary))
                        .opacity(canGenerate ? AppTheme.Opacity.opaque : AppTheme.Opacity.medium)
                }
                .buttonStyle(.plain).focusable(false)
                .disabled(!canGenerate)

                agentMenu
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
        .overlay(alignment: .top) {
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .lineLimit(1)
    }

    private func clock(_ frame: Int) -> String {
        let total = Double(frame) / Double(max(1, editor.timeline.fps))
        let m = Int(total) / 60
        let s = Int(total) % 60
        return String(format: "%d:%02d", m, s)
    }

    private var agentMenu: some View {
        Menu {
            Button {
                mode = .videoToMusic
            } label: { Label("Generate music for the timeline", systemImage: "music.note") }
            Menu {
                ForEach(Self.moodMenuOptions, id: \.id) { option in
                    Button(option.label) { openMoodDialog(preselecting: option.id) }
                }
            } label: { Label("Mood", systemImage: "slider.horizontal.3") }
            Divider()
            Button {
                editor.agentService.prefillInput("")
            } label: { Label("Ask the agent…", systemImage: "bubble.left.and.text.bubble.right") }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("Agent Mode")
                Image(systemName: "chevron.down").font(.system(size: AppTheme.FontSize.xs))
            }
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(AppTheme.aiGradient)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.raisedColor))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(AppTheme.aiGradient.opacity(AppTheme.Opacity.medium), lineWidth: AppTheme.BorderWidth.thin))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
        .help("Let Agent generate music for you. Choose a starter, or ask Agent in the chat.")
    }

    // Mirrors the mood chip ids in makeMusicDialog's "mood" section.
    private static let moodMenuOptions: [(id: String, label: String)] = [
        ("cinematic", "Cinematic"), ("upbeat", "Upbeat"), ("ambient", "Ambient"),
        ("tense", "Tense"), ("lofi", "Lo-fi"),
    ]

    /// Opens the existing shaping dialog with a mood preselected — clicks compose the intent,
    /// never canned prose handed to the agent.
    private func openMoodDialog(preselecting moodId: String) {
        guard let model else { return }
        genDialog = Self.makeMusicDialog(model: model)
        dialogPreselected = ["mood": [moodId]]
    }

    private func generate() {
        banner = nil
        guard let model else { return }
        // Text mode with no direction → enter the generative flow: shape the music with the dialog
        // instead of firing a silent, under-specified render.
        if isTextMode, trimmedPrompt.isEmpty {
            genDialog = Self.makeMusicDialog(model: model)
            dialogPreselected = [:]
            return
        }
        compileAndGenerate(intent: trimmedPrompt.isEmpty ? nil : trimmedPrompt, model: model)
    }

    /// Deterministic prompt gate (#100), then submit. Panel input is intent, never a raw model
    /// prompt: locked ledger directives fold in and model limits are enforced before any provider.
    private func compileAndGenerate(intent: String?, model: AudioModelConfig) {
        guard let intent else { performGenerate(compiledPrompt: nil); return }
        Task { @MainActor in
            do {
                let compiled = try await PromptCompiler.compile(intent: intent, modelId: model.id, editor: editor)
                performGenerate(compiledPrompt: compiled.text)
            } catch let toolError as ToolError {
                banner = .init(text: toolError.message, kind: .error)
            } catch {
                banner = .init(text: error.localizedDescription, kind: .error)
            }
        }
    }

    /// The generative shaping dialog result (chips + free-text direction) becomes the intent, then
    /// runs the same compile→generate path. This is the panel entering the generative process.
    private func runGeneration(from result: AgentDialogResult) {
        guard let model else { return }
        genDialog = nil
        dialogPreselected = [:]
        var parts = result.labels("mood") + result.labels("character")
        if !result.direction.isEmpty { parts.append(result.direction) }
        let intent = parts.joined(separator: ", ")
        guard !intent.isEmpty else { return }
        prompt = intent
        compileAndGenerate(intent: intent, model: model)
    }

    /// A music-shaping dialog seeded for the current model — mood (single) + character (multi) as
    /// chips, plus a free-text direction. Length stays a first-class field in the panel above.
    private static func makeMusicDialog(model: AudioModelConfig) -> AgentDialog {
        AgentDialog(
            id: UUID().uuidString,
            title: "Shape the music",
            symbol: "music.note",
            intro: "Pick a direction, or type your own — NexGenVideo writes the model prompt.",
            costHint: nil,
            confirmLabel: "Generate",
            textPlaceholder: "Anything specific (instruments, reference, mood)…",
            sections: [
                AgentDialog.Section(id: "mood", label: "Mood", kind: .choices(options: [
                    .init(id: "cinematic", label: "Cinematic", symbol: "film"),
                    .init(id: "upbeat", label: "Upbeat", symbol: "bolt.fill"),
                    .init(id: "ambient", label: "Ambient", symbol: "waveform"),
                    .init(id: "tense", label: "Tense", symbol: "exclamationmark.triangle"),
                    .init(id: "lofi", label: "Lo-fi", symbol: "dial.low"),
                    .init(id: "melancholic", label: "Melancholic", symbol: "cloud.rain"),
                ], multiSelect: false)),
                AgentDialog.Section(id: "character", label: "Character", kind: .choices(options: [
                    .init(id: "driving", label: "Driving", symbol: "gauge.high"),
                    .init(id: "sparse", label: "Sparse", symbol: "circle.dotted"),
                    .init(id: "warm", label: "Warm", symbol: "sun.max"),
                    .init(id: "dark", label: "Dark", symbol: "moon.fill"),
                    .init(id: "playful", label: "Playful", symbol: "sparkles"),
                ], multiSelect: true)),
            ]
        )
    }

    private func performGenerate(compiledPrompt: String?) {
        guard let model else { return }
        let trimmed = compiledPrompt
        let submission: MusicGenerationSubmission
        if isTextMode {
            let frameCount = max(1, Int(textDuration * Double(max(1, editor.timeline.fps))))
            submission = MusicGenerationSubmission(
                mode: .textToMusic, model: model, prompt: trimmed,
                source: .init(startFrame: textPlacementFrame, frameCount: frameCount),
                spanSeconds: textDuration, name: nil
            )
        } else {
            guard let source else { return }
            submission = MusicGenerationSubmission(
                mode: .videoToMusic, model: model, prompt: trimmed,
                source: source, spanSeconds: spanSeconds, name: nil
            )
        }

        isGenerating = true
        banner = nil
        generatingLabel = (isTextMode ? MusicGenerationSubmission.Phase.generating : .exporting).label
        Task {
            do {
                try await submission.run(
                    service: editor.generationService,
                    projectURL: editor.projectURL,
                    editor: editor,
                    onPhase: { generatingLabel = $0.label },
                    onFinished: { isGenerating = false },
                    onSucceeded: {
                        // Audio lands on an audio track below the fold — say so, and it's already
                        // selected on the timeline so the eye can find it.
                        banner = .init(text: "Music added on an audio track — selected on the timeline.", kind: .success)
                    }
                )
            } catch {
                banner = .init(text: error.localizedDescription, kind: .error)
                isGenerating = false
            }
        }
    }
}
