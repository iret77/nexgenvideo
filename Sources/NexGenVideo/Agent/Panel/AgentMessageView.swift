import AppKit
import NexGenEngine
import SwiftUI

struct AgentTranscriptTurnView: View {
    let turn: AgentTranscriptTurn
    let toolResults: [String: ToolRunResult]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            ForEach(turn.items) { item in
                switch item {
                case .userIntent(let intent):
                    AgentUserIntentView(text: intent.text)
                case .assistantResult(let message):
                    AgentMessageView(message: message, toolResults: toolResults)
                case .activity(let activity):
                    AgentActivityView(activity: activity, toolResults: toolResults)
                case .receipts(let group):
                    AgentReceiptGroupView(group: group)
                case .notice(let notice):
                    DialogNoticeView(text: notice.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation turn")
    }
}

private struct AgentUserIntentView: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: AppTheme.Spacing.xxl)
            Text(text)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineSpacing(AppTheme.Spacing.xxs)
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                        .fill(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.faint))
                )
                .textSelection(.enabled)
        }
    }
}

private struct AgentReceiptGroupView: View {
    let group: AgentReceiptGroup

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if let phase = group.phase {
                Text(PhaseDisplay.label(phase).uppercased())
                    .font(.system(
                        size: AppTheme.FontSize.xxs,
                        weight: AppTheme.FontWeight.semibold
                    ))
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            ForEach(group.receipts) { receipt in
                AgentReceiptView(receipt: receipt)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AgentReceiptView: View {
    let receipt: AgentTranscriptReceipt

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(color)
                .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
            Text(summary)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityLabel(summary)
    }

    private var summary: String {
        switch receipt.content {
        case .choice(let record):
            return record.summary
        case .workflow(let record):
            let details = [record.detail] + record.attachmentNames.map { Optional($0) }
            let suffix = details.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return suffix.isEmpty
                ? "\(record.title) — \(outcomeLabel(record.outcome))"
                : "\(record.title) — \(outcomeLabel(record.outcome)) · \(suffix)"
        }
    }

    private var symbol: String {
        switch receipt.content {
        case .choice: "checkmark.circle.fill"
        case .workflow(let record):
            switch record.outcome {
            case .attached: "paperclip.circle.fill"
            case .provided: "tray.and.arrow.down.fill"
            case .skipped: "forward.fill"
            case .completed: "checkmark.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            case .needsAction: "exclamationmark.circle.fill"
            }
        }
    }

    private var color: Color {
        switch receipt.content {
        case .choice: AppTheme.Text.tertiaryColor
        case .workflow(let record):
            switch record.outcome {
            case .skipped: AppTheme.Text.tertiaryColor
            case .failed: AppTheme.Status.errorColor
            case .needsAction: AppTheme.Status.warningColor
            default: AppTheme.Status.successColor
            }
        }
    }

    private func outcomeLabel(_ outcome: AgentWorkflowRecord.Outcome) -> String {
        switch outcome {
        case .attached: "Attached"
        case .provided: "Provided"
        case .skipped: "Skipped"
        case .completed: "Done"
        case .failed: "Failed"
        case .needsAction: "Needs action"
        }
    }
}

struct AgentMessageView: View {
    let message: AgentMessage
    let toolResults: [String: ToolRunResult]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        switch message.role {
        case .user:   userBody
        case .assistant: assistantBody
        }
    }

    private var copyableText: String {
        message.blocks
            .compactMap { if case let .text(s) = $0 { return s } else { return nil } }
            .joined(separator: "\n\n")
    }

    @ViewBuilder
    private var userBody: some View {
        if let presentation = message.userPresentation {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if let record = presentation.workflowRecord {
                    WorkflowRecordView(record: record)
                }
                if let record = presentation.choiceRecord {
                    HStack {
                        DialogChoiceRecordView(record: record)
                        Spacer(minLength: AppTheme.Spacing.xxl)
                    }
                }
                if let typed = presentation.typedText, !typed.isEmpty {
                    userBubble(typed)
                }
                if let notice = presentation.notice, !notice.isEmpty {
                    HStack {
                        DialogNoticeView(text: notice)
                        Spacer(minLength: AppTheme.Spacing.xxl)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            let texts = message.blocks.compactMap { block -> String? in
                if case let .text(s) = block { return s }
                return nil
            }
            if !texts.isEmpty { userBubble(texts.joined(separator: "\n")) }
        }
        // Tool-result user messages render merged into the preceding assistant row.
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: AppTheme.Spacing.xxl)
            Text(text)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineSpacing(AppTheme.Spacing.xxs)
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                        .fill(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.faint))
                )
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var assistantBody: some View {
        let structuredResults = parsedStructuredResults
        let firstStructuredResultIndex = structuredResults.first?.index
        let combinedStructuredBlocks = structuredResults.flatMap(\.blocks)
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .text(let text):
                    MarkdownText(text: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .toolUse(let id, let name, let inputJSON):
                    // show_blocks renders as native UI, not as a tool row (#135). A call the
                    // strict parser rejects falls back to the row — its expanded detail carries
                    // the violation the model was told about.
                    if ToolRunPresentation.baseName(for: name) == ToolName.showBlocks.rawValue,
                       Self.parsedBlocks(inputJSON) != nil {
                        if index == firstStructuredResultIndex {
                            AgentBlocksView(blocks: combinedStructuredBlocks)
                        }
                    } else {
                        ToolRunRow(name: name, inputJSON: inputJSON, result: toolResults[id])
                    }
                case .toolResult:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Copy floats as an overlay so hovering never reflows the transcript. As an in-flow child it
        // pushed every row below it down when it appeared, so scrubbing the mouse down the chat made
        // the whole thing jump.
        .overlay(alignment: .topTrailing) {
            if !copyableText.isEmpty, isHovering {
                CopyMessageButton(text: copyableText)
                    .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .animation(
            reduceMotion ? nil : .easeOut(duration: AppTheme.Anim.hover),
            value: isHovering
        )
    }

    private struct StructuredResult {
        let index: Int
        let blocks: [AgentBlock]
    }

    private var parsedStructuredResults: [StructuredResult] {
        message.blocks.enumerated().compactMap { index, block in
            guard case .toolUse(_, let name, let inputJSON) = block,
                  ToolRunPresentation.baseName(for: name) == ToolName.showBlocks.rawValue,
                  let blocks = Self.parsedBlocks(inputJSON) else { return nil }
            return StructuredResult(index: index, blocks: blocks)
        }
    }

    /// Blocks from a show_blocks tool-use payload, nil when the JSON or the strict
    /// block schema doesn't hold (→ tool-row fallback).
    private static func parsedBlocks(_ inputJSON: String) -> [AgentBlock]? {
        guard let data = inputJSON.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return AgentBlocks.parseForRendering(args)
    }
}

private struct WorkflowRecordView: View {
    let record: AgentWorkflowRecord

    private var outcomeLabel: String {
        switch record.outcome {
        case .attached: "Attached"
        case .provided: "Provided"
        case .skipped: "Skipped"
        case .completed: "Done"
        case .failed: "Failed"
        case .needsAction: "Needs action"
        }
    }

    private var outcomeSymbol: String {
        switch record.outcome {
        case .failed: "exclamationmark.triangle.fill"
        case .needsAction: "exclamationmark.circle.fill"
        default: "checkmark.circle.fill"
        }
    }

    private var outcomeColor: Color {
        switch record.outcome {
        case .skipped: AppTheme.Text.tertiaryColor
        case .failed: AppTheme.Status.errorColor
        case .needsAction: AppTheme.Status.warningColor
        default: AppTheme.Status.successColor
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: record.symbol)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Accent.timecodeColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                    Text(record.title)
                        .font(.system(
                            size: AppTheme.FontSize.sm,
                            weight: AppTheme.FontWeight.semibold
                        ))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Spacer(minLength: AppTheme.Spacing.sm)
                    Label(outcomeLabel, systemImage: outcomeSymbol)
                        .font(.system(
                            size: AppTheme.FontSize.xs,
                            weight: AppTheme.FontWeight.medium
                        ))
                        .foregroundStyle(outcomeColor)
                }
                if let phase = record.phase {
                    Text(PhaseDisplay.label(phase))
                        .font(.system(
                            size: AppTheme.FontSize.xxs,
                            weight: AppTheme.FontWeight.medium
                        ))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                if let detail = record.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                if !record.attachmentNames.isEmpty {
                    Text(record.attachmentNames.joined(separator: ", "))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(AppTheme.Spacing.smMd)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(
                    AppTheme.Border.subtleColor,
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(record.title), \(outcomeLabel), "
                + ([record.phase.map { PhaseDisplay.label($0) }, record.detail]
                    .compactMap { $0 } + record.attachmentNames)
                    .joined(separator: ", ")
        )
    }
}

private struct DialogChoiceRecordView: View {
    let record: AgentChoiceRecord

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
            Text(record.summary)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
        .accessibilityLabel("Selected: \(record.summary)")
    }
}

private struct DialogNoticeView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Status.errorColor)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(AppTheme.Status.errorColor.opacity(AppTheme.Opacity.subtle))
            )
            .textSelection(.enabled)
    }
}

