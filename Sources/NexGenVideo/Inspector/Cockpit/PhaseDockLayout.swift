import SwiftUI

struct PhaseDockReadiness: Equatable {
    var phase: String?
    var mutation: PhaseControlReadiness
    var approval: NativeGateApprovalReadiness

    static let readyMessage = "Review this phase’s artifact, then approve it to continue."
    static let incompleteMessage = "This phase is incomplete. Continue the phase before approval."
    static let savingMessage = "Saving the phase decision…"

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
    let stable: PhaseDockReadiness?
    let checking: Bool
    let waiting: Bool
    let settling: Bool
    let placeholderMessages: [String]

    static func resolve(phase: String, current: PhaseDockReadiness, settled: PhaseDockReadiness?,
                        saving: Bool) -> Self {
        let stale = current.phase != phase
        let checking = stale || current.mutation == .checking
        let waiting = !stale && current.mutation.isBusy
        let settling = checking || waiting || saving
        let stable = settling ? settled.flatMap { $0.phase == phase ? $0 : nil } : current
        let shown = stale ? PhaseDockReadiness(phase: phase, mutation: .checking, approval: .ready) : current
        return Self(message: saving ? PhaseDockReadiness.savingMessage : shown.message, stable: stable,
                    checking: checking, waiting: waiting, settling: settling,
                    placeholderMessages: [PhaseDockReadiness.readyMessage,
                                          PipelineReadinessPresentation.message(for: .artifact, phase: phase)])
    }

    func reservedMessages(showing text: String) -> [String] {
        guard let stable else { return placeholderMessages }
        return text == stable.message ? [] : [stable.message]
    }

