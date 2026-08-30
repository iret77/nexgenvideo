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
                "Connected Services",
                subtitle: "Credentials are stored in the macOS Keychain. Each provider shows only its supported connection method."
            ) {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: AppTheme.ComponentSize.settingsProviderCardMinWidth),
                            spacing: AppTheme.Spacing.smMd
                        ),
                    ],
                    alignment: .leading,
                    spacing: AppTheme.Spacing.smMd
                ) {
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
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.vertical, AppTheme.Spacing.md)
                .frame(
                    minHeight: AppTheme.ComponentSize.settingsProviderHeaderMinHeight,
                    alignment: .topLeading
                )
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
            case .ready: return true
            case .checking, .inactive, .none: return connectionState(p).oauthConnected
            case .actionRequired, .unavailable: return false
            }
        case .localApp: return connectionState(p).localEnabled
        case .apiKey:
            switch catalog.providerDiscovery[p] {
            case .unavailable, .actionRequired: return false
            case .inactive, .checking, .ready, .none: return connectionState(p).hasKey
            }
        }
    }

    private func providerHeader(_ provider: GenerationProvider) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(provider.displayName)
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                    Text(provider.modalities)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    linkButton(provider)
                }
            }
            Spacer(minLength: AppTheme.Spacing.md)
            statusPill(provider)
        }
    }

    private func linkButton(_ provider: GenerationProvider) -> some View {
        Button(action: { NSWorkspace.shared.open(provider.keysURL) }) {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Text(primaryStyle(provider) == .apiKey ? "Get key" : "Website")
                Image(systemName: "arrow.up.right").font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
            }
            .font(.system(size: AppTheme.FontSize.sm))
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
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if let note = provider.mcpCapability?.note {
                Text(note)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                if signingIn == provider.id {
                    ProgressView().controlSize(.small)
                    Text("Opening \(provider.displayName)…").font(.system(size: AppTheme.FontSize.sm)).foregroundStyle(AppTheme.Text.tertiaryColor)
                } else if connected {
                    if case .unavailable = discovery {
                        Label("Connection failed", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Status.errorColor)
                        Button("Sign in again") { signIn(provider) }
                            .buttonStyle(.capsule(.prominent, size: .regular))
                    } else {
                        Label("Signed in", systemImage: "checkmark.seal.fill")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Accent.primary)
                    }
                    Button("Sign out") { ProviderOAuthStore.disconnect(provider); refresh() }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                } else {
                    Button("Sign in with \(provider.displayName)") { signIn(provider) }
                        .buttonStyle(.capsule(.prominent, size: .regular))
                }
            }
            if let message = discoveryMessage(discovery) {
                Text(message)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.md)
        .frame(
            minHeight: AppTheme.ComponentSize.settingsProviderControlMinHeight,
            alignment: .topLeading
        )
    }

    private func discoveryMessage(_ state: ProviderDiscoveryState?) -> String? {
        switch state {
        case .actionRequired(let message), .unavailable(let message): message
        case .inactive, .checking, .ready, .none: nil
        }
    }

    @ViewBuilder
    private func localAppControl(_ provider: GenerationProvider) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(provider.mcpCapability?.note ?? "")
                    .font(.system(size: AppTheme.FontSize.sm)).foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AppTheme.Spacing.lg)
            Toggle("", isOn: Binding(
                get: { connectionState(provider).localEnabled },
                set: { on in
                    ProviderMCP.setEndpoint(on ? provider.mcpCapability?.defaultURL.absoluteString : nil, for: provider)
                    refresh()
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.md)
        .frame(
            minHeight: AppTheme.ComponentSize.settingsProviderControlMinHeight,
            alignment: .topLeading
        )
    }

    private func keyField(_ provider: GenerationProvider) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                SecureField(placeholder(provider), text: draftBinding(provider))
                    .textFieldStyle(.plain)
                    .focused($focusedProvider, equals: provider.id)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
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
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.md)
        .frame(
            minHeight: AppTheme.ComponentSize.settingsProviderControlMinHeight,
            alignment: .topLeading
        )
    }

    @ViewBuilder
    private func trailingControl(_ provider: GenerationProvider) -> some View {
        let trimmed = (draft[provider.id] ?? "").trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save") { save(provider) }.buttonStyle(.capsule(.prominent, size: .regular)).controlSize(.large)
        } else if connectionState(provider).hasKey {
            Button("Remove", systemImage: "trash") { remove(provider) }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.large)
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
