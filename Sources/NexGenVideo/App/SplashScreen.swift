import AppKit
import SwiftUI

/// Launch splash: a borderless panel shown alone on every app start — artwork plus the version
/// in the corner. Fades out on its own; a click dismisses it early. Shown once per process, never
/// on window reopen. `onDismiss` fires exactly once when it starts fading — that's when the Home
/// window is revealed, so the splash dissolves TO reveal Home rather than floating over it.
@MainActor
final class SplashScreenController {
    static let shared = SplashScreenController()

    private var window: NSWindow?
    private var didShow = false
    private var onDismiss: (() -> Void)?
    private var didDismiss = false

    private init() {}

    func showAtLaunch(onDismiss: @escaping () -> Void) {
        guard !didShow else { return }
        didShow = true
        self.onDismiss = onDismiss

        let hosting = NSHostingController(rootView: SplashView())
        let window = SplashWindow(contentViewController: hosting)
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone, .transient]
        window.setContentSize(AppTheme.Window.splash)
        window.center()
        window.onClick = { [weak self] in self?.dismiss() }
        window.orderFrontRegardless()
        self.window = window

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppTheme.Anim.splashHold))
            self?.dismiss()
        }
    }

    private func dismiss() {
        guard !didDismiss else { return }
        didDismiss = true
        // Reveal Home as the splash begins to fade — no black gap between the two.
        onDismiss?()
        onDismiss = nil
        guard let window else { return }
        self.window = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AppTheme.Anim.splashFade
            window.animator().alphaValue = 0
        }
        Task {
            try? await Task.sleep(for: .seconds(AppTheme.Anim.splashFade))
            window.orderOut(nil)
        }
    }
}

/// Borderless, never key/main; any click anywhere on it dismisses the splash.
private final class SplashWindow: NSWindow {
    var onClick: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

private struct SplashView: View {
    private static let hero: NSImage? = loadHero()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            artwork
            if let version = AppVersion.marketing {
                Text("Version \(version)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.white.opacity(AppTheme.Opacity.prominent))
                    .shadow(AppTheme.Shadow.sm)
                    .padding(AppTheme.Spacing.md)
            }
        }
        .frame(width: AppTheme.Window.splash.width, height: AppTheme.Window.splash.height)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private var artwork: some View {
        Group {
            if let hero = Self.hero {
                Image(nsImage: hero).resizable().aspectRatio(contentMode: .fill)
            } else {
                AppTheme.aiGradient
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func loadHero() -> NSImage? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let candidates = [
            root.appendingPathComponent("Images/welcome-splash.png"),
            root.appendingPathComponent("NexGenVideo_NexGenVideo.bundle/Images/welcome-splash.png"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}
