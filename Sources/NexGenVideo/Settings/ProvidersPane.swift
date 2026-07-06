import AppKit
import SwiftUI

struct ProvidersPane: View {
    @State private var hasKey: [String: Bool] = [:]
    @State private var maskedKey: [String: String] = [:]
    @State private var draft: [String: String] = [:]
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
            keyField(provider)
        }
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
