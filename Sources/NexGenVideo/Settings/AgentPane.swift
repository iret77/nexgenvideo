import AppKit
import SwiftUI

@MainActor
struct ExternalMcpServerEditorState: Equatable {
    enum Mode: Equatable {
        case adding
        case editing(originalName: String, canPreserveConfiguration: Bool)
    }

    var mode: Mode?
    var name = ""
    var connection = ""

    var isPresented: Bool { mode != nil }

    var importsMultipleServers: Bool {
        guard case .success(let parsed) = ExternalMcpServers.parseUserInput(connection) else { return false }
        return parsed.entries.count > 1
    }

    var importCount: Int {
        guard case .success(let parsed) = ExternalMcpServers.parseUserInput(connection) else { return 0 }
        return parsed.entries.count
    }

    var nameHint: String? {
        guard let hint = ExternalMcpServers.nameHint(fromUserInput: connection),
              ExternalMcpServers.isValidName(hint),
              hint.caseInsensitiveCompare("nexgen") != .orderedSame
        else { return nil }
        return hint
    }

    mutating func beginAdding() {
        mode = .adding
        name = ""
        connection = ""
    }

    mutating func beginEditing(_ entry: ExternalMcpServers.SettingsEntry) {
        mode = .editing(
            originalName: entry.name,
            canPreserveConfiguration: entry.canPreserveConfiguration
        )
        name = entry.name
        connection = ""
    }

    mutating func useNameHint() {
        guard let nameHint else { return }
        name = nameHint
    }

    mutating func cancel() {
        mode = nil
        name = ""
        connection = ""
    }

    func validationMessage(existingNames: Set<String>) -> String? {
        guard isPresented else { return nil }
        switch operation(existingNames: existingNames) {
        case .success:
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }

    func operation(
        existingNames: Set<String>
    ) -> Result<ExternalMcpServers.SaveOperation, ExternalMcpServers.ValidationError> {
        switch mode {
        case .adding:
            return ExternalMcpServers.makeOperation(
                input: connection,
                manualName: name,
                existingNames: existingNames,
                editingOriginalName: nil,
                canPreserveOriginal: false
            )
        case .editing(let originalName, let canPreserveConfiguration):
            return ExternalMcpServers.makeOperation(
                input: connection,
                manualName: name,
                existingNames: existingNames,
                editingOriginalName: originalName,
                canPreserveOriginal: canPreserveConfiguration
            )
        case .none:
            return .failure(.missingConnection)
        }
    }
}

struct AgentPane: View {
    @Bindable private var appState = AppState.shared
    @State private var backend = AgentBackendPreference.selected
    @State private var claudeStatus: ClaudeCodeLocator.Status?
    @State private var isCheckingClaude = false
    @State private var hasKey = false
    @State private var maskedKey = ""
    @State private var draft = ""
    @State private var externalMcpServers: [ExternalMcpServers.SettingsEntry] = []
    @State private var externalMcpEditor = ExternalMcpServerEditorState()
    @State private var pendingExternalMcpRemoval: String?
    @State private var pendingExternalMcpTrust: PendingExternalMcpTrust?
    @State private var externalMcpError: String?
    @FocusState private var isFocused: Bool
    @FocusState private var externalMcpField: ExternalMcpField?

    @AppStorage(CostGuard.autoApproveKey) private var autoApproveCredits = 0

    private let consoleURL = URL(string: "https://platform.claude.com/settings/keys")!
    private let installationURL = URL(string: "https://code.claude.com/docs/en/setup")!

    private enum ExternalMcpField: Hashable {
        case name
        case connection
    }

