import SwiftUI

struct PhaseDockReadiness: Equatable {
    var phase: String?
    var mutation: PhaseControlReadiness
    var approval: NativeGateApprovalReadiness

    static let readyMessage = "Review this phase’s artifact, then approve it to continue."
    static let incompleteMessage = "This phase is incomplete. Continue the phase before approval."
    static let savingMessage = "Saving the phase decision…"

    static func assumedReady(_ phase: String) -> Self {
        Self(phase: phase, mutation: .ready, approval: .ready)
    }

    var message: String {
        if let message = mutation.dockMessage { return message }
        if approval.isReady { return Self.readyMessage }
        return approval.userMessage ?? Self.incompleteMessage
    }

    var approves: Bool { approval.isReady }
    var offersRetry: Bool { mutation.failure != nil }
    var diagnostic: String? { mutation.failure ?? (mutation.isReady ? approval.blocker : nil) }
}

// While readiness is unknown the dock keeps the last settled result's controls and text height.
struct PhaseDockLayout: Equatable {
    let message: String
    let stable: PhaseDockReadiness
    let checking: Bool
    let settling: Bool

    var reservedMessage: String? { settling ? stable.message : nil }

    static func resolve(phase: String, current: PhaseDockReadiness, settled: PhaseDockReadiness?,
                        saving: Bool) -> Self {
        let checking = current.phase != phase || current.mutation.isTransient
        let settling = checking || saving
        let stable = !settling ? current : settled.flatMap { $0.phase == phase ? $0 : nil } ?? .assumedReady(phase)
        let shown = current.phase == phase ? current : PhaseDockReadiness(phase: phase, mutation: .checking, approval: .ready)
        let message = saving ? PhaseDockReadiness.savingMessage : shown.message
        return Self(message: message, stable: stable, checking: checking, settling: settling)
    }
}

struct PhaseDockRevisionLayout: Equatable {
    let reason: String?
    var reserved: String?
    var settling = false
    var offersRetry = false

    static func resolve(mutation: PhaseControlReadiness, settled: PhaseControlReadiness?) -> Self {
        guard mutation.isTransient else {
            return Self(reason: mutation.revisionMessage, offersRetry: mutation.failure != nil)
        }
        let stable = settled ?? .ready
        let reserved = stable.revisionMessage
        return Self(reason: reserved == nil ? nil : mutation.revisionMessage, reserved: reserved, settling: true,
                    offersRetry: stable.failure != nil)
    }
}

// A transient text replaces the settled one inside the settled text's height instead of reflowing the dock.
struct PhaseDockMessage: View {
    let text: String
    var reserved: String?

    var body: some View {
        if let reserved {
            line(reserved, fitsHeight: false)
                .hidden()
                .overlay(alignment: .topLeading) { line(text, fitsHeight: true) }
                .help(text)
        } else {
            line(text, fitsHeight: false)
        }
    }

    @ViewBuilder
    private func line(_ value: String, fitsHeight: Bool) -> some View {
        let label = Text(value)
            .interfaceFont(size: AppTheme.Typography.ui)
            .foregroundStyle(AppTheme.Text.secondaryColor)
        if fitsHeight {
            label.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            label.fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PhaseDockStatusLabel: View {
    let phase: String
    let status: PipelinePhasePresentation
    var stable: PipelinePhasePresentation?

    var body: some View {
        if let stable, stable != status {
            label(stable)
                .hidden()
                .overlay(alignment: .topLeading) {
                    label(status).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
        } else {
            label(status)
        }
    }

    private func label(_ presentation: PipelinePhasePresentation) -> some View {
        Label("\(PhaseDisplay.label(phase)) · \(presentation.label)", systemImage: presentation.symbol)
            .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// The progress indicator always occupies its slot so starting or finishing a check never resizes the row.
struct PhaseDockPrimaryAction<Content: View>: View {
    let settling: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            content()
            ProgressView()
                .controlSize(.small)
                .opacity(settling ? AppTheme.Opacity.opaque : AppTheme.Opacity.transparent)
                .accessibilityLabel("Updating phase controls")
                .accessibilityHidden(!settling)
        }
    }
}