private struct CopyMessageButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                Text(copied ? "Copied" : "Copy")
            }
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Background.raisedColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Copy message")
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

struct ToolRunResult {
    let content: [ToolResult.Block]
    let isError: Bool
}

struct AgentActivityView: View {
    let activity: AgentActivity
    let toolResults: [String: ToolRunResult]
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private var hasError: Bool {
        activity.steps.contains { toolResults[$0.id]?.isError == true }
    }

    private var hasIncompleteStep: Bool {
        !activity.isRunning && activity.steps.contains { toolResults[$0.id] == nil }
    }

    private var label: String {
        activity.operationLabel
    }

    private var accessibilityState: String {
        if activity.isRunning { return "Working" }
        if hasError { return "Failed" }
        if hasIncompleteStep { return "Incomplete" }
        return "Completed"
    }

    private var generationImages: [String] {
        activity.steps.flatMap { step -> [String] in
            guard Self.displaysCompletedImage(for: step.name),
                  let result = toolResults[step.id] else { return [] }
            return result.content.compactMap { block in
                guard case .image(let base64, _) = block else { return nil }
                return base64
            }
        }
    }

    private static func displaysCompletedImage(for name: String) -> Bool {
        switch ToolRunPresentation.baseName(for: name) {
        case ToolName.generateImage.rawValue, ToolName.upscaleMedia.rawValue:
            true
        default:
            false
        }
    }

