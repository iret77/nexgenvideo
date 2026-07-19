import AppKit

/// A spinner for the pack install. The install is two network round-trips that happen after the gate
/// alert has closed and before any window exists, so without this the user stares at nothing.
///
/// AppKit metrics are literals here: AppTheme is the SwiftUI design system and doesn't reach this far.
@MainActor
final class PackInstallProgress {
    private let panel: NSPanel
    private var closed = false

    init(packID: String) {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.sizeToFit()
        spinner.translatesAutoresizingMaskIntoConstraints = false

        // Same label treatment as the alerts: no hyphenation, so a pack name never breaks mid-word.
        let label = AppState.bodyText("Installing the “\(packID)” format pack…")
        let labelWidth = label.frame.width
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.contentView = content

        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: labelWidth),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        spinner.startAnimation(nil)
    }

    func show() {
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        panel.center()
        panel.orderFrontRegardless()
    }

    /// Idempotent — the caller closes it before each alert, and again via `defer`.
    func close() {
        guard !closed else { return }
        closed = true
        panel.orderOut(nil)
    }
}
