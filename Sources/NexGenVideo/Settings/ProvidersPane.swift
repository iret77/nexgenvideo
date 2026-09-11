import AppKit
import AuthenticationServices
import SwiftUI

struct ProvidersPane: View {
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var connection: [String: ProviderConnectionSnapshot] = [:]
    @State private var draft: [String: String] = [:]
    @State private var signingIn: String?
    @State private var signInTask: Task<Void, Never>?
    @State private var errorText: [String: String] = [:]
    @FocusState private var focusedProvider: String?
    private var catalog = ModelCatalog.shared

    @AppStorage(PromptCompiler.rawPromptsDefaultsKey) private var allowRawPrompts = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            SettingsSection(
                "Connections",
                subtitle: "API keys and sign-ins are stored in the macOS Keychain."
            ) {
                VStack(spacing: AppTheme.Spacing.smMd) {
                    ForEach(GenerationProvider.allCases) { provider in
                        providerSection(provider)
                    }
                }
            }
            SettingsSection("Prompt Processing") {
                SettingsCard {
                    SettingsToggleRow(
                        title: "Allow raw prompts",
                        subtitle: "Send text directly to generation models without NexGenVideo's translation, context, or consistency passes.",
                        isOn: $allowRawPrompts
                    )
                    if allowRawPrompts {
                        SettingsDivider()
                        SettingsNotice(
                            text: "Prompt safeguards are bypassed for raw generation requests.",
                            systemImage: "exclamationmark.triangle",
                            tone: .warning
                        )
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .providerKeysChanged)) { _ in
            refresh()
        }
        .onDisappear {
            signInTask?.cancel()
            signInTask = nil
            signingIn = nil
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: GenerationProvider) -> some View {
        SettingsCard {
            providerHeader(provider)
            SettingsDivider()
            switch primaryStyle(provider) {
            case .oauth: oauthControl(provider)
            case .localApp: localAppControl(provider)
            case .apiKey: keyField(provider)
            }
            if let err = errorText[provider.id] {
                SettingsDivider()
                SettingsNotice(text: err, systemImage: "exclamationmark.triangle", tone: .error)
            }
        }
    }

    private enum Style { case oauth, localApp, apiKey }
    private func primaryStyle(_ p: GenerationProvider) -> Style {
        switch p.mcpCapability?.auth {
        case .oauth: return .oauth
        case .localApp: return .localApp
        case .none: return .apiKey
        }
    }

    private func isReady(_ p: GenerationProvider) -> Bool {
        switch primaryStyle(p) {
        case .oauth:
            switch catalog.providerDiscovery[p] {
            case .ready, .stale: return true
            case .checking, .inactive, .none: return connectionState(p).oauthConnected
            case .actionRequired, .unavailable: return false
            }
        case .localApp: return connectionState(p).localEnabled
        case .apiKey:
            switch catalog.providerDiscovery[p] {
            case .unavailable, .actionRequired: return false
            case .inactive, .checking, .ready, .stale, .none: return connectionState(p).hasKey
            }
        }
    }

    private func providerHeader(_ provider: GenerationProvider) -> some View {
        SettingsRow(title: provider.displayName, subtitle: provider.modalities) {
            linkButton(provider)
            statusPill(provider)
        }
    }

    private func linkButton(_ provider: GenerationProvider) -> some View {
        Button(action: { NSWorkspace.shared.open(provider.keysURL) }) {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Text(primaryStyle(provider) == .apiKey ? "Get key" : "Website")
                Image(systemName: "arrow.up.right").interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
            }
            .interfaceFont(size: AppTheme.Typography.ui)
            .foregroundStyle(AppTheme.Accent.primary)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func statusPill(_ provider: GenerationProvider) -> some View {
        let ready = isReady(provider)
        let label: String
        let tone: SettingsTone
        switch primaryStyle(provider) {
        case .oauth:
            switch catalog.providerDiscovery[provider] {
            case .checking: (label, tone) = ("Checking…", .neutral)
            case .actionRequired: (label, tone) = ("Sign in again", .warning)
            case .unavailable: (label, tone) = ("Connection failed", .error)
            case .stale: (label, tone) = ("Refresh pending", .warning)
            case .ready: (label, tone) = ("Signed in", .success)
            case .inactive, .none:
                (label, tone) = ready ? ("Signed in", .success) : ("Not configured", .neutral)
            }
        case .localApp:
            (label, tone) = ready ? ("Enabled", .success) : ("Disabled", .neutral)
        case .apiKey:
            switch catalog.providerDiscovery[provider] {
            case .checking where connectionState(provider).hasKey:
                (label, tone) = ("Checking…", .neutral)
            case .unavailable where connectionState(provider).hasKey:
                (label, tone) = ("Connection failed", .error)
            case .actionRequired where connectionState(provider).hasKey:
                (label, tone) = ("Key rejected", .error)
            case .stale where connectionState(provider).hasKey:
                (label, tone) = ("Refresh pending", .warning)
            default:
                (label, tone) = ready ? ("Key saved", .success) : ("Not configured", .neutral)
            }
        }
        return SettingsStatusBadge(text: label, tone: tone)
    }

    @ViewBuilder
    private func oauthControl(_ provider: GenerationProvider) -> some View {
        let connected = connectionState(provider).oauthConnected
        let discovery = catalog.providerDiscovery[provider]
        SettingsRow(title: "Account", subtitle: provider.mcpCapability?.note) {
            if signingIn == provider.id {
                ProgressView().controlSize(.small)
                Text("Signing in…")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else if connected {
                if case .unavailable = discovery {
                    Button("Sign in again") { signIn(provider) }
                        .buttonStyle(.capsule(.prominent, size: .regular))
                }
                Button("Sign out") { ProviderOAuthStore.disconnect(provider); refresh() }
            } else {
                Button("Sign in") { signIn(provider) }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(signingIn != nil)
            }
        }
        if let message = discoveryMessage(discovery) {
            SettingsNotice(text: message, systemImage: "exclamationmark.triangle", tone: .warning)
        }
    }

    private func discoveryMessage(_ state: ProviderDiscoveryState?) -> String? {
        switch state {
        case .actionRequired(let message), .unavailable(let message),
             .stale(_, let message): message
        case .inactive, .checking, .ready, .none: nil
        }
    }

    private func localAppControl(_ provider: GenerationProvider) -> some View {
        SettingsRow(title: "Enable connection", subtitle: provider.mcpCapability?.note) {
            Toggle("Enable \(provider.displayName)", isOn: Binding(
                get: { connectionState(provider).localEnabled },
                set: { on in
                    ProviderMCP.setEndpoint(on ? provider.mcpCapability?.defaultURL.absoluteString : nil, for: provider)
                    refresh()
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private func keyField(_ provider: GenerationProvider) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                SecureField(placeholder(provider), text: draftBinding(provider))
                    .accessibilityLabel("\(provider.displayName) API key")
                    .textFieldStyle(.plain)
                    .focused($focusedProvider, equals: provider.id)
                    .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .onSubmit { save(provider) }
                    .padding(.horizontal, AppTheme.Spacing.md).padding(.vertical, AppTheme.Spacing.smMd)
                    .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.muted)))
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(
                        focusedProvider == provider.id ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.thin))
                trailingControl(provider)
            }
            if connectionState(provider).hasKey,
               let message = discoveryMessage(catalog.providerDiscovery[provider]) {
                Text(message)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.Spacing.lgXl)
    }

    @ViewBuilder
    private func trailingControl(_ provider: GenerationProvider) -> some View {
        let trimmed = (draft[provider.id] ?? "").trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save") { save(provider) }.buttonStyle(.capsule(.prominent, size: .regular)).controlSize(.small)
        } else if connectionState(provider).hasKey {
            Button("Remove", systemImage: "trash") { remove(provider) }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.small)
        }
    }

