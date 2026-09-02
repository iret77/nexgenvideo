import SwiftUI

/// Discoverable list of installed plugins and their entry-point slash-commands, so a user can start a
/// workflow without knowing the `/plugin:command` syntax. Pure render — the caller supplies the
/// discovered plugins and the run/prefill callback.
struct PluginLauncherPopover: View {
    let plugins: [PluginCommandCatalog.PluginInfo]
    let canCloseConversation: Bool
    let onRun: (PluginCommandCatalog.PluginCommand) -> Void
    let onCloseConversation: () -> Void

    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            header
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: AppTheme.BorderWidth.hairline)
            content
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: AppTheme.BorderWidth.hairline)
            closeConversationButton
        }
        .frame(width: AppTheme.ComponentSize.pluginLauncherWidth)
        .glassEffect(.clear, in: .rect(cornerRadius: AppTheme.Radius.md))
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "ellipsis")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text("More")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    @ViewBuilder
    private var content: some View {
        if plugins.allSatisfy({ $0.commands.isEmpty }) {
            Text("No workflows available")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppTheme.Spacing.md)
        } else {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
                Text("Workflows".uppercased())
                    .font(.system(
                        size: AppTheme.FontSize.xxs,
                        weight: AppTheme.FontWeight.semibold
                    ))
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.top, AppTheme.Spacing.sm)
                workflowSearch
                if filteredPlugins.isEmpty {
                    Text("No matching workflows")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .padding(AppTheme.Spacing.md)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                            ForEach(filteredPlugins) { plugin in
                                if !plugin.commands.isEmpty {
                                    pluginSection(plugin)
                                }
                            }
                        }
                        .padding(AppTheme.Spacing.sm)
                    }
                    .frame(maxHeight: AppTheme.ComponentSize.pluginLauncherMaxHeight)
                }
            }
        }
    }

    private var workflowSearch: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField("Search workflows", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs))
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private var filteredPlugins: [PluginCommandCatalog.PluginInfo] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return plugins }
        return plugins.compactMap { plugin in
            let commands = plugin.commands.filter { command in
                [command.title, command.description, command.command]
                    .compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(needle) }
            }
            guard !commands.isEmpty else { return nil }
            return PluginCommandCatalog.PluginInfo(
                name: plugin.name,
                description: plugin.description,
                commands: commands
            )
        }
    }

    private var closeConversationButton: some View {
        Button(action: onCloseConversation) {
            Label("Close conversation", systemImage: "xmark")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(!canCloseConversation)
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private func pluginSection(_ plugin: PluginCommandCatalog.PluginInfo) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(plugin.name)
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .textCase(.uppercase)
                .padding(.horizontal, AppTheme.Spacing.xs)
            ForEach(plugin.commands) { command in
                PluginCommandRow(command: command) { onRun(command) }
            }
        }
    }
}

private struct PluginCommandRow: View {
    let command: PluginCommandCatalog.PluginCommand
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text(command.title)
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        if let hint = command.argumentHint {
                            Text(hint)
                                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium).monospaced())
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                                .padding(.horizontal, AppTheme.Spacing.xs)
                                .padding(.vertical, AppTheme.Spacing.xxs)
                                .background(
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs, style: .continuous)
                                        .fill(AppTheme.Background.raisedColor)
                                )
                        }
                    }
                    if let description = command.description {
                        Text(description)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: AppTheme.Spacing.none)
                Image(systemName: command.requiresArgument ? "pencil.line" : "arrow.up")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(hovering ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(hovering ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint) : AppTheme.Background.clearColor)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(command.requiresArgument
            ? "Insert \(command.command) and fill in the argument"
            : "Run \(command.command)")
    }
}
