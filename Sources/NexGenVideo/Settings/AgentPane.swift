import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared
    @State private var backend = AgentBackendPreference.selected
    @State private var claudeStatus: ClaudeCodeLocator.Status?
    @State private var isCheckingClaude = false
    @State private var hasKey = false
    @State private var maskedKey = ""
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    @AppStorage(CostGuard.autoApproveKey) private var autoApproveCredits = 0

    private let consoleURL = URL(string: "https://platform.claude.com/settings/keys")!
    private let installationURL = URL(string: "https://code.claude.com/docs/en/setup")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            runtimeSection
            renderApprovalSection
            mcpSection
        }
        .onAppear {
            backend = AgentBackendPreference.selected
            refreshKey()
        }
        .task {
            if backend == .claudeCode {
                await checkClaude()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeCodeStatusChanged)) { notification in
            guard let status = notification.object as? ClaudeCodeLocator.Status else { return }
            claudeStatus = status
            isCheckingClaude = false
        }
    }

    private var runtimeSection: some View {
        SettingsSection(
            "Agent Runtime",
            subtitle: "Choose one backend for the in-app agent. Provider connections for generated media remain separate."
        ) {
            SettingsCard {
                SettingsRow(
                    title: "Run agent with",
                    subtitle: backend == .claudeCode
                        ? "Uses your signed-in Claude subscription."
                        : "Uses your Anthropic API account."
                ) {
                    Picker("Agent runtime", selection: $backend) {
                        ForEach(AgentBackend.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .onChange(of: backend) { _, newValue in
                        appState.setAgentBackend(newValue)
                        if newValue == .claudeCode {
                            Task { await checkClaude() }
                        }
                    }
                }
                SettingsDivider()
                if backend == .claudeCode {
                    claudeCodeConfiguration
                } else {
                    anthropicConfiguration
                }
            }
        }
    }

    private var anthropicConfiguration: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Anthropic API")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Button(action: { NSWorkspace.shared.open(consoleURL) }) {
                        Label("Get API key", systemImage: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Accent.primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: AppTheme.Spacing.lg)
                SettingsStatusBadge(
                    text: hasKey ? "Key saved" : "Not configured",
                    tone: hasKey ? .success : .neutral
                )
            }
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.md)

            SettingsDivider()

            HStack(spacing: AppTheme.Spacing.sm) {
                SecureField(keyPlaceholder, text: $draft)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .onSubmit(saveKey)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.muted))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(
                                isFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                                lineWidth: AppTheme.BorderWidth.thin
                            )
                    )
                    .animation(.easeOut(duration: AppTheme.Anim.hover), value: isFocused)
                keyTrailingControl
            }
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.md)
        }
    }

    private var claudeCodeConfiguration: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(claudeCodeTitle)
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(claudeCodeDetail)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppTheme.Spacing.lg)
                SettingsStatusBadge(text: claudeStatusLabel, tone: claudeStatusTone)
            }
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.md)

            SettingsDivider()

            HStack(spacing: AppTheme.Spacing.sm) {
                if claudeStatus?.found != true {
                    Button("Installation guide") { NSWorkspace.shared.open(installationURL) }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .controlSize(.small)
                }
                Spacer(minLength: AppTheme.Spacing.lg)
                Button("Check again") {
                    Task { await checkClaude() }
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.small)
                .disabled(isCheckingClaude)
            }
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.smMd)

            SettingsDivider()
            SettingsNotice(
                text: "Claude Code runs headlessly with Read as its only built-in tool. Timeline changes go through NexGenVideo's local MCP tools.",
                systemImage: "lock.shield",
                tone: .neutral
            )
        }
    }

    private var claudeCodeTitle: String {
        guard let version = claudeStatus?.version else { return "Claude Code" }
        return "Claude Code \(version)"
    }

    private var claudeCodeDetail: String {
        if isCheckingClaude {
            return "Checking the installed CLI and sign-in status…"
        }
        guard claudeStatus?.found == true else {
            return "Install Claude Code, then sign in with your Claude subscription."
        }
        guard claudeStatus?.isAuthenticated == true else {
            return "Run claude auth login in Terminal, then check again."
        }
        return "Ready to run the in-app agent through your Claude subscription."
    }

    private var claudeStatusLabel: String {
        if isCheckingClaude { return "Checking" }
        guard claudeStatus?.found == true else { return "Not installed" }
        return claudeStatus?.isAuthenticated == true ? "Signed in" : "Sign-in required"
    }

    private var claudeStatusTone: SettingsTone {
        if isCheckingClaude { return .neutral }
        return claudeStatus?.isAuthenticated == true ? .success : .warning
    }

    private var renderApprovalSection: some View {
        SettingsSection(
            "Agent Render Approvals",
            subtitle: "Unknown costs always require approval."
        ) {
            SettingsCard {
                SettingsRow(
                    title: "Auto-approve paid renders",
                    subtitle: autoApproveCredits <= 0
                        ? "Ask before every paid render."
                        : "Run priced renders up to \(CostEstimator.format(autoApproveCredits)) without asking."
                ) {
                    Stepper(value: $autoApproveCredits, in: 0...1000, step: 10) {
                        Text(CostEstimator.format(autoApproveCredits))
                            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        }
    }

    private var mcpSection: some View {
        SettingsSection(
            "Local MCP Bridge",
            subtitle: "Allows supported local clients to control the open NexGenVideo project."
        ) {
            SettingsCard {
                SettingsRow(
                    title: "NexGenVideo MCP server",
                    subtitle: appState.isMCPRequiredByAgent
                        ? "Required while Claude Code is the selected agent runtime."
                        : "Listens only on this Mac at 127.0.0.1:\(String(MCPService.port))."
                ) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        SettingsStatusBadge(text: mcpStatusLabel, tone: mcpStatusTone)
                        if appState.mcpService?.lastError != nil {
                            Button("Retry") { appState.restartMCPService() }
                                .controlSize(.small)
                        }
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { appState.isMCPEnabled },
                                set: { appState.setMCPEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(appState.isMCPRequiredByAgent)
                    }
                }
                SettingsDivider()
                HStack {
                    Text("Connection setup for Claude Desktop, Claude Code, Codex, and other MCP clients.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Spacer(minLength: AppTheme.Spacing.lg)
                    Button("Setup instructions") {
                        HelpWindowController.shared.show(tab: .mcp)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.primary)
                }
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.vertical, AppTheme.Spacing.smMd)
            }
        }
    }

    private var mcpStatusLabel: String {
        if appState.mcpService?.isRunning == true { return "Running" }
        if appState.mcpService?.lastError != nil { return "Unavailable" }
        return appState.isMCPEnabled ? "Starting" : "Off"
    }

    private var mcpStatusTone: SettingsTone {
        if appState.mcpService?.isRunning == true { return .success }
        if appState.mcpService?.lastError != nil { return .error }
        return .neutral
    }

    private var keyPlaceholder: String {
        hasKey ? maskedKey : "sk-ant-…"
    }

    @ViewBuilder
    private var keyTrailingControl: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save", action: saveKey)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasKey {
            Button(action: removeKey) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help("Remove Anthropic API key")
        }
    }

    private func checkClaude() async {
        isCheckingClaude = true
        let status = await Task.detached(priority: .utility) {
            ClaudeCodeLocator.status()
        }.value
        claudeStatus = status
        isCheckingClaude = false
        NotificationCenter.default.post(name: .claudeCodeStatusChanged, object: status)
    }

    private func refreshKey() {
        let key = AnthropicKeychain.load() ?? ""
        hasKey = !key.isEmpty
        maskedKey = mask(key)
    }

    private func saveKey() {
        let key = draft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        AnthropicKeychain.save(key)
        draft = ""
        isFocused = false
        refreshKey()
    }

    private func removeKey() {
        AnthropicKeychain.delete()
        draft = ""
        refreshKey()
    }

    private func mask(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "\u{2022}", count: 32) }
        return String(repeating: "\u{2022}", count: 36) + key.suffix(4)
    }
}
