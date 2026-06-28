import AppKit
import SwiftUI

/// First-launch welcome shown over the Home screen — the splash art fills the card.
struct WelcomeOverlay: View {
    let onDismiss: () -> Void

    private static let hero: NSImage? = loadHero()

    var body: some View {
        ZStack {
            Color.black.opacity(AppTheme.Opacity.strong)
                .ignoresSafeArea()
            card
                .frame(width: 560, height: 373)
        }
        .transition(.opacity)
    }

    private var card: some View {
        ZStack(alignment: .bottom) {
            splash
            buttonsBar
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
        .shadow(AppTheme.Shadow.lg)
    }

    private var splash: some View {
        Group {
            if let hero = Self.hero {
                Image(nsImage: hero).resizable().aspectRatio(contentMode: .fill)
            } else {
                AppTheme.aiGradient
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var buttonsBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("Skip") { onDismiss() }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Get started") { onDismiss() }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .keyboardShortcut(.defaultAction)
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [.clear, Color.black.opacity(AppTheme.Opacity.strong)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
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
