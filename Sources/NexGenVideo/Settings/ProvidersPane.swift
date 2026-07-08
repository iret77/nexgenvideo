import AppKit
import SwiftUI

struct ProvidersPane: View {
    @State private var hasKey: [String: Bool] = [:]
    @State private var maskedKey: [String: String] = [:]
    @State private var draft: [String: String] = [:]
    @State private var mcpDraft: [String: String] = [:]
    @State private var mcpTokenDraft: [String: String] = [:]
    @FocusState private var focusedProvider: String?

    @AppStorage(PromptCompiler.rawPromptsDefaultsKey) private var allowRawPrompts = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header
            ForEach(Array(GenerationProvider.allCases.enumerated()), id: \.element.id) { index, provider in
                if index > 0 {
                    Divider().overlay(AppTheme.Border.subtleColor)
                }
                providerSection(provider)
            }

            Divider().overlay(AppTheme.Border.subtleColor)

            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Raw prompts (pro)")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("Send prompts to generation models without NGV's prompt engine. For pros who know exactly what a model expects — the engine's translation, context, and consistency passes are skipped.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppTheme.Spacing.lg)
                Toggle("", isOn: $allowRawPrompts)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .onAppear(perform: refresh)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Providers")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Text("Bring your own API keys for generation models. Stored in your macOS Keychain.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func providerSection(_ provider: GenerationProvider) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            providerHeader(provider)
            // MCP-only providers (OpenArt, ACE) have no direct REST client, so no API-key field —
            // showing one would be a dead field. They activate through the MCP fields below.
            if provider.supportsDirectAPI {
                keyField(provider)
            }
            mcpField(provider)
        }
    }

    /// Optional MCP transport for the provider: NGV reaches it through the provider's own MCP
    /// server (subscription/OAuth) instead of the pay-per-call API. A provider may have both — NGV
    /// picks the cheaper per call. The agent never calls it raw; NGV drives it behind the gate.
    private func mcpField(_ provider: GenerationProvider) -> some View {
        let hasEndpoint = !(mcpDraft[provider.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                TextField("MCP server URL (optional — use the provider's subscription instead of the API)",
                          text: mcpBinding(provider))
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .onSubmit { saveMCP(provider) }
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(Color.black.opacity(AppTheme.Opacity.muted)))
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin))
                if hasEndpoint || !(mcpTokenDraft[provider.id] ?? "").isEmpty {
                    Button("Save") { saveMCP(provider) }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .controlSize(.large)
                }
            }
            // The subscription/OAuth bearer token NGV sends when driving this provider's MCP —
            // this is what makes MCP a real activated transport (not just an endpoint). Kept in the
            // Keychain; only shown once an endpoint is set.
            if hasEndpoint {
                SecureField(ProviderMCP.token(provider) != nil ? "Bearer token set — paste to replace" : "MCP bearer token / OAuth (optional)",
                            text: mcpTokenBinding(provider))
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .onSubmit { saveMCP(provider) }
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(Color.black.opacity(AppTheme.Opacity.muted)))
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin))
            }
        }
    }

    private func mcpBinding(_ provider: GenerationProvider) -> Binding<String> {
        Binding(get: { mcpDraft[provider.id] ?? "" }, set: { mcpDraft[provider.id] = $0 })
    }

    private func mcpTokenBinding(_ provider: GenerationProvider) -> Binding<String> {
        Binding(get: { mcpTokenDraft[provider.id] ?? "" }, set: { mcpTokenDraft[provider.id] = $0 })
    }

    private func saveMCP(_ provider: GenerationProvider) {
        ProviderMCP.setEndpoint(mcpDraft[provider.id], for: provider)
        // Only overwrite the stored token when the user typed a new one (endpoint-only saves keep it).
        let token = (mcpTokenDraft[provider.id] ?? "").trimmingCharacters(in: .whitespaces)
        if !token.isEmpty {
            ProviderMCP.setToken(token, for: provider)
            mcpTokenDraft[provider.id] = ""
        }
        refresh()
    }

    private func providerHeader(_ provider: GenerationProvider) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(provider.displayName)
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(provider.modalities)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: { NSWorkspace.shared.open(provider.keysURL, configuration: .init(), completionHandler: nil) }) {
                    HStack(spacing: 2) {
                        Text("Get key")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.primary)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
    }

    private func keyField(_ provider: GenerationProvider) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            fieldBox(provider)
            trailingControl(provider)
        }
    }

    private func fieldBox(_ provider: GenerationProvider) -> some View {
        SecureField(placeholder(provider), text: draftBinding(provider))
            .textFieldStyle(.plain)
            .focused($focusedProvider, equals: provider.id)
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .onSubmit { save(provider) }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.black.opacity(AppTheme.Opacity.muted))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        focusedProvider == provider.id ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.thin
                    )
            )
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: focusedProvider)
    }

    private func placeholder(_ provider: GenerationProvider) -> String {
        if hasKey[provider.id] == true {
            return maskedKey[provider.id] ?? ""
        }
        return "Paste API key…"
    }

    @ViewBuilder
    private func trailingControl(_ provider: GenerationProvider) -> some View {
        let trimmed = (draft[provider.id] ?? "").trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save") { save(provider) }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasKey[provider.id] == true {
            Button(action: { remove(provider) }) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help("Remove \(provider.displayName) API key")
        }
    }

    private func draftBinding(_ provider: GenerationProvider) -> Binding<String> {
        Binding(
            get: { draft[provider.id] ?? "" },
            set: { draft[provider.id] = $0 }
        )
    }

    private func refresh() {
        for provider in GenerationProvider.allCases {
            let key = ProviderKeychain.load(provider) ?? ""
            hasKey[provider.id] = !key.isEmpty
            maskedKey[provider.id] = mask(key)
            mcpDraft[provider.id] = ProviderMCP.endpoint(provider)?.absoluteString ?? ""
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
