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

@MainActor
struct AgentSettingsServices {
    let backend: () -> AgentBackend
    let setBackend: (AgentBackend) -> Void
    let loadKey: () -> String?
    let saveKey: (String) -> Bool
    let deleteKey: () -> Bool
    let checkClaude: () async -> ClaudeCodeLocator.Status
    let mcpRequired: () -> Bool
    let mcpEnabled: () -> Bool
    let mcpRunning: () -> Bool
    let mcpError: () -> String?
    let setMCPEnabled: (Bool) -> Void
    let retryMCP: () -> Void

    static var live: Self {
        .init(backend: { AgentBackendPreference.selected }, setBackend: { AppState.shared.setAgentBackend($0) },
            loadKey: { AnthropicKeychain.load() }, saveKey: { AnthropicKeychain.save($0) }, deleteKey: { AnthropicKeychain.delete() },
            checkClaude: { await Task.detached(priority: .utility) { ClaudeCodeLocator.status() }.value },
            mcpRequired: { AppState.shared.isMCPRequiredByAgent }, mcpEnabled: { AppState.shared.isMCPEnabled },
            mcpRunning: { AppState.shared.mcpService?.isRunning == true }, mcpError: { AppState.shared.mcpService?.lastError },
            setMCPEnabled: { AppState.shared.setMCPEnabled($0) }, retryMCP: { AppState.shared.restartMCPService() })
    }
}

struct AgentPane: View {
    private let services: AgentSettingsServices
    private let mcpDependencies: ExternalMcpServers.Dependencies
    @State private var backend: AgentBackend
    @State private var claudeStatus: ClaudeCodeLocator.Status?
    @State private var isCheckingClaude = false
    @State private var hasKey = false
    @State private var maskedKey = ""
    @State private var draft = ""
    @State private var keyError: String?
    @State private var externalMcpServers: [ExternalMcpServers.SettingsEntry] = []
    @State private var externalMcpEditor = ExternalMcpServerEditorState()
    @State private var pendingExternalMcpRemoval: String?
    @State private var pendingExternalMcpTrust: PendingExternalMcpTrust?
    @State private var externalMcpError: String?
    @FocusState private var isFocused: Bool
    @FocusState private var externalMcpField: ExternalMcpField?

    @AppStorage(CostGuard.autoApproveKey) private var autoApproveCredits = 0

