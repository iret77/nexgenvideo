import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension InspectorView {

    // MARK: - Effects Tab

    struct EffectControl: Hashable {
        let effectId: String
        let paramKey: String
        var label: String? = nil
        var gradient: [Color]? = nil
    }

    /// Basic › Tone.
    private var toneControls: [EffectControl] {
        [
            EffectControl(effectId: "color.exposure", paramKey: "ev"),
            EffectControl(effectId: "color.contrast", paramKey: "amount"),
            EffectControl(effectId: "color.highlightsShadows", paramKey: "highlights"),
            EffectControl(effectId: "color.highlightsShadows", paramKey: "shadows"),
            EffectControl(effectId: "color.blacksWhites", paramKey: "blacks"),
            EffectControl(effectId: "color.blacksWhites", paramKey: "whites"),
        ]
    }

    /// Basic › White Balance.
    private var whiteBalanceControls: [EffectControl] {
        [
            EffectControl(effectId: "color.temperature", paramKey: "temperature", gradient: AppTheme.Slider.tempGradient),
            EffectControl(effectId: "color.temperature", paramKey: "tint", gradient: AppTheme.Slider.tintGradient),
        ]
    }

    /// Basic › Presence.
    private var presenceControls: [EffectControl] {
        [
            EffectControl(effectId: "color.vibrance", paramKey: "amount"),
            EffectControl(effectId: "color.saturation", paramKey: "amount"),
        ]
    }

    private var blurControls: [EffectControl] {
        [EffectControl(effectId: "blur.gaussian", paramKey: "radius", label: "Blur")]
    }

    private var vignetteControls: [EffectControl] {
        [
            EffectControl(effectId: "stylize.vignette", paramKey: "amount", label: "Amount"),
            EffectControl(effectId: "stylize.vignette", paramKey: "midpoint", label: "Midpoint"),
            EffectControl(effectId: "stylize.vignette", paramKey: "roundness", label: "Roundness"),
            EffectControl(effectId: "stylize.vignette", paramKey: "feather", label: "Feather"),
        ]
    }

    /// Motion blur groups its distance + direction rows under one section.
    private var motionBlurControls: [EffectControl] {
        [
            EffectControl(effectId: "blur.motion", paramKey: "radius", label: "Amount"),
            EffectControl(effectId: "blur.motion", paramKey: "angle", label: "Angle"),
        ]
    }

    private var glowControls: [EffectControl] {
        [
            EffectControl(effectId: "stylize.glow", paramKey: "intensity", label: "Intensity"),
            EffectControl(effectId: "stylize.glow", paramKey: "radius", label: "Radius"),
            EffectControl(effectId: "stylize.glow", paramKey: "threshold", label: "Threshold"),
            EffectControl(effectId: "stylize.glow", paramKey: "warmth", label: "Warmth"),
        ]
    }

    private var chromaKeyControls: [EffectControl] {
        [
            EffectControl(effectId: "key.chroma", paramKey: "keyHue", label: "Key Hue"),
            EffectControl(effectId: "key.chroma", paramKey: "tolerance", label: "Tolerance"),
            EffectControl(effectId: "key.chroma", paramKey: "softness", label: "Softness"),
            EffectControl(effectId: "key.chroma", paramKey: "spill", label: "Spill"),
        ]
    }

    private var grainControls: [EffectControl] {
        [
            EffectControl(effectId: "stylize.grain", paramKey: "amount", label: "Amount"),
            EffectControl(effectId: "stylize.grain", paramKey: "size", label: "Size"),
        ]
    }

    private var detailControls: [EffectControl] {
        [
            EffectControl(effectId: "blur.sharpen", paramKey: "amount", label: "Sharpen"),
            EffectControl(effectId: "blur.noiseReduction", paramKey: "amount", label: "Noise Reduction"),
            EffectControl(effectId: "blur.noiseReduction", paramKey: "chroma", label: "Noise Chroma"),
            EffectControl(effectId: "blur.noiseReduction", paramKey: "detail", label: "Noise Detail"),
            EffectControl(effectId: "detail.clarity", paramKey: "clarity", label: "Clarity"),
            EffectControl(effectId: "detail.clarity", paramKey: "dehaze", label: "Dehaze"),
        ]
    }

    private var basicEffectIds: Set<String> {
        Set((toneControls + whiteBalanceControls + presenceControls).map(\.effectId))
    }

    private var effectsEffectIds: Set<String> {
        Set((detailControls + blurControls + motionBlurControls + vignetteControls + grainControls + glowControls + chromaKeyControls).map(\.effectId))
    }

    @ViewBuilder
    func effectsTabContent() -> some View {
        let clips = nonTextVisualClips
        let single = clips.count == 1 ? clips.first : nil
        InspectorKeyframesContent(isPresented: single != nil && editor.keyframesPanelVisible, keyframesFirstWhenStacked: true) {
            effectAdjustmentSections(clips: clips)
        } keyframes: {
            if let single { KeyframesPanel(clip: single, effectsOnly: true) }
        }
        .inspectorKeyframeAccessoryColumn(single != nil)
    }

    private func effectAdjustmentSections(clips: [Clip]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            if clips.count == 1, let clip = clips.first { ColorReferenceComparisonView(clipID: clip.id) }
            adjustSection(title: "Basic Correction", effectIds: basicEffectIds, clips: clips) {
                adjustSubgroup(title: "Tone", controls: toneControls, clips: clips)
                adjustSubgroup(title: "White Balance", controls: whiteBalanceControls, clips: clips)
                adjustSubgroup(title: "Presence", controls: presenceControls, clips: clips)
            }
            adjustSection(title: "Curves", effectIds: ["color.curves"], clips: clips) {
                curvesContent(clips: clips)
            }
            adjustSection(title: "Color Wheels", effectIds: ["color.wheels"], clips: clips) {
                wheelsContent(clips: clips)
            }
            adjustSection(title: "Hue Curves", effectIds: ["color.hueCurves"], clips: clips) {
                hueCurvesContent(clips: clips)
            }
            adjustSection(title: "LUTs", effectIds: ["color.lut"], clips: clips) {
                lutContent(clips: clips)
            }
            adjustSection(title: "Effects", effectIds: effectsEffectIds, clips: clips) {
                adjustSubgroup(title: "Detail", controls: detailControls, clips: clips)
                adjustSubgroup(title: "Blur", controls: blurControls, clips: clips)
                adjustSubgroup(title: "Motion Blur", controls: motionBlurControls, clips: clips)
                adjustSubgroup(title: "Vignette", controls: vignetteControls, clips: clips)
                adjustSubgroup(title: "Film Grain", controls: grainControls, clips: clips)
                adjustSubgroup(title: "Glow", controls: glowControls, clips: clips)
                adjustSubgroup(title: "Chroma Key", controls: chromaKeyControls, clips: clips)
            }
        }
    }

    // MARK: Section chrome

    @ViewBuilder
    private func adjustSection<Content: View>(
        title: String,
        effectIds: Set<String>,
        clips: [Clip],
        @ViewBuilder content: () -> Content
    ) -> some View {
        let expanded = !collapsedAdjustSections.contains(title)
        let hasEffects = anyAdjusted(effectIds, clips: clips)
        let enablement = sectionEnablement(effectIds, clips: clips)
        VStack(spacing: AppTheme.Spacing.none) {
            InspectorSectionHeading(title: title, expanded: expanded, onToggle: {
                if expanded { collapsedAdjustSections.insert(title) }
                else { collapsedAdjustSections.remove(title) }
            }) {
                if hasEffects {
                    resetButton(
                        onReset: { resetEffects(effectIds, clips: clips, actionName: "Reset \(title)") },
                        help: "Reset \(title.lowercased())"
                    )
                }
                Button {
                    setSectionEnabled(effectIds, clips: clips, enabled: enablement != .on)
                } label: {
                    Image(systemName: enablement.iconName)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(hasEffects ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
                        .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasEffects)
                .help(hasEffects
                    ? "\(enablement == .on ? "Disable" : "Enable") \(title.lowercased())"
                    : "No adjustments yet")
                .accessibilityLabel("\(enablement == .on ? "Disable" : "Enable") \(title)")
                .accessibilityValue(enablement.accessibilityValue)
                .reviewAcceptanceProbe("inspector.adjust.bypass." + title, state: hasEffects, text: enablement.accessibilityValue)
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Background.raisedColor)
            .overlay(alignment: .bottom) {
                if expanded { sectionDivider }
            }
            if expanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    content()
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.vertical, AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) { sectionDivider }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(AppTheme.Border.primaryColor)
            .frame(height: AppTheme.BorderWidth.hairline)
    }

    @ViewBuilder
    private func adjustSubgroup(title: String, controls: [EffectControl], clips: [Clip]) -> some View {
        let expanded = !collapsedAdjustSubgroups.contains(title)
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            InspectorSectionHeading(title: title, expanded: expanded, onToggle: {
                if expanded { collapsedAdjustSubgroups.insert(title) }
                else { collapsedAdjustSubgroups.remove(title) }
            })
            if expanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    ForEach(controls, id: \.self) { control in
                        adjustmentRow(control, clips: clips)
                    }
                }
            }
        }
    }

    // MARK: Curves

    @ViewBuilder
    private func curvesContent(clips: [Clip]) -> some View {
        CurveEditorView(
            curve: curve(in: clips.first?.effects ?? []),
            onChange: { setCurveChannel($0, points: $1, clips: clips, commit: false, action: "Edit Curves") },
            onCommit: { setCurveChannel($0, points: $1, clips: clips, commit: true, action: "Edit Curves") }
        )
    }

    private func curve(in effects: [Effect]) -> GradeCurve {
        guard let json = effects.first(where: { $0.type == "color.curves" })?
            .params["curve"]?.string else { return GradeCurve() }
        return GradeCurve(json: json) ?? GradeCurve()
    }

    private func setCurveChannel(
        _ channel: CurveEditorView.Channel,
        points: [CurvePoint],
        clips: [Clip],
        commit: Bool,
        action: String
    ) {
        let mutate: (inout [Effect]) -> Void = { [self] effects in
            var curve = curve(in: effects)
            switch channel {
            case .master: curve.master = points
            case .red: curve.red = points
            case .green: curve.green = points
            case .blue: curve.blue = points
            }
            upsertCurve(curve, in: &effects)
        }
        if commit {
            commitEffects(clips, actionName: action, mutate)
        } else {
            applyEffects(clips, mutate)
        }
    }

    private func upsertCurve(_ curve: GradeCurve, in effects: inout [Effect]) {
        let existing = effects.firstIndex { $0.type == "color.curves" }
        guard !curve.isIdentity, let json = curve.encoded() else {
            if let existing { effects.remove(at: existing) }
            return
        }
        if let existing {
            effects[existing].params["curve"] = EffectParam(string: json)
        } else {
            var effect = Effect(type: "color.curves")
            effect.params["curve"] = EffectParam(string: json)
            effects.insert(effect, at: alwaysOnInsertIndex(effects, for: "color.curves"))
        }
    }

    // MARK: Hue curves

    @ViewBuilder
    private func hueCurvesContent(clips: [Clip]) -> some View {
        HueCurveEditorView(
            curves: HueCurves.read(from: clips.first?.effects ?? []),
            onChange: { setHueCurveChannel($0, points: $1, clips: clips, commit: false, action: "Edit Hue Curves") },
            onCommit: { setHueCurveChannel($0, points: $1, clips: clips, commit: true, action: "Edit Hue Curves") }
        )
    }

    private func setHueCurveChannel(
        _ channel: HueCurves.Channel,
        points: [CurvePoint],
        clips: [Clip],
        commit: Bool,
        action: String
    ) {
        let mutate: (inout [Effect]) -> Void = { effects in
            var curves = HueCurves.read(from: effects)
            curves.set(channel, points)
            curves.upsert(into: &effects)
        }
        if commit {
            commitEffects(clips, actionName: action, mutate)
        } else {
            applyEffects(clips, mutate)
        }
    }

    // MARK: Color wheels

    @ViewBuilder
    private func wheelsContent(clips: [Clip]) -> some View {
        WrapLayout(spacing: AppTheme.Spacing.md) {
            wheelControl("Lift", prefix: "lift", clips: clips)
            wheelControl("Gamma", prefix: "gamma", clips: clips)
            wheelControl("Gain", prefix: "gain", clips: clips)
        }
        .frame(maxWidth: .infinity)
    }

    private func wheelControl(_ title: String, prefix: String, clips: [Clip]) -> some View {
        let mKey = "\(prefix)_m"
        let mSpec = EffectRegistry.descriptor(id: "color.wheels")?.params.first { $0.key == mKey }
        let mDefault = mSpec?.defaultValue ?? 0
        let mRange = mSpec?.range ?? 0...2
        return ColorWheelControl(
            title: title,
            x: sharedClipValue(clips) { wheelParam($0, "\(prefix)_x", default: 0) } ?? 0,
            y: sharedClipValue(clips) { wheelParam($0, "\(prefix)_y", default: 0) } ?? 0,
            master: sharedClipValue(clips) { wheelParam($0, mKey, default: mDefault) } ?? mDefault,
            masterRange: mRange,
            masterDefault: mDefault,
            onColorChanged: { setWheelColor(prefix, $0, $1, clips: clips, commit: false) },
            onColorCommit: { setWheelColor(prefix, $0, $1, clips: clips, commit: true) },
            onMasterChanged: { setControlParam(EffectControl(effectId: "color.wheels", paramKey: mKey), label: title, value: $0, clips: clips, commit: false) },
            onMasterCommit: { setControlParam(EffectControl(effectId: "color.wheels", paramKey: mKey), label: title, value: $0, clips: clips, commit: true) }
        )
        .disabled(!canEditEffect(clips, type: "color.wheels", keys: [prefix + "_x", prefix + "_y", mKey]))
        .help(canEditEffect(clips, type: "color.wheels", keys: [prefix + "_x", prefix + "_y", mKey]) ? title : "Move playhead inside the animated clip")
    }

    private func wheelParam(_ clip: Clip, _ key: String, default def: Double) -> Double {
        (clip.effects ?? []).first { $0.type == "color.wheels" }?.params[key]?.resolved(at: editor.activeFrame - clip.startFrame, default: def) ?? def
    }

    /// Both pad axes upserted in one mutation so a drag is a single undo entry.
    private func setWheelColor(_ prefix: String, _ x: Double, _ y: Double, clips: [Clip], commit: Bool) {
        editor.setEffectParameters(clipIDs: clips.map(\.id), type: "color.wheels",
            values: [prefix + "_x": x, prefix + "_y": y], commit: commit, action: "Adjust " + prefix.capitalized)
    }

    // MARK: LUT

    @ViewBuilder
    private func lutContent(clips: [Clip]) -> some View {
        let path = lutPath(in: clips)
        let problems = editor.unresolvedEffectResourceProblems.filter { problem in clips.contains { $0.id == problem.clipID } }
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            ForEach(problems) { problem in
                Text(problem.message)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .reviewAcceptanceProbe("inspector.lut.offline", text: problem.name)
            }
            if !problems.isEmpty {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Button("Relink…") { chooseLUT(clips: clips) }
                        .buttonStyle(.capsule(.secondary))
                        .reviewAcceptanceProbe("inspector.lut.relink")
                    Button("Remove LUT") {
                        let ids = Set(problems.map(\.effectID))
                        commitEffects(clips, actionName: "Remove Missing LUT") { effects in
                            effects.removeAll { ids.contains($0.id) }
                        }
                    }
                    .buttonStyle(.capsule(.secondary))
                    .reviewAcceptanceProbe("inspector.lut.remove")
                }
                .disabled(lutMutationID != nil)
            }
            lutFileRow(path: path, clips: clips)
            if path != nil { lutIntensityRow(clips: clips) }
            if lutMutationID != nil { ProgressView("Loading LUT…").interfaceFont(size: AppTheme.Typography.ui) }
            if let lutLoadError {
                Text(lutLoadError).interfaceFont(size: AppTheme.Typography.ui).foregroundStyle(AppTheme.Status.errorColor)
                    .reviewAcceptanceProbe("inspector.lut.error", text: lutLoadError)
            }
        }
    }

    private func lutFileRow(path: String?, clips: [Clip]) -> some View {
        InspectorFormRow(label: "File") {
            Button { chooseLUT(clips: clips) } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "square.stack.3d.up")
                        .interfaceFont(size: AppTheme.Typography.ui)
                    Text(lutDisplayName(in: clips) ?? "Choose…")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .reviewAcceptanceProbe("inspector.lut.name", text: lutDisplayName(in: clips) ?? "Choose…")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.capsule(.secondary))
            .help(lutDisplayName(in: clips) ?? "Choose a .cube LUT file")
            .disabled(lutMutationID != nil)
            .reviewAcceptanceProbe("inspector.lut.choose", state: lutMutationID == nil, text: path ?? "")
        }
        .frame(minHeight: AppTheme.Timeline.keyframeRowHeight)
    }

    private func lutIntensityRow(clips: [Clip]) -> some View {
        let spec = EffectRegistry.descriptor(id: "color.lut")?.params.first { $0.key == "intensity" }
        let range = spec?.range ?? 0...1
        let value = lutIntensity(in: clips)
        return InspectorAnimatableFormRow(label: "Intensity", showsAccessory: clips.count == 1) {
            HStack(spacing: AppTheme.Spacing.sm) {
                AdjustSlider(
                    value: value, range: range, defaultValue: spec?.defaultValue ?? 1,
                    accessibilityName: "LUT intensity",
                    onChanged: { setLUTIntensity($0, clips: clips, commit: false) },
                    onCommit: { setLUTIntensity($0, clips: clips, commit: true) }
                )
                .frame(minWidth: AppTheme.ComponentSize.inspectorSliderMinWidth)
                ScrubbableNumberField(
                    value: value, range: range, displayMultiplier: 100, format: "%.0f",
                    valueSuffix: "%", accessibilityName: "LUT intensity value",
                    acceptanceIdentifier: "inspector.lut.intensity",
                    dragSensitivity: 0.5, fieldWidth: AppTheme.ComponentSize.scrubFieldStandard,
                    onChanged: { setLUTIntensity($0, clips: clips, commit: false) }
                ) { setLUTIntensity($0, clips: clips, commit: true) }
            }
            .disabled(!canEditEffect(clips, type: "color.lut", keys: ["intensity"]))
            .help(canEditEffect(clips, type: "color.lut", keys: ["intensity"]) ? "LUT intensity" : "Move playhead inside the animated clip")
        } accessory: {
            if clips.count == 1, let clip = clips.first {
                effectKeyframeControls(EffectControl(effectId: "color.lut", paramKey: "intensity"), clip: clip, label: "LUT intensity")
            }
        }
        .frame(minHeight: AppTheme.Timeline.keyframeRowHeight)
    }

    private func lutPath(in clips: [Clip]) -> String? {
        (clips.first?.effects ?? []).first { $0.type == "color.lut" }?.params["path"]?.string
    }

    private func lutDisplayName(in clips: [Clip]) -> String? {
        guard let effect = clips.first?.effects?.first(where: { $0.type == "color.lut" }) else { return nil }
        if let name = effect.params["name"]?.string, !name.isEmpty { return name }
        guard let path = effect.params["path"]?.string else { return nil }
        return ProjectEffectResources.isPortable(path) ? "Project LUT" : URL(fileURLWithPath: path).lastPathComponent
    }

    private func lutIntensity(in clips: [Clip]) -> Double? {
        sharedClipValue(clips) { clip in
            (clip.effects ?? []).first { $0.type == "color.lut" }?
                .params["intensity"]?.resolved(at: editor.activeFrame - clip.startFrame, default: 1) ?? 1
        }
    }

    private func chooseLUT(clips: [Clip]) {
        let home = editor.workingRoot, key = editor.openWorkingCopyKey
        let selection = editor.selectedClipIds, timeline = editor.timeline
        let declaredName = editor.declaredPluginName, binding = editor.declaredPluginBinding
        let contract = editor.declaredProductionContract
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .cube LUT file"
        if let cube = UTType(filenameExtension: "cube") { panel.allowedContentTypes = [cube] }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard editor.workingRoot == home, editor.openWorkingCopyKey == key,
                  editor.selectedClipIds == selection, editor.timeline == timeline,
                  editor.declaredPluginName == declaredName, editor.declaredPluginBinding == binding,
                  editor.declaredProductionContract == contract else {
                lutLoadError = "The project or clip selection changed. Choose the LUT again."; return
            }
            setLUTPath(url.path, clips: clips)
        }
    }

    private func setLUTPath(_ path: String, clips: [Clip]) {
        guard lutMutationID == nil else { return }
        guard let home = editor.workingRoot, let key = editor.openWorkingCopyKey else {
            lutLoadError = "Open a project before loading a LUT."; return
        }
        let operation = UUID(), timeline = editor.timeline, selection = editor.selectedClipIds
        let binding = editor.declaredPluginBinding, contract = editor.declaredProductionContract
        let declaredName = editor.declaredPluginName
        let name = URL(fileURLWithPath: path).lastPathComponent
        lutMutationID = operation; lutLoadError = nil
        Task { @MainActor in
            defer { if lutMutationID == operation { lutMutationID = nil } }
            do {
                _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: declaredName,
                    declaredBinding: binding, declaredProductionContract: contract)
                try ProjectWorkingCopy.markDirty(key: key)
                let stored = try await Task.detached(priority: .userInitiated) {
                    try LUTLoader.store(path: path, projectRoot: home)
                }.value
                guard lutMutationID == operation, editor.workingRoot == home, editor.openWorkingCopyKey == key,
                      editor.timeline == timeline, editor.selectedClipIds == selection,
                      editor.declaredPluginName == declaredName, editor.declaredPluginBinding == binding,
                      editor.declaredProductionContract == contract else {
                    throw ToolError("The project or clip selection changed. Choose the LUT again.")
                }
                _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: declaredName,
                    declaredBinding: binding, declaredProductionContract: contract)
                commitEffects(clips, actionName: "Apply LUT") { effects in
                    if let i = effects.firstIndex(where: { $0.type == "color.lut" }) {
                        effects[i].params["path"] = EffectParam(string: stored)
                        effects[i].params["name"] = EffectParam(string: name)
                    } else {
                        var effect = Effect(type: "color.lut")
                        effect.params["path"] = EffectParam(string: stored)
                        effect.params["name"] = EffectParam(string: name)
                        effects.insert(effect, at: alwaysOnInsertIndex(effects, for: "color.lut"))
                    }
                }
            } catch {
                if lutMutationID == operation, editor.workingRoot == home { lutLoadError = error.localizedDescription }
            }
        }
    }

    private func setLUTIntensity(_ value: Double, clips: [Clip], commit: Bool) {
        let existing = clips.filter { $0.effects?.contains(where: { $0.type == "color.lut" }) == true }
        editor.setEffectParameter(clipIDs: existing.map(\.id), type: "color.lut", key: "intensity",
                                  value: value, commit: commit, action: "Change LUT Intensity")
    }

    // MARK: Adjustment rows

    @ViewBuilder
    private func adjustmentRow(_ control: EffectControl, clips: [Clip]) -> some View {
        if let descriptor = EffectRegistry.descriptor(id: control.effectId),
           let spec = descriptor.params.first(where: { $0.key == control.paramKey }) {
            let label = control.label ?? spec.label
            let value = sharedClipValue(clips) { controlValue($0, control, spec) }
            InspectorAnimatableFormRow(label: label, showsAccessory: clips.count == 1) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    AdjustSlider(
                        value: value,
                        range: spec.range,
                        gradient: control.gradient,
                        defaultValue: EffectInspectorValues.resetValue(type: control.effectId, spec: spec),
                        accessibilityName: label,
                        onChanged: { setControlParam(control, label: label, value: $0, clips: clips, commit: false) },
                        onCommit: { setControlParam(control, label: label, value: $0, clips: clips, commit: true) }
                    )
                    .frame(minWidth: AppTheme.ComponentSize.inspectorSliderMinWidth)
                    ScrubbableNumberField(
                        value: value,
                        range: spec.range,
                        format: effectParamFormat(spec),
                        valueSuffix: spec.unit.isEmpty ? "" : " \(spec.unit)",
                        accessibilityName: label + " value",
                        acceptanceIdentifier: "inspector.adjust.value." + control.effectId + "." + control.paramKey,
                        dragSensitivity: effectParamSensitivity(spec),
                        fieldWidth: AppTheme.ComponentSize.scrubFieldStandard,
                        onChanged: { setControlParam(control, label: label, value: $0, clips: clips, commit: false) }
                    ) { setControlParam(control, label: label, value: $0, clips: clips, commit: true) }
                }
                .disabled(!canEditEffect(clips, type: control.effectId, keys: [control.paramKey]))
                .help(canEditEffect(clips, type: control.effectId, keys: [control.paramKey]) ? label : "Move playhead inside the animated clip")
            } accessory: {
                if clips.count == 1, let clip = clips.first { effectKeyframeControls(control, clip: clip, label: label) }
            }
            .frame(minHeight: AppTheme.Timeline.keyframeRowHeight)
        }
    }

    private func canEditEffect(_ clips: [Clip], type: String, keys: [String]) -> Bool {
        clips.allSatisfy { clip in
            clip.contains(timelineFrame: editor.activeFrame) || keys.allSatisfy { key in
                clip.effects?.first(where: { $0.type == type })?.params[key]?.track?.isActive != true
            }
        }
    }

    private func controlValue(_ clip: Clip, _ control: EffectControl, _ spec: EffectParamSpec) -> Double {
        EffectInspectorValues.value(clip: clip, type: control.effectId, spec: spec, frame: editor.activeFrame)
    }

    private func setControlParam(
        _ control: EffectControl, label: String, value: Double, clips: [Clip], commit: Bool
    ) {
        editor.setEffectParameter(clipIDs: clips.map(\.id), type: control.effectId, key: control.paramKey,
                                  value: value, commit: commit, action: "Change " + label)
    }

    private func alwaysOnInsertIndex(_ effects: [Effect], for effectId: String) -> Int {
        EffectRegistry.insertIndex(effects, for: effectId)
    }

    private func anyAdjusted(_ ids: Set<String>, clips: [Clip]) -> Bool {
        clips.contains { ($0.effects ?? []).contains { ids.contains($0.type) } }
    }

    private func resetEffects(_ ids: Set<String>, clips: [Clip], actionName: String) {
        commitEffects(clips, actionName: actionName) { effects in
            effects.removeAll { ids.contains($0.type) }
        }
    }

    private enum SectionEnablement {
        case on
        case off
        case mixed

        var iconName: String {
            switch self {
            case .on: "checkmark.square"
            case .off: "square"
            case .mixed: "minus.square"
            }
        }

        var accessibilityValue: String {
            switch self {
            case .on: "On"
            case .off: "Off"
            case .mixed: "Mixed"
            }
        }
    }

    private func sectionEnablement(_ ids: Set<String>, clips: [Clip]) -> SectionEnablement {
        let states = clips.flatMap { clip in
            (clip.effects ?? []).filter { ids.contains($0.type) }.map(\.enabled)
        }
        guard states.contains(false) else { return .on }
        return states.contains(true) ? .mixed : .off
    }

    private func setSectionEnabled(_ ids: Set<String>, clips: [Clip], enabled: Bool) {
        commitEffects(clips, actionName: enabled ? "Enable Section" : "Disable Section") { effects in
            for i in effects.indices where ids.contains(effects[i].type) {
                effects[i].enabled = enabled
            }
        }
    }

    private func effectParamFormat(_ spec: EffectParamSpec) -> String {
        (spec.range.upperBound - spec.range.lowerBound) <= 20 ? "%.2f" : "%.0f"
    }

    private func effectParamSensitivity(_ spec: EffectParamSpec) -> Double {
        max(0.01, (spec.range.upperBound - spec.range.lowerBound) / 200)
    }

    /// Live edit (no undo entry) — mirrors applyClipProperty's refresh-only path.
    private func applyEffects(_ clips: [Clip], _ mutate: @escaping (inout [Effect]) -> Void) {
        editor.applyClipProperties(clipIds: clips.map(\.id)) { c in
            var effects = c.effects ?? []
            mutate(&effects)
            c.effects = effects.isEmpty ? nil : effects
        }
    }

    /// One undoable entry across all selected clips.
    private func commitEffects(
        _ clips: [Clip], actionName: String, _ mutate: @escaping (inout [Effect]) -> Void
    ) {
        editor.undoManager?.beginUndoGrouping()
        editor.commitClipProperties(clipIds: clips.map(\.id)) { c in
            var effects = c.effects ?? []
            mutate(&effects)
            c.effects = effects.isEmpty ? nil : effects
        }
        editor.undoManager?.setActionName(actionName)
        editor.undoManager?.endUndoGrouping()
    }
}

enum EffectInspectorValues {
    static func resetValue(type: String, spec: EffectParamSpec) -> Double {
        switch (type, spec.key) {
        case ("blur.gaussian", "radius"), ("blur.sharpen", "amount"): 0
        default: spec.defaultValue
        }
    }

    static func value(clip: Clip, type: String, spec: EffectParamSpec, frame: Int) -> Double {
        guard let effect = clip.effects?.first(where: { $0.type == type }) else {
            return resetValue(type: type, spec: spec)
        }
        return effect.params[spec.key]?.resolved(at: frame - clip.startFrame, default: spec.defaultValue) ?? spec.defaultValue
    }
}
