import SwiftUI

struct AIEditTab: View {
    let asset: MediaAsset
    /// Clip id from the timeline.
    let clipId: String?
    let services: GenerationPanelServices
    @Environment(EditorViewModel.self) private var editor
    @State private var rerunError: String?
    @State private var replaceClipSource: Bool = false
    @State private var useTrimmedClip: Bool = true
    @State private var placeAudioOnTimeline: Bool = true
    @State private var aiEnhanceExpanded: Bool = true
    @State private var aiAudioExpanded: Bool = true

    init(asset: MediaAsset, clipId: String? = nil, services: GenerationPanelServices = .live) {
        self.asset = asset
        self.clipId = clipId
        self.services = services
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                if clipId == nil, editor.workspaceFocus == .edit, asset.type.isPlaceable {
                    SourceRangeInspector(asset: asset)
                }
                if hasScopeToggles {
                    aiSection(title: "Scope") {
                        if clipId != nil { replaceToggle }
                        if trimmedClipAvailable { trimmedClipToggle }
                    }
                }

                collapsibleAISection(title: "AI Enhance", isExpanded: $aiEnhanceExpanded) {
                    actionRow(
                        action: .upscale,
                        icon: "sparkles.rectangle.stack",
                        title: "Upscale",
                        description: "Enhance resolution with AI"
                    )
                    actionRow(
                        action: .edit,
                        icon: "wand.and.stars",
                        title: "Edit",
                        description: "Transform with a prompt or motion reference"
                    )
                    actionRow(
                        action: .rerun,
                        icon: "arrow.clockwise",
                        title: "Rerun",
                        description: rerunDescription
                    )
                    if asset.type == .image {
                        actionRow(
                            action: .createVideo,
                            icon: "video.badge.plus",
                            title: "Create Video",
                            description: "Use as first frame or reference"
                        )
                    }
                }

                if asset.type == .video {
                    collapsibleAISection(title: "AI Audio", isExpanded: $aiAudioExpanded) {
                        if showsAudioOutputOptions {
                            audioPlacementToggle
                        }
                        videoAudioActionRow(kind: .music)
                        videoAudioActionRow(kind: .sfx)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Rerun failed", isPresented: Binding(
            get: { rerunError != nil },
            set: { if !$0 { rerunError = nil } }
        )) {
            Button("Dismiss") { rerunError = nil }
        } message: {
            Text(rerunError ?? "")
        }
    }

    private var hasScopeToggles: Bool {
        clipId != nil || trimmedClipAvailable
    }

    private var showsAudioOutputOptions: Bool {
        asset.type == .video && clipId != nil
    }

    private var rerunDescription: String {
        guard let gen = asset.generationInput,
              let cost = CostEstimator.cost(for: gen) else {
            return "Regenerate with the same parameters"
        }
        return "Regenerate · \(CostEstimator.format(cost))"
    }

    private func aiSection<Content: View>(
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        InspectorSection(title) {
            content()
        }
    }

    private func collapsibleAISection<Content: View>(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            InspectorSectionHeading(title: title, expanded: isExpanded.wrappedValue, onToggle: {
                withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                    isExpanded.wrappedValue.toggle()
                }
            })