    private struct PendingExternalMcpTrust: Identifiable {
        let id = UUID()
        let operation: ExternalMcpServers.SaveOperation
        let request: ExternalMcpServers.TrustRequest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            runtimeSection
            renderApprovalSection
            mcpSection
            externalMcpSection
        }
        .onAppear {
            backend = AgentBackendPreference.selected
            refreshKey()
            refreshExternalMcpServers()
        }
        .task {
            if backend == .claudeCode {
                await checkClaude()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeCodeStatusChanged)) { notification in
            guard let status = notification.object as? ClaudeCodeLocator.Status else { return }
            claudeStatus = status
        }
        .confirmationDialog(
            "Remove external MCP server?",
            isPresented: Binding(
                get: { pendingExternalMcpRemoval != nil },
                set: { if !$0 { pendingExternalMcpRemoval = nil } }
            ),
            presenting: pendingExternalMcpRemoval
        ) { name in
            Button("Remove “\(name)”", role: .destructive) {
                removeExternalMcpServer(name)
            }
            Button("Cancel", role: .cancel) {}
        } message: { name in
            Text("“\(name)” will no longer be available to new Claude Code sessions.")
        }
        .alert(
            "Trust Local MCP Software?",
            isPresented: Binding(
                get: { pendingExternalMcpTrust != nil },
                set: { if !$0 { pendingExternalMcpTrust = nil } }
            ),
            presenting: pendingExternalMcpTrust
        ) { pending in
            Button("Trust and Save") {
                applyExternalMcpOperation(pending.operation, trustingStdio: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.request.message)
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
                HStack(spacing: AppTheme.Spacing.sm) {
                    SettingsStatusBadge(text: claudeStatusLabel, tone: claudeStatusTone)
                    Button("Check again") {
                        Task { await checkClaude() }
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.small)
                    .disabled(isCheckingClaude)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.md)

            if !isCheckingClaude && claudeStatus?.found == false {
                SettingsDivider()
                HStack {
                    Button("Installation guide") { NSWorkspace.shared.open(installationURL) }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .controlSize(.small)
                    Spacer(minLength: AppTheme.Spacing.lg)
                }
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.vertical, AppTheme.Spacing.smMd)
            }

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

    private var externalMcpSection: some View {
        SettingsSection(
            "External MCP Servers",
            subtitle: "Stored securely for new Claude Code sessions. Changes apply when the next session starts."
        ) {
            SettingsCard {
                if let externalMcpError {
                    SettingsNotice(
                        text: externalMcpError,
                        systemImage: "exclamationmark.triangle",
                        tone: .error
                    )
                    SettingsDivider()
                }
                if externalMcpServers.isEmpty && !externalMcpEditor.isPresented {
                    SettingsRow(
                        title: "No external MCP servers",
                        subtitle: "Add a server URL, command, or MCP configuration."
                    ) {
                        Button("Add Server") { beginAddingExternalMcpServer() }
                            .buttonStyle(.capsule(.prominent, size: .regular))
                            .controlSize(.small)
                    }
                } else {
                    ForEach(Array(externalMcpServers.enumerated()), id: \.element.id) { index, server in
                        if index > 0 {
                            SettingsDivider()
                        }
                        externalMcpServerRow(server)
                    }
                    if !externalMcpServers.isEmpty {
                        SettingsDivider()
                    }
                    if externalMcpEditor.isPresented {
                        externalMcpEditorView
                    } else {
                        HStack {
                            Button("Add Server") { beginAddingExternalMcpServer() }
                                .buttonStyle(.capsule(.secondary, size: .regular))
                                .controlSize(.small)
                            Spacer(minLength: AppTheme.Spacing.lg)
                        }
                        .padding(.horizontal, AppTheme.Spacing.mdLg)
                        .padding(.vertical, AppTheme.Spacing.smMd)
                    }
                }
            }
        }
    }

    private func externalMcpServerRow(_ entry: ExternalMcpServers.SettingsEntry) -> some View {
        SettingsRow(
            title: entry.name,
            subtitle: entry.preview
        ) {
            HStack(spacing: AppTheme.Spacing.sm) {
                switch entry.status {
                case .ready:
                    EmptyView()
                case .trustRequired:
                    SettingsStatusBadge(text: "Trust required", tone: .warning)
                case .needsRepair:
                    SettingsStatusBadge(text: "Needs repair", tone: .warning)
                }
                Button(externalMcpEditLabel(entry)) { beginEditingExternalMcpServer(entry) }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.small)
                    .disabled(externalMcpEditor.isPresented)
                Button {
                    pendingExternalMcpRemoval = entry.name
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.small)
                .disabled(externalMcpEditor.isPresented)
                .help("Remove \(entry.name)")
            }
        }
    }

    private func externalMcpEditLabel(_ entry: ExternalMcpServers.SettingsEntry) -> String {
        switch entry.status {
        case .ready: return "Edit"
        case .trustRequired: return "Review"
        case .needsRepair: return "Repair"
        }
    }

