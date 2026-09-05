import AppKit
import SwiftUI

struct MCPInstructionsPane: View {
    private var serverURL: String { "http://127.0.0.1:\(MCPService.port)" }
    private var mcpEndpoint: String { "\(serverURL)/mcp" }

    private var claudeCodeCommand: String {
        "claude mcp add --transport http nexgen \(mcpEndpoint)"
    }

    private var codexCommand: String {
        "codex mcp add nexgen --url \(mcpEndpoint)"
    }

    private var cursorJSONConfig: String {
        """
        {
          "mcpServers": {
            "nexgen": {
              "type": "http",
              "url": "\(mcpEndpoint)"
            }
          }
        }
        """
    }

    private var claudeDesktopJSONConfig: String {
        """
        {
          "mcpServers": {
            "nexgen": {
              "command": "npx",
              "args": [
                "-y",
                "mcp-remote",
                "\(mcpEndpoint)",
                "--allow-http",
                "--transport",
                "http-only"
              ]
            }
          }
        }
        """
    }

    private var cursorDeepLink: URL? {
        let config: [String: String] = ["type": "http", "url": mcpEndpoint]
        guard
            let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
            let encoded = data.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "cursor://anysphere.cursor-deeplink/mcp/install?name=nexgen&config=\(encoded)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            serverSection
            clientSection
        }
    }

    private var serverSection: some View {
        SettingsSection(
            "Server",
            subtitle: "NexGenVideo exposes the open project on this Mac only."
        ) {
            SettingsCard {
                SettingsRow(
                    title: "Server URL",
                    subtitle: "Use this endpoint when a client asks for an MCP server address."
                ) {
                    CopyButton(value: mcpEndpoint)
                }
                SettingsDivider()
                Text(mcpEndpoint)
                    .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppTheme.Spacing.mdLg)
                    .padding(.vertical, AppTheme.Spacing.smMd)
            }
        }
    }

    private var clientSection: some View {
        SettingsSection(
            "Client Setup",
            subtitle: "Choose the client you want to connect."
        ) {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: AppTheme.ComponentSize.settingsClientCardMinWidth),
                        spacing: AppTheme.Spacing.smMd
                    ),
                ],
                alignment: .leading,
                spacing: AppTheme.Spacing.smMd
            ) {
                installClientCard(
                    title: "Cursor",
                    subtitle: "Install the NexGenVideo MCP connection.",
                    buttonLabel: "Install",
                    manualIntro: "Add this to ~/.cursor/mcp.json in your project:",
                    manualCode: cursorJSONConfig
                ) {
                    if let url = cursorDeepLink {
                        NSWorkspace.shared.open(url, configuration: .init(), completionHandler: nil)
                    }
                }

                installClientCard(
                    title: "Claude Desktop",
                    subtitle: "Install the bundled NexGenVideo connector.",
                    buttonLabel: "Install",
                    manualIntro: "Open Settings → Developer → Edit Config, then merge this into mcpServers:",
                    manualCode: claudeDesktopJSONConfig,
                    action: openClaudeDesktopBundle
                )

                commandClientCard(
                    title: "Claude Code",
                    subtitle: "Run once in Terminal.",
                    command: claudeCodeCommand
                )

                commandClientCard(
                    title: "Codex",
                    subtitle: "Run once in Terminal.",
                    command: codexCommand
                )
            }
        }
    }

    private func openClaudeDesktopBundle() {
        guard let resourceURL = Bundle.main.resourceURL else { return }
        let url = resourceURL.appendingPathComponent("nexgen.mcpb")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url, configuration: .init(), completionHandler: nil)
    }

    private func installClientCard(
        title: String,
        subtitle: String,
        buttonLabel: String,
        manualIntro: String,
        manualCode: String,
        action: @escaping () -> Void
    ) -> some View {
        SettingsCard(minHeight: AppTheme.ComponentSize.settingsClientCardMinHeight) {
            SettingsRow(title: title, subtitle: subtitle) {
                Button(buttonLabel, action: action)
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.small)
            }
            SettingsDivider()
            ManualFallback(intro: manualIntro, code: manualCode)
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.vertical, AppTheme.Spacing.smMd)
        }
    }

    private func commandClientCard(
        title: String,
        subtitle: String,
        command: String
    ) -> some View {
        SettingsCard(minHeight: AppTheme.ComponentSize.settingsClientCardMinHeight) {
            SettingsRow(title: title, subtitle: subtitle) {
                CopyButton(value: command)
            }
            SettingsDivider()
            Text(command)
                .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CodeBlockView: View {
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
            Text(content)
                .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            CopyButton(value: content)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }
}

private struct ManualFallback: View {
    let intro: String
    let code: String
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Button(action: toggle) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Manual setup")
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                }
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text(intro)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    CodeBlockView(content: code)
                }
            }
        }
        .padding(.top, AppTheme.Spacing.xxs)
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: AppTheme.Anim.hover)) {
            expanded.toggle()
        }
    }
}

private struct CopyButton: View {
    let value: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(copied ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
        }
        .buttonStyle(.capsule(.secondary, size: .regular))
        .controlSize(.small)
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(AppTheme.Anim.copyConfirmation))
            guard !Task.isCancelled else { return }
            copied = false
            resetTask = nil
        }
    }
}

#Preview {
    MCPInstructionsPane()
        .frame(width: AppTheme.ComponentSize.mcpInstructionsWindow.width, height: AppTheme.ComponentSize.mcpInstructionsWindow.height)
        .background(AppTheme.Background.surfaceColor)
}