    private func signIn(_ provider: GenerationProvider) {
        guard signingIn == nil else { return }
        signingIn = provider.id
        errorText[provider.id] = nil
        signInTask = Task { @MainActor in
            do {
                try await ProviderOAuth.signIn(provider) { authorizationURL in
                    try await webAuthenticationSession.authenticate(
                        using: authorizationURL,
                        callback: .customScheme("nexgenvideo"),
                        preferredBrowserSession: .shared,
                        additionalHeaderFields: [:]
                    )
                }
                try Task.checkCancellation()
                refresh()
            } catch {
                guard !Task.isCancelled else { return }
                errorText[provider.id] = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            signingIn = nil
            signInTask = nil
        }
    }

    private func placeholder(_ provider: GenerationProvider) -> String {
        let state = connectionState(provider)
        return state.hasKey ? state.maskedKey : "Paste API key…"
    }

    private func draftBinding(_ provider: GenerationProvider) -> Binding<String> {
        Binding(get: { draft[provider.id] ?? "" }, set: { draft[provider.id] = $0 })
    }

    private func refresh() {
        connection = Dictionary(uniqueKeysWithValues: GenerationProvider.allCases.map { provider in
            let key = ProviderKeychain.load(provider) ?? ""
            return (
                provider.id,
                ProviderConnectionSnapshot(
                    hasKey: !key.isEmpty,
                    maskedKey: mask(key),
                    oauthConnected: ProviderOAuthStore.isConnected(provider),
                    localEnabled: ProviderMCP.configuredEndpoint(provider) != nil
                )
            )
        })
    }

    private func save(_ provider: GenerationProvider) {
        let key = (draft[provider.id] ?? "").trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        ProviderKeychain.save(key, for: provider)
        draft[provider.id] = ""
        focusedProvider = nil
        refresh()
    }

    private func remove(_ provider: GenerationProvider) {
        ProviderKeychain.delete(provider)
        draft[provider.id] = ""
        refresh()
    }

    private func mask(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "\u{2022}", count: 32) }
        return String(repeating: "\u{2022}", count: 36) + key.suffix(4)
    }

    private func connectionState(_ provider: GenerationProvider) -> ProviderConnectionSnapshot {
        connection[provider.id] ?? .empty
    }
}

private struct ProviderConnectionSnapshot {
    let hasKey: Bool
    let maskedKey: String
    let oauthConnected: Bool
    let localEnabled: Bool

    static let empty = ProviderConnectionSnapshot(
        hasKey: false,
        maskedKey: "",
        oauthConnected: false,
        localEnabled: false
    )
}
