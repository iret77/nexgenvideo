import NexGenEngine
import SwiftUI

struct StoryboardReviewSheet: View {
    let storyboard: Storyboard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lgXl) {
            HStack {
                Text("Storyboard")
                    .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
            }
            Text(storyboard.meta.summaryOneline)
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if let notes = storyboard.meta.notes { Text(notes) }
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xlXxl) {
                    ForEach(storyboard.sections, id: \.id) { section in
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
                            Text(section.label.isEmpty ? section.id : section.label)
                                .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                            Text("\(section.timeStart, specifier: "%.1f")–\(section.timeEnd, specifier: "%.1f") s · \(section.function) · \(section.energy)")
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                            if let pattern = section.patternOverride { field("Pattern", pattern) }
                            ForEach(section.steps, id: \.id) { step in
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                                    Text("\(step.id) · \(step.function.rawValue)")
                                        .fontWeight(AppTheme.FontWeight.semibold)
                                    field("Subject", step.subject)
                                    field("Camera", step.camera)
                                    field("Framing", step.framing)
                                    field("Setting", step.settingHint)
                                    field("Location view", step.locationViewRequest)
                                    field("Source", step.sourceMode.rawValue)
                                    field("Character views", describe(step.characterViewRequest))
                                    field("Props", step.propRequest.joined(separator: ", "))
                                    field("Visible zones", step.visibleZones.joined(separator: ", "))
                                    field("Introduces", step.zoneIntroduces.joined(separator: ", "))
                                    field("Camera setup", describe(step.cameraSetup))
                                    field("Blocking", step.characterBlocking.map(describe).joined(separator: "\n"))
                                    field("Notes", step.notes)
                                }
                                .padding(AppTheme.Spacing.lgXl)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                            }
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        .interfaceFont(size: AppTheme.Typography.reading)
        .padding(AppTheme.Spacing.xlXxl)
        .frame(minWidth: AppTheme.ComponentSize.formatSheetWidth,
               idealWidth: AppTheme.ComponentSize.storyboardReviewWidth,
               minHeight: AppTheme.ComponentSize.formatSheetCardListMinHeight)
    }

    private func describe(_ values: [String: String]) -> String {
        values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
    }

    @ViewBuilder private func field(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(label).interfaceFont(size: AppTheme.Typography.ui).foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(value).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