    func reservedStatuses(for status: PipelinePhasePresentation) -> [PipelinePhasePresentation] {
        guard status == .checking || status == .waiting else { return [] }
        guard let stable else { return [.incomplete] }
        return [stable.approves ? .ready : .incomplete]
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

struct PhaseDockCurrentPhaseView: View {
    let phase: String
    let status: PipelinePhasePresentation
    let layout: PhaseDockLayout
    var activity: String?
    var showsActions = true
    var approveEnabled = false
    var controlsReady = false
    var checkInFlight = false
    @Binding var showsDiagnostics: Bool
    var approve: () -> Void = {}
    var continuePhase: () -> Void = {}
    var retry: () -> Void = {}

    var body: some View {
        let text = activity ?? layout.message
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            PhaseDockStatusLabel(phase: phase, status: status, reserved: layout.reservedStatuses(for: status))
                .background { PipelineAcceptanceProbe(part: "dock.status", text: status.label) }
            PhaseDockMessage(text: text, reserved: showsActions ? layout.reservedMessages(showing: text) : [])
                .background { PipelineAcceptanceProbe(part: "dock.reason", text: text) }
            if showsActions {
                if let stable = layout.stable {
                    actions(stable)
                } else {
                    // No result yet: keep the incomplete layout's space without offering an action.
                    PhaseDockPrimaryAction(settling: true) { continueButton(enabled: false).hidden() }
                    Button("Diagnostics") {}.buttonStyle(.inlineAction(.neutral)).disabled(true).hidden()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actions(_ stable: PhaseDockReadiness) -> some View {
        PhaseDockPrimaryAction(settling: layout.settling) {
            if stable.approves {
                PhaseApproveButton(phase: phase, enabled: approveEnabled,
                                   unavailableHelp: layout.settling ? layout.message : nil, action: approve)
            } else {
                let enabled = !layout.settling && controlsReady
                continueButton(enabled: enabled)
                    .background { PipelineAcceptanceProbe(part: "dock.continue", enabled: enabled) }
            }
        }
        if stable.offersRetry {
            let enabled = !layout.settling && !checkInFlight
            Button("Retry phase controls", action: retry)
                .buttonStyle(.inlineAction(.neutral))
                .disabled(!enabled)
                .background { PipelineAcceptanceProbe(part: "dock.retry", enabled: enabled) }
        }
        if let diagnostic = stable.diagnostic {
            diagnosticsButton(diagnostic)
                .disabled(layout.settling)
                .background { PipelineAcceptanceProbe(part: "dock.diagnostics", enabled: !layout.settling) }
        }
    }

    private func continueButton(enabled: Bool) -> some View {
        Button("Continue \(PhaseDisplay.label(phase))", action: continuePhase)
            .buttonStyle(.inlineAction(.pack))
            .disabled(!enabled)
    }

    private func diagnosticsButton(_ diagnostic: String) -> some View {
        Button("Diagnostics") { showsDiagnostics = true }
            .buttonStyle(.inlineAction(.neutral))
            .popover(isPresented: $showsDiagnostics) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text("\(PhaseDisplay.label(phase)) diagnostics")
                        .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                    ScrollView {
                        Text(diagnostic)
                            .interfaceFont(size: AppTheme.Typography.metadata, design: .monospaced)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background { PipelineAcceptanceProbe(part: "dock.diagnostic-text", text: diagnostic) }
                    }
                    Button("Done") { showsDiagnostics = false }
                        .buttonStyle(.inlineAction(.neutral))
                        .background { PipelineAcceptanceProbe(part: "dock.diagnostics-done", enabled: true) }
                }
                .padding(AppTheme.Spacing.md)
                .frame(width: AppTheme.Layout.activityFlyoutWidth, height: AppTheme.Layout.activityFlyoutHeight)
            }
    }
}

struct PhaseDockRevisionView: View {
    let phase: String
    let status: PipelinePhasePresentation
    let layout: PhaseDockRevisionLayout
    var reviseEnabled = false
    var checkInFlight = false
    var revise: () -> Void = {}
    var retry: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            PhaseDockStatusLabel(phase: phase, status: status)
                .background { PipelineAcceptanceProbe(part: "dock.status", text: status.label) }
            Text("Revising this phase resets its approval and all following approvals.")
                .interfaceFont(size: AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if let reason = layout.reason {
                PhaseDockMessage(text: reason, reserved: layout.reserved.map { [$0] } ?? [])
                if layout.offersRetry {
                    Button("Retry phase controls", action: retry)
                        .buttonStyle(.inlineAction(.neutral))
                        .disabled(layout.settling || checkInFlight)
                }
            }
            PhaseDockPrimaryAction(settling: layout.settling) {
                Button("Revise \(PhaseDisplay.label(phase))…", action: revise)
                    .buttonStyle(.inlineAction(.neutral))
                    .disabled(!reviseEnabled)
                    .background { PipelineAcceptanceProbe(part: "dock.revise", enabled: reviseEnabled) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Approving is the one action the pipeline cannot advance without, so it stays a labeled button.
struct PhaseApproveButton: View {
    let phase: String
    let enabled: Bool
    var unavailableHelp: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Approve")
                .fixedSize(horizontal: false, vertical: true)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .frame(minHeight: AppTheme.IconSize.smMd)
        }
        .buttonStyle(.inlineAction(.approval))
        .disabled(!enabled)
        .background { PipelineAcceptanceProbe(part: "approve.\(phase)", enabled: enabled) }
        .help(enabled
              ? "Approve \(PhaseDisplay.label(phase)) and move to the next phase"
              : unavailableHelp ?? "Complete \(PhaseDisplay.label(phase)) before approving")
    }
}

private struct PipelineAcceptanceProbesKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var pipelineAcceptanceProbes: Bool? {
        get { self[PipelineAcceptanceProbesKey.self] }
        set { self[PipelineAcceptanceProbesKey.self] = newValue }
    }
}

struct PipelineAcceptanceProbe: View {
    let id: String
    var enabled: Bool?
    var text: String?
    @Environment(\.pipelineAcceptanceProbes) private var forced

    init(id: String, enabled: Bool? = nil, text: String? = nil) {
        self.id = id
        self.enabled = enabled
        self.text = text
    }

    init(part: String, enabled: Bool? = nil, text: String? = nil) {
        self.init(id: "pipeline.overview.\(part)", enabled: enabled, text: text)
    }

    var body: some View {
        if forced ?? (WorkspaceUIAcceptance.isRequested || MusicvideoHostFlowAcceptance.isRequested
            || ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false) {
            AppRelaunchClickProbe(identifier: id, acceptanceState: enabled, acceptanceText: text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }
}

// A transient text replaces the settled one inside the reserved height instead of reflowing the dock.
struct PhaseDockMessage: View {
    let text: String
    var reserved: [String] = []

    var body: some View {
        if reserved.isEmpty {
            line(text, fitsHeight: false)
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(Array(reserved.enumerated()), id: \.offset) { line($0.element, fitsHeight: false) }
            }
            .hidden()
            .overlay(alignment: .topLeading) { line(text, fitsHeight: true) }
            .help(text)
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
    var reserved: [PipelinePhasePresentation] = []

    var body: some View {
        if reserved.isEmpty {
            label(status)
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(reserved, id: \.self) { label($0) }
            }
            .hidden()
            .overlay(alignment: .topLeading) {
                label(status).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
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
