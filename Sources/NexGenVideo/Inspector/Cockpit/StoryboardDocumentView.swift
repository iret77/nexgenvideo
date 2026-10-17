import NexGenEngine
import SwiftUI

struct StoryboardShotSelection: Equatable {
    let step: Step
    let sectionTitle: String
    let sectionRange: String
}

enum StoryboardPresentation {
    static func sectionTitle(_ section: NexGenEngine.Section) -> String {
        section.label.isEmpty ? readable(section.id) : section.label
    }

    static func sectionRange(_ section: NexGenEngine.Section) -> String {
        String(format: "%.1f–%.1f s", section.timeStart, section.timeEnd)
    }

    static func readable(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " · ")
            .capitalized
    }

    static func function(_ function: StepFunction) -> String {
        switch function {
        case .story: String(localized: "Story")
        case .moodInsert: String(localized: "Atmosphere")
        case .performance: String(localized: "Performance")
        case .cutaway: String(localized: "Cutaway")
        case .structuralAnchor: String(localized: "Section anchor")
        case .transition: String(localized: "Transition")
        }
    }

    static func source(_ mode: SourceMode) -> String {
        switch mode {
        case .generated: String(localized: "AI generation")
        case .imported: String(localized: "Imported footage")
        case .aiEnhanced: String(localized: "AI-enhanced footage")
        }
    }

    static func purpose(_ step: Step) -> String {
        function(step.function)
    }
}

struct StoryboardDocumentView: View {
    @Environment(EditorViewModel.self) private var editor
    let storyboard: Storyboard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                ForEach(storyboard.sections, id: \.id) { section in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(StoryboardPresentation.sectionTitle(section))
                                .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                            Spacer()
                            Text(StoryboardPresentation.sectionRange(section))
                                .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: AppTheme.Layout.storyboardCardMinWidth),
                            spacing: AppTheme.Spacing.md)], alignment: .leading, spacing: AppTheme.Spacing.md) {
                            ForEach(section.steps, id: \.id) { step in
                                shot(step, section: section)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: storyboard) { _, value in
            guard let selected = editor.storyboardSelection else { return }
            guard let section = value.sections.first(where: { $0.steps.contains(where: { $0.id == selected.step.id }) }),
                  let step = section.steps.first(where: { $0.id == selected.step.id }) else {
                editor.storyboardSelection = nil
                return
            }
            select(step, section: section)
        }
    }

    private func shot(_ step: Step, section: NexGenEngine.Section) -> some View {
        let selected = editor.storyboardSelection?.step.id == step.id
        return Button { select(step, section: section) } label: {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack {
                    Text(step.id)
                        .interfaceFont(size: AppTheme.Typography.metadata, design: .monospaced)
                    Spacer()
                    Text("Section · \(StoryboardPresentation.sectionRange(section))")
                        .interfaceFont(size: AppTheme.Typography.metadata, design: .monospaced)
                }
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(step.subject)
                    .interfaceFont(size: AppTheme.Typography.reading, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(StoryboardPresentation.purpose(step))
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1)
            }
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: AppTheme.Layout.storyboardCardMinHeight, alignment: .topLeading)
            .background(selected ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint) : AppTheme.Background.raisedColor)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(selected ? AppTheme.Accent.primary : AppTheme.Border.subtleColor,
                              lineWidth: selected ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.thin))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(step.id), \(step.subject), \(StoryboardPresentation.sectionRange(section))")
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(identifier: "storyboard.shot.\(step.id)",
                    acceptanceState: selected, acceptanceText: "\(step.subject) · \(StoryboardPresentation.purpose(step))")
                    .allowsHitTesting(false)
            }
        }
    }

    private func select(_ step: Step, section: NexGenEngine.Section) {
        editor.storyboardSelection = StoryboardShotSelection(step: step,
            sectionTitle: StoryboardPresentation.sectionTitle(section), sectionRange: StoryboardPresentation.sectionRange(section))
        editor.inspectorPanelVisible = true
    }
}

struct StoryboardShotInspector: View {
    let selection: StoryboardShotSelection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                Text(selection.step.id).interfaceFont(size: AppTheme.Typography.metadata, design: .monospaced)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(selection.step.subject)
                    .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                field("Section", selection.sectionTitle)
                field("Section timing", selection.sectionRange)
                field("Purpose", StoryboardPresentation.function(selection.step.function))
                field("Image source", StoryboardPresentation.source(selection.step.sourceMode))
                field("Camera", selection.step.camera)
                field("Framing", selection.step.framing)
                field("Setting", StoryboardPresentation.readable(selection.step.settingHint))
                field("Location view", StoryboardPresentation.readable(selection.step.locationViewRequest))
                fields(selection.step.cameraSetup)
                fields(selection.step.characterViewRequest)
                field("Props", selection.step.propRequest.map(StoryboardPresentation.readable).joined(separator: ", "))
                field("Visible areas", selection.step.visibleZones.map(StoryboardPresentation.readable).joined(separator: ", "))
                field("Introduced areas", selection.step.zoneIntroduces.map(StoryboardPresentation.readable).joined(separator: ", "))
                ForEach(Array(selection.step.characterBlocking.enumerated()), id: \.offset) { _, blocking in
                    fields(blocking)
                }
            }
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(identifier: "storyboard.inspector", acceptanceText: selection.step.id)
                    .allowsHitTesting(false)
            }
        }
    }

    private func fields(_ values: [String: String]) -> some View {
        ForEach(values.keys.sorted(), id: \.self) { key in
            field(StoryboardPresentation.readable(key), StoryboardPresentation.readable(values[key] ?? ""))
        }
    }

    @ViewBuilder private func field(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(label).interfaceFont(size: AppTheme.Typography.ui).foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(value).interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.primaryColor).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
