import AppKit
import SwiftUI

/// Providers setup — one honest control per provider, matching how the service actually authenticates
/// (researched, not guessed): a masked API-key field, a one-click OAuth sign-in, or a local-app switch.
/// No MCP URLs to type (they're known and pre-filled), no field a service can't use. A status pill
/// tells a creative at a glance whether a provider is ready.
struct ProvidersPane: View {
    @State private var hasKey: [String: Bool] = [:]
    @State private var maskedKey: [String: String] = [:]
    @State private var draft: [String: String] = [:]
    @State private var oauthConnected: [String: Bool] = [:]
    @State private var localEnabled: [String: Bool] = [:]
    @State private var signingIn: String?
    @State private var errorText: [String: String] = [:]
    @State private var oauth = ProviderOAuth()
    @FocusState private var focusedProvider: String?

    @AppStorage(PromptCompiler.rawPromptsDefaultsKey) private var allowRawPrompts = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header
            ForEach(Array(GenerationProvider.allCases.enumerated()), id: \.element.id) { index, provider in
                if index > 0 { Divider().overlay(AppTheme.Border.subtleColor) }
                providerSection(provider)
            }
            Divider().overlay(AppTheme.Border.subtleColor)
            rawPromptsRow
        }
        .onAppear(perform: refresh)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Providers")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text("Connect the AI services you use. NGV stores keys in your macOS Keychain and picks the right one for each model.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Per-provider section

    @ViewBuilder
    private func providerSection(_ provider: GenerationProvider) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            providerHeader(provider)
            switch primaryStyle(provider) {
            case .oauth: oauthControl(provider)
            case .localApp: localAppControl(provider)
            case .apiKey: keyField(provider)
            }
            if let err = errorText[provider.id] {
                Text(err)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
    }

    /// The one control style a provider leads with: OAuth sign-in, a local-app switch, or an API key.
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
        case .oauth: return oauthConnected[p.id] == true || hasKey[p.id] == true
        case .localApp: return localEnabled[p.id] == true
        case .apiKey: return hasKey[p.id] == true
        }
    }

    private func providerHeader(_ provider: GenerationProvider) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(provider.displayName)
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                    Text(provider.modalities)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if primaryStyle(provider) != .localApp {
                        linkButton(provider)
                    }
                }
            }
            Spacer(minLength: AppTheme.Spacing.md)
            statusPill(provider)
        }
    }

    private func linkButton(_ provider: GenerationProvider) -> some View {
        Button(action: { NSWorkspace.shared.open(provider.keysURL) }) {
            HStack(spacing: 2) {
                Text(primaryStyle(provider) == .oauth ? "Website" : "Get key")
                Image(systemName: "arrow.up.right").font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
            }
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Accent.primary)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func statusPill(_ provider: GenerationProvider) -> some View {
        let ready = isReady(provider)
        return Text(ready ? "Active" : "Not set up")
            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
            .foregroundStyle(ready ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(
                Capsule().fill((ready ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor).opacity(AppTheme.Opacity.faint))
            )
    }

    // MARK: - OAuth control (Higgsfield, OpenArt)

    @ViewBuilder
    private func oauthControl(_ provider: GenerationProvider) -> some View {
        let connected = oauthConnected[provider.id] == true
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if let note = provider.mcpCapability?.note {
                Text(note).font(.system(size: AppTheme.FontSize.sm)).foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                if connected {
                    Label("Signed in", systemImage: "checkmark.seal.fill")
                        .font(.system(size: AppTheme.FontSize.sm)).foregroundStyle(AppTheme.Accent.primary)
                    Button("Sign out") { ProviderOAuthStore.disconnect(provider); refresh() }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                } else if signingIn == provider.id {
                    ProgressView().controlSize(.small)
                    Text("Opening \(provider.displayName)…").font(.system(size: AppTheme.FontSize.sm)).foregroundStyle(AppTheme.Text.tertiaryColor)
                } else {
                    Button("Sign in with \(provider.displayName)") { signIn(provider) }
                        .buttonStyle(.capsule(.prominent, size: .regular))
                }
            }
        }
    }

    // MARK: - Local-app control (ACE Studio)

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
                get: { localEnabled[provider.id] == true },
                set: { on in
                    ProviderMCP.setEndpoint(on ? provider.mcpCapability?.defaultURL.absoluteString : nil, for: provider)
                    refresh()
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    // MARK: - API-key field

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
                    .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(Color.black.opacity(AppTheme.Opacity.muted)))
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(
                        focusedProvider == provider.id ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.thin))
                trailingControl(provider)
            }
        }
    }

    @ViewBuilder
    private func trailingControl(_ provider: GenerationProvider) -> some View {
        let trimmed = (draft[provider.id] ?? "").trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save") { save(provider) }.buttonStyle(.capsule(.prominent, size: .regular)).controlSize(.large)
        } else if hasKey[provider.id] == true {
            Button(action: { remove(provider) }) {
                Image(systemName: "trash").font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular)).controlSize(.large)
            .help("Remove \(provider.displayName) API key")
        }
    }

    private var rawPromptsRow: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Raw prompts (pro)").font(.system(size: AppTheme.FontSize.md)).foregroundStyle(AppTheme.Text.primaryColor)
                Text("Send prompts to generation models without NGV's prompt engine. For pros who know exactly what a model expects — the engine's translation, context, and consistency passes are skipped.")
                    .font(.system(size: AppTheme.FontSize.sm)).foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AppTheme.Spacing.lg)
            Toggle("", isOn: $allowRawPrompts).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    // MARK: - Actions

    private func signIn(_ provider: GenerationProvider) {
        signingIn = provider.id
        errorText[provider.id] = nil
        Task {
            do { try await oauth.signIn(provider) }
            catch { errorText[provider.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            signingIn = nil
            refresh()
        }
    }

    private func placeholder(_ provider: GenerationProvider) -> String {
        hasKey[provider.id] == true ? (maskedKey[provider.id] ?? "") : "Paste API key…"
    }

    private func draftBinding(_ provider: GenerationProvider) -> Binding<String> {
        Binding(get: { draft[provider.id] ?? "" }, set: { draft[provider.id] = $0 })
    }

    private func refresh() {
        for provider in GenerationProvider.allCases {
            let key = ProviderKeychain.load(provider) ?? ""
            hasKey[provider.id] = !key.isEmpty
            maskedKey[provider.id] = mask(key)
            oauthConnected[provider.id] = ProviderOAuthStore.isConnected(provider)
            localEnabled[provider.id] = ProviderMCP.configuredEndpoint(provider) != nil
        }
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
}