    private var activePhaseProgress: PipelinePhaseExecutionSnapshot? {
        guard let snapshot = editor.pipelinePhaseExecution.snapshot,
              snapshot.isRunning,
              let dataRoot = editor.workingRoot.flatMap({
                  DataRootResolver.dataRoot(of: $0)
              }),
              editor.pipelinePhaseExecution.isRunning(
                  projectRoot: dataRoot,
                  phase: snapshot.phase
              ),
              activity.steps.contains(where: {
                  ToolRunPresentation.baseName(for: $0.name)
                      == ToolName.runPhase.rawValue
                      && Self.phase(from: $0.inputJSON) == snapshot.phase
              })
        else { return nil }
        return snapshot
    }

    @ViewBuilder
    var body: some View {
        if let activePhaseProgress {
            PipelinePhaseProgressView(snapshot: activePhaseProgress)
        } else {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Button {
                    if reduceMotion {
                        expanded.toggle()
                    } else {
                        withAnimation(.easeOut(duration: AppTheme.Anim.hover)) {
                            expanded.toggle()
                        }
                    }
                } label: {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        statusIcon
                        Text(label)
                            .font(.system(
                                size: AppTheme.FontSize.sm,
                                weight: AppTheme.FontWeight.medium
                            ))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .lineLimit(2)
                        Spacer(minLength: AppTheme.Spacing.sm)
                        Image(systemName: "chevron.right")
                            .font(.system(
                                size: AppTheme.FontSize.micro,
                                weight: AppTheme.FontWeight.semibold
                            ))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(accessibilityState): \(label)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(expanded ? "Hide technical details" : "Show technical details")

                ForEach(Array(generationImages.enumerated()), id: \.offset) { _, base64 in
                    ToolResultImageView(base64: base64)
                }

                if expanded {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        if activity.statuses.count > 1 {
                            ForEach(
                                Array(activity.statuses.dropLast().enumerated()),
                                id: \.offset
                            ) { _, status in
                                Text(status)
                                    .font(.system(size: AppTheme.FontSize.xs))
                                    .foregroundStyle(AppTheme.Text.mutedColor)
                            }
                        }
                        ForEach(activity.steps) { step in
                            ToolRunDetail(
                                name: step.name,
                                inputJSON: step.inputJSON,
                                result: toolResults[step.id],
                                showsHeader: true
                            )
                        }
                    }
                    .padding(.leading, AppTheme.Spacing.xxs)
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if activity.isRunning {
            ProgressView()
                .controlSize(.mini)
                .frame(width: AppTheme.Spacing.md, height: AppTheme.Spacing.md)
        } else {
            Image(systemName: hasError || hasIncompleteStep
                ? "exclamationmark.circle.fill"
                : "checkmark.circle.fill")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(
                    hasError || hasIncompleteStep
                        ? AppTheme.Status.warningColor.opacity(AppTheme.Opacity.prominent)
                        : AppTheme.Text.tertiaryColor
                )
        }
    }

    private static func phase(from inputJSON: String) -> String? {
        guard let data = inputJSON.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any]
        else { return nil }
        return object["phase"] as? String
    }
}

private struct ToolRunRow: View {
    let name: String
    let inputJSON: String
    let result: ToolRunResult?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private var isRunning: Bool { result == nil }
    private var statusIcon: String {
        guard let result else { return "circle.dotted" }
        return result.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    }
    private var statusTint: Color {
        guard let result else { return AppTheme.Text.mutedColor }
        // Tool failures are routine agent feedback, not user-facing fatal errors.
        return result.isError
            ? AppTheme.Status.warningColor.opacity(AppTheme.Opacity.prominent)
            : AppTheme.Text.tertiaryColor
    }
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Button {
                if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(.easeOut(duration: AppTheme.Anim.hover)) {
                        expanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.sm) {
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: AppTheme.Spacing.md, height: AppTheme.Spacing.md)
                    } else {
                        Image(systemName: statusIcon)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(statusTint)
                    }
                    Text(ToolRunPresentation.label(for: name))
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .opacity(isRunning ? AppTheme.Opacity.prominent : AppTheme.Opacity.opaque)
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                ToolRunDetail(
                    name: name,
                    inputJSON: inputJSON,
                    result: result,
                    showsHeader: false
                )
                .transition(reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct ToolRunDetail: View {
    let name: String
    let inputJSON: String
    let result: ToolRunResult?
    let showsHeader: Bool

    private var isRunning: Bool { result == nil }
    private var statusIcon: String {
        guard let result else { return "circle.dotted" }
        return result.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    }
    private var statusTint: Color {
        guard let result else { return AppTheme.Text.mutedColor }
        return result.isError
            ? AppTheme.Status.warningColor.opacity(AppTheme.Opacity.prominent)
            : AppTheme.Text.tertiaryColor
    }
    private var showsGenerationImage: Bool {
        switch ToolRunPresentation.baseName(for: name) {
        case ToolName.generateImage.rawValue, ToolName.upscaleMedia.rawValue:
            return result?.content.contains(where: {
                if case .image = $0 { return true }
                return false
            }) == true
        default:
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if showsHeader {
                HStack(spacing: AppTheme.Spacing.sm) {
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: AppTheme.Spacing.md, height: AppTheme.Spacing.md)
                    } else {
                        Image(systemName: statusIcon)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(statusTint)
                    }
                    Text(ToolRunPresentation.label(for: name))
                        .font(.system(
                            size: AppTheme.FontSize.sm,
                            weight: AppTheme.FontWeight.medium
                        ))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            Text(name)
                .font(.system(size: AppTheme.FontSize.xxs, design: .monospaced))
                .foregroundStyle(AppTheme.Text.mutedColor)
            argsSection
            if let result { resultSection(result) }
        }
        .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
        .foregroundStyle(AppTheme.Text.tertiaryColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.subtle))
        )
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var argsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("args").font(.system(size: AppTheme.FontSize.xxs)).foregroundStyle(AppTheme.Text.mutedColor)
            Text(prettyPrinted(inputJSON))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func resultSection(_ r: ToolRunResult) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(r.isError ? "error" : "result")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(
                    r.isError
                        ? AppTheme.Status.errorColor.opacity(AppTheme.Opacity.prominent)
                        : AppTheme.Text.mutedColor
                )
            ForEach(Array(r.content.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let s):
                    Text(s).frame(maxWidth: .infinity, alignment: .leading)
                case .image(let base64, _):
                    if !showsGenerationImage {
                        ToolResultImageView(base64: base64)
                    }
                }
            }
        }
    }

    private func prettyPrinted(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let s = String(data: pretty, encoding: .utf8),
              !s.isEmpty, s != "{}" else {
            return "(no args)"
        }
        return s
    }
}

private struct ToolResultImageView: View {
    let base64: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: AppTheme.ComponentSize.toolImagePreviewMaxHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
            } else {
                Text("(image payload)").foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .task(id: base64) {
            guard image == nil else { return }
            let data = await Task.detached { Data(base64Encoded: base64) }.value
            if let data { image = NSImage(data: data) }
        }
    }
}
