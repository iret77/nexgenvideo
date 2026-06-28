import AppKit
import SwiftUI

/// First-launch welcome shown over the Home screen
struct WelcomeOverlay: View {
    let onDismiss: () -> Void

    private static let hero: NSImage? = loadHero()

    var body: some View {
        ZStack {
            Color.black.opacity(AppTheme.Opacity.strong)
                .ignoresSafeArea()
            card
                .frame(width: 520)
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Welcome to NexGen Video")
                    .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("A video editor built for AI. Generate, and edit all in one place.")
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            heroImage
            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Skip") { onDismiss() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                signInButton
            }
            .padding(.top, AppTheme.Spacing.lg)
        }
        .padding(AppTheme.Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .shadow(AppTheme.Shadow.lg)
    }

    private var signInButton: some View {
        Button("Get started") { onDismiss() }
            .buttonStyle(.capsule(.prominent, size: .regular))
            .keyboardShortcut(.defaultAction)
    }


    @ViewBuilder
    private var heroImage: some View {
        Group {
            if let hero = Self.hero {
                Image(nsImage: hero).resizable().aspectRatio(contentMode: .fit)
            } else {
                AppTheme.aiGradient
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
    }

    private static func loadHero() -> NSImage? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let candidates = [
            root.appendingPathComponent("Images/welcome-splash.png"),
            root.appendingPathComponent("PalmierPro_PalmierPro.bundle/Images/welcome-splash.png"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}