    private var externalMcpEditorView: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(externalMcpEditorTitle)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            if externalMcpEditor.importsMultipleServers {
                SettingsNotice(
                    text: "Imports \(externalMcpEditor.importCount) named servers from this configuration.",
                    systemImage: "square.stack.3d.up",
                    tone: .neutral
                )
            } else {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Name")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    TextField("server-name", text: $externalMcpEditor.name)
                        .textFieldStyle(.plain)
                        .focused($externalMcpField, equals: .name)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .onSubmit(saveExternalMcpServer)
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.smMd)
                        .background(externalMcpFieldBackground)
                        .overlay(externalMcpFieldBorder(isFocused: externalMcpField == .name))
                }
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Connection")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                TextField(
                    externalMcpConnectionPlaceholder,
                    text: $externalMcpEditor.connection,
                    axis: .vertical
                )
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .focused($externalMcpField, equals: .connection)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .background(externalMcpFieldBackground)
                .overlay(externalMcpFieldBorder(isFocused: externalMcpField == .connection))
            }

            if let hint = externalMcpEditor.nameHint,
               hint != externalMcpEditor.name.trimmingCharacters(in: .whitespacesAndNewlines) {
                Button("Use suggested name “\(hint)”") {
                    externalMcpEditor.useNameHint()
                    externalMcpField = .name
                }
                .buttonStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Accent.primary)
            }

            if let validationMessage = externalMcpValidationMessage,
               !externalMcpEditor.name.isEmpty || !externalMcpEditor.connection.isEmpty {
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(validationMessage)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Status.errorColor)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Spacer(minLength: AppTheme.Spacing.lg)
                Button("Cancel") { cancelExternalMcpEditor() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.small)
                Button(externalMcpEditor.importsMultipleServers ? "Import" : "Save") {
                    saveExternalMcpServer()
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.small)
                .disabled(
                    externalMcpValidationMessage != nil
                        || externalMcpOperation == nil
                )
            }
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    private var externalMcpEditorTitle: String {
        switch externalMcpEditor.mode {
        case .some(.editing): return "Edit Server"
        case .some(.adding), .none: return "Add Server"
        }
    }

    private var externalMcpConnectionPlaceholder: String {
        guard case .some(.editing(_, let canPreserveConfiguration)) = externalMcpEditor.mode else {
            return "HTTPS URL, command, MCP entry, or mcpServers JSON"
        }
        return canPreserveConfiguration
            ? "Stored securely — paste a replacement to change it"
            : "Paste a valid replacement configuration"
    }

    private var externalMcpOperation: ExternalMcpServers.SaveOperation? {
        guard case .success(let operation) = externalMcpEditor.operation(
            existingNames: Set(externalMcpServers.map(\.name))
        ) else { return nil }
        return operation
    }

    private var externalMcpValidationMessage: String? {
        externalMcpEditor.validationMessage(existingNames: Set(externalMcpServers.map(\.name)))
    }

    private var externalMcpFieldBackground: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .fill(AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.muted))
    }

    private func externalMcpFieldBorder(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(
                isFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                lineWidth: AppTheme.BorderWidth.thin
            )
    }

    private func refreshExternalMcpServers() {
        externalMcpServers = ExternalMcpServers.settingsEntries()
    }

    private func beginAddingExternalMcpServer() {
        externalMcpError = nil
        externalMcpEditor.beginAdding()
        externalMcpField = .name
    }

    private func beginEditingExternalMcpServer(_ entry: ExternalMcpServers.SettingsEntry) {
        externalMcpError = nil
        externalMcpEditor.beginEditing(entry)
        externalMcpField = .name
    }

    private func cancelExternalMcpEditor() {
        externalMcpEditor.cancel()
        externalMcpField = nil
    }

    private func saveExternalMcpServer() {
        guard let operation = externalMcpOperation else { return }
        if let request = ExternalMcpServers.trustRequest(for: operation) {
            pendingExternalMcpTrust = PendingExternalMcpTrust(operation: operation, request: request)
        } else {
            applyExternalMcpOperation(operation, trustingStdio: false)
        }
    }

    private func applyExternalMcpOperation(
        _ operation: ExternalMcpServers.SaveOperation,
        trustingStdio: Bool
    ) {
        do {
            try ExternalMcpServers.apply(operation, trustingStdio: trustingStdio)
            pendingExternalMcpTrust = nil
            externalMcpError = nil
            cancelExternalMcpEditor()
            refreshExternalMcpServers()
        } catch {
            pendingExternalMcpTrust = nil
            externalMcpError = error.localizedDescription
        }
    }

    private func removeExternalMcpServer(_ name: String) {
        ExternalMcpServers.remove(name: name)
        pendingExternalMcpRemoval = nil
        externalMcpError = nil
        refreshExternalMcpServers()
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