            if isExpanded.wrappedValue {
                VStack(spacing: AppTheme.Spacing.smMd) {
                    content()
                }
            }
        }
    }

    // MARK: - Replace toggle

    private var replaceToggle: some View {
        scopeToggleRow(
            icon: "arrow.triangle.2.circlepath",
            label: "Replace clip source",
            help: "Swap the clip's media when generation completes. Speed, volume, trim, and transform are preserved.",
            isOn: $replaceClipSource
        )
    }

    // MARK: - Trimmed clip toggle

    private var trimmedClipToggle: some View {
        scopeToggleRow(
            icon: "scissors",
            label: "Use trimmed portion only",
            help: "Send only the visible clip range to the model, not the full source.",
            isOn: $useTrimmedClip
        )
    }

    private var audioPlacementToggle: some View {
        scopeToggleRow(
            icon: "plus.rectangle.on.rectangle",
            label: "Place on timeline",
            help: "Add generated audio to an audio track at this clip's start.",
            isOn: $placeAudioOnTimeline
        )
    }

    private func scopeToggleRow(
        icon: String,
        label: String,
        help: String,
        isOn: Binding<Bool>
    ) -> some View {
        InspectorFormRow(label: label, icon: icon, labelHelp: help) {
            Toggle(label, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .labelsHidden()
                .accessibilityLabel(label)
                .reviewAcceptanceProbe("ai-edit.scope." + label, text: isOn.wrappedValue ? "on" : "off")
        }
        .help(help)
    }

    private var timelineClip: Clip? {
        guard let clipId else { return nil }
        return editor.clipFor(id: clipId)
    }

    private var trimmedClipAvailable: Bool {
        guard asset.type == .video, let clip = timelineClip else { return false }
        return clip.trimStartFrame > 0 || clip.trimEndFrame > 0
    }

    private func trimmedSourceIfEnabled() -> TrimmedSource? {
        guard trimmedClipAvailable, useTrimmedClip, let clip = timelineClip else { return nil }
        return TrimmedSource(
            sourceURL: asset.url,
            trimStartFrame: clip.trimStartFrame,
            trimEndFrame: clip.trimEndFrame,
            sourceFramesConsumed: clip.sourceFramesConsumed,
            fps: editor.timeline.fps
        )
    }

    private var effectiveDurationForAvailability: Double? {
        trimmedSourceIfEnabled()?.durationSeconds
    }

    // MARK: - Action row

    @ViewBuilder
    private func actionRow(
        action: EditAction,
        icon: String,
        title: String,
        description: String,
        triggerTitle: String? = nil
    ) -> some View {
        let availability: EditActionAvailability = editor.isMediaOffline(asset.id) && action != .rerun
            ? .disabled(reason: "Relink the original media to use this action")
            : action.availability(for: asset, effectiveDurationOverride: effectiveDurationForAvailability, isModelRunnable: services.canRun)
        let isEnabled = availability.isAvailable
        let disabledReason = availability.reason

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                actionDescription(icon: icon, title: title, detail: disabledReason ?? description, enabled: isEnabled)
                Spacer(minLength: AppTheme.Spacing.sm)
                actionTrigger(action: action, title: triggerTitle ?? title, isEnabled: isEnabled)
            }
            .frame(minWidth: AppTheme.ComponentSize.inspectorActionInlineMinWidth)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                actionDescription(icon: icon, title: title, detail: disabledReason ?? description, enabled: isEnabled)
                actionTrigger(action: action, title: triggerTitle ?? title, isEnabled: isEnabled)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(disabledReason ?? "")
    }

    private func actionDescription(icon: String, title: String, detail: String, enabled: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(enabled ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
                .frame(width: AppTheme.IconSize.xs)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(title)
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                    .foregroundStyle(enabled ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                Text(detail)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(enabled ? AppTheme.Text.tertiaryColor : AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func videoAudioActionRow(kind: VideoToAudioEditKind) -> some View {
        actionRow(
            action: kind.action,
            icon: kind.iconName,
            title: kind.title,
            description: kind.description,
            triggerTitle: "Generate"
        )
    }

    @ViewBuilder
    private func actionTrigger(action: EditAction, title: String, isEnabled: Bool) -> some View {
        switch action {
        case .upscale:
            Menu {
                ForEach(services.upscaleSelections(for: asset, duration: effectiveDurationForAvailability)) { selection in
                    Button {
                        runUpscale(selection)
                    } label: {
                        Text(upscaleLabel(for: selection))
                    }
                }
            } label: { ActionMenuLabel(title: title) }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.capsule(.secondary))
            .disabled(!isEnabled)
            .reviewAcceptanceProbe("ai-edit." + String(describing: action), state: isEnabled)
        case .createVideo:
            Menu {
                Button("Set as first frame") { sendToVideo(asReference: false) }
                    .disabled(EditSubmitter.createVideoSeed(for: asset, asReference: false) == nil)
                Button("Set as reference") { sendToVideo(asReference: true) }
                    .disabled(EditSubmitter.createVideoSeed(for: asset, asReference: true) == nil)
            } label: { ActionMenuLabel(title: title) }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.capsule(.secondary))
            .disabled(!isEnabled)
            .reviewAcceptanceProbe("ai-edit." + String(describing: action), state: isEnabled)
        case .edit, .generateMusic, .generateSFX, .rerun:
            Button(title) {
                present(action)
            }
            .buttonStyle(.capsule(.secondary))
            .disabled(!isEnabled)
            .reviewAcceptanceProbe("ai-edit." + String(describing: action), state: isEnabled)
        }
    }

    private func sendToVideo(asReference: Bool) {
        guard let stored = EditSubmitter.createVideoSeed(for: asset, asReference: asReference) else { return }
        seedPanel(stored: stored, trimmed: nil)
    }

    private func present(_ action: EditAction) {
        switch action {
        case .upscale, .createVideo: break // handled via menu
        case .edit:
            guard let stored = EditSubmitter.editSeed(for: asset) else { return }
            seedPanel(stored: stored, trimmed: trimmedSourceIfEnabled())
        case .generateMusic:
            presentVideoAudio(kind: .music)
        case .generateSFX:
            presentVideoAudio(kind: .sfx)
        case .rerun:
            let modelId = asset.generationInput?.model ?? ""
            if UpscaleModelConfig.allIds.contains(modelId) {
                let replacement = replacementTarget()
                Task { @MainActor in
                    do {
                        _ = try await EditSubmitter.rerun(
                            asset: asset, editor: editor,
                            replacementTarget: replacement, services: services
                        )
                    } catch {
                        rerunError = error.localizedDescription
                    }
                }
            } else if let stored = asset.generationInput {
                seedPanel(stored: stored, trimmed: nil)
            }
        }
    }

    private func presentVideoAudio(kind: VideoToAudioEditKind) {
        guard let stored = EditSubmitter.videoAudioSeed(for: asset, kind: kind, effectiveDuration: effectiveDurationForAvailability) else { return }
        seedPanel(
            stored: stored,
            trimmed: trimmedSourceIfEnabled(),
            allowsReplacement: false,
            audioPlacement: pendingAudioPlacement(actionName: kind.timelineActionName)
        )
    }

    private func seedPanel(
        stored: GenerationInput,
        trimmed: TrimmedSource?,
        allowsReplacement: Bool = true,
        audioPlacement: PendingAudioPlacement? = nil
    ) {
        editor.seedGenerationPanel(
            asset: asset,
            stored: stored,
            replacementClipId: allowsReplacement && shouldReplace ? clipId : nil,
            trimmedSource: trimmed,
            audioPlacement: audioPlacement
        )
    }

    private func pendingAudioPlacement(actionName: String) -> PendingAudioPlacement? {
        guard placeAudioOnTimeline, let clip = timelineClip else { return nil }
        let spanSeconds = trimmedSourceIfEnabled()?.durationSeconds
            ?? (asset.duration > 0
                ? asset.duration
                : Double(clip.durationFrames) / Double(max(1, editor.timeline.fps)))
        return PendingAudioPlacement(
            startFrame: clip.startFrame,
            spanSeconds: max(spanSeconds, 1 / Double(max(1, editor.timeline.fps))),
            actionName: actionName
        )
    }

    private func upscaleLabel(for selection: UpscaleSelection) -> String {
        selection.label(
            durationSeconds: effectiveDurationForAvailability ?? asset.duration
        )
    }

    private func runUpscale(_ selection: UpscaleSelection) {
        let trim = trimmedSourceIfEnabled()
        let replacement = replacementTarget(resetTrim: trim != nil)
        Task { @MainActor in
            _ = await EditSubmitter.submitUpscale(
                asset: asset,
                model: selection.model,
                targetResolution: selection.targetResolution,
                editor: editor,
                trimmedSource: trim,
                replacementTarget: replacement, services: services
            )
        }
    }

    private var shouldReplace: Bool { replaceClipSource && clipId != nil }

    private func replacementTarget(resetTrim: Bool = false) -> GenerationClipReplacement.Snapshot? {
        guard shouldReplace, let clipId else { return nil }
        return .init(clipID: clipId, resetTrim: resetTrim, editor: editor)
    }

}