    init(services: AgentSettingsServices = .live, mcpDependencies: ExternalMcpServers.Dependencies = .live,
         defaults: UserDefaults = .standard) {
        self.services = services; self.mcpDependencies = mcpDependencies
        _backend = State(initialValue: services.backend())
        _autoApproveCredits = AppStorage(wrappedValue: 0, CostGuard.autoApproveKey, store: defaults)
    }

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
            backend = services.backend()
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
                    subtitle: runtimeSubtitle
                ) {
                    Picker("Agent runtime", selection: $backend) {
                        ForEach(AgentBackend.selectableCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .reviewAcceptanceProbe("settings.agent.backend", text: backend.displayName)
                    .fixedSize()
                    .onChange(of: backend) { _, newValue in
                        services.setBackend(newValue)
                        if newValue == .claudeCode {
                            Task { await checkClaude() }
                        }
                    }
                }
                SettingsDivider()
                if backend == .claudeCode {
                    claudeCodeConfiguration
                } else if backend == .codexAppServer {
                    codexConfiguration
                } else {
                    anthropicConfiguration
                }
            }
        }
    }

    private var runtimeSubtitle: String {
        switch backend {
        case .claudeCode:
            "Uses your signed-in Claude subscription."
        case .anthropicAPI:
            "Uses your Anthropic API account."
        case .codexAppServer:
            "Uses an isolated Codex account."
        }
    }

    private var codexConfiguration: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            SettingsRow(
                title: "Codex App Server \(CodexAppServerContract.cliVersion)",
                subtitle: "Uses a dedicated credential home and transcript replay. Personal Codex settings and chats are not loaded."
            ) {
                SettingsStatusBadge(text: "Incompatible", tone: .warning)
            }
            SettingsDivider()
            SettingsNotice(
                text: "Codex remains unavailable until configuration isolation, transcript replay, and its model-visible tools pass approved Actions acceptance. Account setup is not available in Settings.",
                systemImage: "lock.shield",
                tone: .neutral
            )
        }
    }

    private var anthropicConfiguration: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            SettingsRow(title: "Anthropic API") {
                Button("Get API key", systemImage: "arrow.up.right") { NSWorkspace.shared.open(consoleURL) }
                SettingsStatusBadge(text: hasKey ? "Key saved" : "Not configured", tone: hasKey ? .success : .neutral)
            }

            SettingsDivider()

            HStack(spacing: AppTheme.Spacing.sm) {
                SecureField(keyPlaceholder, text: $draft)
                    .reviewAcceptanceProbe("settings.agent.key")
                    .accessibilityLabel("Anthropic API key")
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
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
            .padding(.horizontal, AppTheme.Spacing.lgXl)
            .padding(.vertical, AppTheme.Spacing.md)
            if let keyError {
                SettingsNotice(text: keyError, systemImage: "exclamationmark.triangle", tone: .error)
                    .reviewAcceptanceProbe("settings.agent.key.error", text: keyError)
            }
        }
    }

    private var claudeCodeConfiguration: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            SettingsRow(title: claudeCodeTitle, subtitle: claudeCodeDetail) {
                SettingsStatusBadge(text: claudeStatusLabel, tone: claudeStatusTone)
                Button("Check again") { Task { await checkClaude() } }
                    .reviewAcceptanceProbe("settings.agent.check")
                    .disabled(isCheckingClaude)
            }

            if !isCheckingClaude && claudeStatus?.found == false {
                SettingsDivider()
                SettingsRow(title: "Install Claude Code") {
                    Button("Installation guide") { NSWorkspace.shared.open(installationURL) }
                }
            }

            SettingsDivider()
            SettingsNotice(
                text: "The agent edits the project through NexGenVideo’s tools. Paid generation follows your approval settings.",
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
                            .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    .controlSize(.small)
                    .reviewAcceptanceProbe("settings.agent.approvals", text: String(autoApproveCredits))
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
                    subtitle: services.mcpRequired()
                        ? "Required while Claude Code is the selected agent runtime."
                        : "Listens only on this Mac at 127.0.0.1:\(String(MCPService.port))."
                ) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        SettingsStatusBadge(text: mcpStatusLabel, tone: mcpStatusTone)
                        if services.mcpError() != nil {
                            Button("Retry") { services.retryMCP() }
                                .controlSize(.small)
                        }
                        Toggle(
                            "Enable NexGenVideo MCP server",
                            isOn: Binding(
                                get: { services.mcpEnabled() },
                                set: { services.setMCPEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(services.mcpRequired())
                        .reviewAcceptanceProbe("settings.agent.mcp", text: String(services.mcpEnabled()))
                    }
                }
                SettingsDivider()
                SettingsRow(title: "Connect an MCP client", subtitle: "Setup for Claude Desktop, Claude Code, Codex, and other clients.") {
                    Button("Setup instructions") { HelpWindowController.shared.show(tab: .mcp) }
                }
            }
        }
    }

    private var mcpStatusLabel: String {
        if services.mcpRunning() { return "Running" }
        if services.mcpError() != nil { return "Unavailable" }
        return services.mcpEnabled() ? "Starting" : "Off"
    }

    private var mcpStatusTone: SettingsTone {
        if services.mcpRunning() { return .success }
        if services.mcpError() != nil { return .error }
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
                            .reviewAcceptanceProbe("settings.mcp.add")
                            .buttonStyle(.capsule(.prominent, size: .regular))
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
                                .reviewAcceptanceProbe("settings.mcp.add")
                                .buttonStyle(.capsule(.secondary, size: .regular))
                            Spacer(minLength: AppTheme.Spacing.lg)
                        }
                        .padding(.horizontal, AppTheme.Spacing.lgXl)
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
                    .reviewAcceptanceProbe("settings.mcp.edit." + entry.name)
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .disabled(externalMcpEditor.isPresented)
                Button("Remove", role: .destructive) {
                    pendingExternalMcpRemoval = entry.name
                }
                .reviewAcceptanceProbe("settings.mcp.remove." + entry.name)
                .buttonStyle(.capsule(.secondary, size: .regular))
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
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
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
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    TextField("server-name", text: $externalMcpEditor.name)
                        .reviewAcceptanceProbe("settings.mcp.name", text: externalMcpEditor.name)
                        .textFieldStyle(.plain)
                        .focused($externalMcpField, equals: .name)
                        .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
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
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                TextField(
                    externalMcpConnectionPlaceholder,
                    text: $externalMcpEditor.connection,
                    axis: .vertical
                )
                .lineLimit(2...6)
                .reviewAcceptanceProbe("settings.mcp.connection")
                .textFieldStyle(.plain)
                .focused($externalMcpField, equals: .connection)
                .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
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
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Accent.primary)
            }

            if let validationMessage = externalMcpValidationMessage,
               !externalMcpEditor.name.isEmpty || !externalMcpEditor.connection.isEmpty {
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(validationMessage)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Status.errorColor)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Spacer(minLength: AppTheme.Spacing.lg)
                Button("Cancel") { cancelExternalMcpEditor() }
                    .reviewAcceptanceProbe("settings.mcp.cancel")
                    .buttonStyle(.capsule(.secondary, size: .regular))
                Button(externalMcpEditor.importsMultipleServers ? "Import" : "Save") {
                    saveExternalMcpServer()
                }
                .reviewAcceptanceProbe("settings.mcp.save")
                .buttonStyle(.capsule(.prominent, size: .regular))
                .disabled(
                    externalMcpValidationMessage != nil
                        || externalMcpOperation == nil
                )
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
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
        externalMcpServers = ExternalMcpServers.settingsEntries(dependencies: mcpDependencies)
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
        if let request = ExternalMcpServers.trustRequest(for: operation, dependencies: mcpDependencies) {
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
            try ExternalMcpServers.apply(operation, trustingStdio: trustingStdio, dependencies: mcpDependencies)
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
        ExternalMcpServers.remove(name: name, dependencies: mcpDependencies)
        pendingExternalMcpRemoval = nil
        externalMcpError = nil
        refreshExternalMcpServers()
    }

    private var keyPlaceholder: String {
        hasKey ? maskedKey : "sk-ant-…"
    }

    @ViewBuilder
    private var keyTrailingControl: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Button("Save", action: saveKey)
                .reviewAcceptanceProbe("settings.agent.key.save")
                .buttonStyle(.capsule(.prominent, size: .regular))
        } else if hasKey {
            Button("Remove", role: .destructive, action: removeKey)
            .reviewAcceptanceProbe("settings.agent.key.remove")
            .buttonStyle(.capsule(.secondary, size: .regular))
            .help("Remove Anthropic API key")
        }
    }

    private func checkClaude() async {
        isCheckingClaude = true
        let status = await services.checkClaude()
        claudeStatus = status
        isCheckingClaude = false
        NotificationCenter.default.post(name: .claudeCodeStatusChanged, object: status)
    }

    private func refreshKey() {
        let key = services.loadKey() ?? ""
        hasKey = !key.isEmpty
        maskedKey = mask(key)
    }

    private func saveKey() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard services.saveKey(key) else { keyError = "The key could not be saved in Keychain. Try again."; return }
        keyError = nil
        draft = ""
        isFocused = false
        refreshKey()
    }

    private func removeKey() {
        guard services.deleteKey() else { keyError = "The key could not be removed from Keychain. Try again."; return }
        keyError = nil
        draft = ""
        refreshKey()
    }

    private func mask(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "\u{2022}", count: 32) }
        return String(repeating: "\u{2022}", count: 36) + key.suffix(4)
    }
}
