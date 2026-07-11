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
                        accent: editor.activePackAccentColor ?? AppTheme.Accent.primary,
                        // Route through the ONE shared handler (audit #3). It dispatches on the
                        // dialog's `.generationIntent` purpose to the intent sink installed below.
                        onSubmit: { result in
                            genDialog = nil
                            dialogPreselected = [:]
                            editor.agentService.submitDialog(dialog, result: result)
                        },
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
        installGenerationSink(model: model)
        genDialog = Self.makeMusicDialog(model: model)
        dialogPreselected = ["mood": [moodId]]
    }

    private func generate() {
        banner = nil
        guard let model else { return }
        // Text mode with no direction → enter the generative flow: shape the music with the dialog
        // instead of firing a silent, under-specified render.
        if isTextMode, trimmedPrompt.isEmpty {
            installGenerationSink(model: model)
            genDialog = Self.makeMusicDialog(model: model)
            dialogPreselected = [:]
            return
        }
        performGenerate(intent: trimmedPrompt.isEmpty ? nil : trimmedPrompt, model: model)
    }

    /// Install the shared generation-dialog sink for the current model: the ONE handler on
    /// AgentService composes the dialog answer into an intent and calls back here, which runs the
    /// unified controller. Set when a shaping dialog opens so it captures the current model.
    private func installGenerationSink(model: AudioModelConfig) {
        editor.agentService.onGenerationDialogIntent = { intent in
            let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            prompt = trimmed
            performGenerate(intent: trimmed, model: model)
        }
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
            textField: AgentDialog.DialogTextField(placeholder: "Anything specific (instruments, reference, mood)…", multiline: false),
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
            ],
            purpose: .generationIntent
        )
    }

    /// Build a `GenerationRequest` and hand it to the shared controller (#114). Panel input is intent,
    /// never a raw model prompt: the controller composes it (locked ledger directives merged, engine
    /// linter gated) and drives `MusicGenerationSubmission` — which places the clip on the timeline.
    /// Success/failure/phase flow back through the callbacks and render as the Banner + spinner.
    private func performGenerate(intent: String?, model: AudioModelConfig) {
        let source: EditorViewModel.TimelineSpan
        let span: Double
        if isTextMode {
            let frameCount = max(1, Int(textDuration * Double(max(1, editor.timeline.fps))))
            source = .init(startFrame: textPlacementFrame, frameCount: frameCount)
            span = textDuration
        } else {
            guard let videoSource = self.source else { return }
            source = videoSource
            span = spanSeconds
        }
        let mode: MusicGenerationSubmission.Mode = isTextMode ? .textToMusic : .videoToMusic

        isGenerating = true
        banner = nil
        generatingLabel = (isTextMode ? MusicGenerationSubmission.Phase.generating : .exporting).label

        let request = GenerationRequest(
            modality: .music, modelId: model.id, intent: intent ?? "",
            durationSeconds: span,
            placement: .timelineAt(startFrame: source.startFrame, spanSeconds: span, actionName: "Add Music"),
            origin: .panel,
            submission: .music(make: { compiled in
                MusicGenerationSubmission(
                    mode: mode, model: model, prompt: compiled.isEmpty ? nil : compiled,
                    intent: intent, source: source, spanSeconds: span, name: nil)
            }))
        // Composition reads the ledger off the main thread (async); await the outcome and surface a
        // compile/preflight failure (nothing was submitted) as the error Banner.
        Task { @MainActor in
            let outcome = await GenerationController.submit(
                request, editor: editor,
                musicProgress: .init(
                    onPhase: { generatingLabel = $0.label },
                    onFinished: { isGenerating = false }),
                onSuccess: { _ in
                    // Audio lands on an audio track below the fold — say so, and it's already selected
                    // on the timeline so the eye can find it.
                    banner = .init(text: "Music added on an audio track — selected on the timeline.", kind: .success)
                })
            if case .failure(let error) = outcome {
                isGenerating = false
                banner = .init(text: error.errorDescription ?? "Generation failed.", kind: .error)
            }
        }
    }
}
