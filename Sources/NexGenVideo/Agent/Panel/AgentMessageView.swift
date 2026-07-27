import AppKit
import SwiftUI

struct AgentMessageView: View {
    let message: AgentMessage
    let toolResults: [String: ToolRunResult]
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
            VStack(spacing: AppTheme.Spacing.sm) {
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
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    MarkdownText(text: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .toolUse(let id, let name, let inputJSON):
                    // show_blocks renders as native UI, not as a tool row (#135). A call the
                    // strict parser rejects falls back to the row — its expanded detail carries
                    // the violation the model was told about.
                    if ToolRunPresentation.baseName(for: name) == ToolName.showBlocks.rawValue,
                       let blocks = Self.parsedBlocks(inputJSON) {
                        AgentBlocksView(blocks: blocks)
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
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovering)
    }

    /// Blocks from a show_blocks tool-use payload, nil when the JSON or the strict
    /// block schema doesn't hold (→ tool-row fallback).
    private static func parsedBlocks(_ inputJSON: String) -> [AgentBlock]? {
        guard let data = inputJSON.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return try? AgentBlocks.parse(args)
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
    @State private var expanded = false

    private var hasError: Bool {
        activity.steps.contains { toolResults[$0.id]?.isError == true }
    }

    private var hasIncompleteStep: Bool {
        !activity.isRunning && activity.steps.contains { toolResults[$0.id] == nil }
    }

    private var label: String {
        activity.currentStatus
            ?? activity.steps.last.map { ToolRunPresentation.label(for: $0.name) }
            ?? "Working"
    }

    private var accessibilityState: String {
        if activity.isRunning { return "Working" }
        if hasError { return "Failed" }
        if hasIncompleteStep { return "Incomplete" }
        return "Completed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Button {
                withAnimation(.easeOut(duration: AppTheme.Anim.hover)) { expanded.toggle() }
            } label: {
                HStack(spacing: AppTheme.Spacing.sm) {
                    statusIcon
                    Text(label)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                    Spacer(minLength: AppTheme.Spacing.sm)
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(accessibilityState): \(label)")

            if expanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    if activity.statuses.count > 1 {
                        ForEach(Array(activity.statuses.dropLast().enumerated()), id: \.offset) { _, status in
                            Text(status)
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        }
                    }
                    ForEach(activity.steps) { step in
                        ToolRunRow(
                            name: step.name,
                            inputJSON: step.inputJSON,
                            result: toolResults[step.id]
                        )
                    }
                }
                .padding(.leading, AppTheme.Spacing.xxs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: label)
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
}

private struct ToolRunRow: View {
    let name: String
    let inputJSON: String
    let result: ToolRunResult?
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
                withAnimation(.easeOut(duration: AppTheme.Anim.hover)) { expanded.toggle() }
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

            if expanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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
                    ToolResultImageView(base64: base64)
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
