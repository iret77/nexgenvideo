import AppKit
import NexGenEngine
import SwiftUI
import Testing
@testable import NexGenVideo

@Suite("Phase dock geometry", .serialized)
@MainActor
struct PhaseDockLayoutTests {
    private let phase = "production_design"
    private let widths: [CGFloat] = [320, 480, AppTheme.Window.projectMin.width - AppTheme.Layout.workflowSidebarDefault]
    private let scales = [AppTheme.Typography.standardScale, AppTheme.Typography.largeScale, AppTheme.Typography.largestScale]

    @Test func transientReadinessNeverChangesTheDockHeightOrMovesItsAction() throws {
        let checkingApproval = NativeGateApprovalReadiness.blocked("Checking approval readiness.")
        let ready = PhaseDockReadiness(phase: phase, mutation: .ready, approval: .ready)
        let blocked = PhaseDockReadiness(phase: phase, mutation: .ready, approval: longestBlockedApproval)
        let failed = PhaseDockReadiness(phase: phase, mutation: .failed("gates.yaml is unreadable."), approval: .ready)
        let transients: [(String, PhaseDockReadiness, Bool)] = [
            ("checking", .init(phase: phase, mutation: .checking, approval: checkingApproval), false),
            ("busy", .init(phase: phase, mutation: .busy("Approve \(phase)"), approval: checkingApproval), false),
            ("native edit", .init(phase: phase, mutation: .busy("Add reviewed source range"), approval: .ready), false),
        ]
        for scale in scales {
            for width in widths {
                for settled in [ready, blocked, failed] {
                    let stable = try measure(.resolve(phase: phase, current: settled, settled: settled, saving: false),
                                             current: settled, scale: scale, width: width)
                    var states = transients.map { name, current, saving in
                        (name, PhaseDockLayout.resolve(phase: phase, current: current, settled: settled, saving: saving), current)
                    }
                    states.append(("saving", PhaseDockLayout.resolve(phase: phase, current: settled, settled: settled, saving: true),
                                   settled))
                    for (name, layout, current) in states {
                        let transient = try measure(layout, current: current, scale: scale, width: width)
                        let context = "scale=\(scale), width=\(width), settled=\(settled.message), state=\(name)"
                        #expect(layout.settling, "\(context)")
                        #expect(abs(transient.height - stable.height) < 0.5, "\(context): \(transient) vs \(stable)")
                        #expect(abs(transient.actionY - stable.actionY) < 0.5, "\(context): \(transient) vs \(stable)")
                    }
                }
                let firstCheck = PhaseDockLayout.resolve(phase: phase,
                    current: .init(phase: phase, mutation: .checking, approval: checkingApproval), settled: nil, saving: false)
                let initial = try measure(firstCheck, current: .init(phase: phase, mutation: .checking, approval: checkingApproval),
                                          scale: scale, width: width)
                let settledReady = try measure(.resolve(phase: phase, current: ready, settled: ready, saving: false),
                                               current: ready, scale: scale, width: width)
                #expect(abs(initial.height - settledReady.height) < 0.5, "first check, scale=\(scale), width=\(width)")
            }
        }
    }

    @Test func approvedPhaseRevisionKeepsItsHeightWhileRecheckingAfterAnEdit() throws {
        for scale in scales {
            for width in widths {
                for settled in [PhaseControlReadiness.ready, .failed("gates.yaml is unreadable.")] {
                    let stable = try measureRevision(.resolve(mutation: settled, settled: settled), scale: scale, width: width)
                    for transient in [PhaseControlReadiness.checking, .busy("Add reviewed source range")] {
                        let layout = PhaseDockRevisionLayout.resolve(mutation: transient, settled: settled)
                        let rechecking = try measureRevision(layout, scale: scale, width: width)
                        let context = "scale=\(scale), width=\(width), settled=\(settled), transient=\(transient)"
                        #expect(layout.settling, "\(context)")
                        #expect(abs(rechecking.height - stable.height) < 0.5, "\(context)")
                        #expect(abs(rechecking.actionY - stable.actionY) < 0.5, "\(context)")
                    }
                }
            }
        }
    }

    @Test func theUnreservedTextsReproduceTheMeasuredWrap() {
        let width: CGFloat = 480
        let checking = textHeight(PhaseControlReadiness.checking.dockMessage ?? "", width: width)
        let readyText = textHeight(PhaseDockReadiness.readyMessage, width: width)
        #expect(readyText > checking + AppTheme.Spacing.sm, "ready=\(readyText), checking=\(checking)")
    }

    private var longestBlockedApproval: NativeGateApprovalReadiness {
        let requirements: [PhaseArtifactFailure.Requirement] = [.document, .entities, .priorArtifacts, .projectIdentity,
            .style, .lighting, .referenceImages, .imageProvenance, .identityVariants, .locations, .locationViews,
            .characterViews, .props]
        let message = requirements.map { PipelineReadinessPresentation.message(for: $0, phase: phase) }
            .max { $0.count < $1.count } ?? ""
        return .blocked("Artifact incomplete.", userMessage: message)
    }

    private struct Geometry: CustomStringConvertible {
        let height: CGFloat
        let actionY: CGFloat
        var description: String { "height=\(height), actionY=\(actionY)" }
    }

    private func measure(_ layout: PhaseDockLayout, current: PhaseDockReadiness, scale: Double,
                         width: CGFloat) throws -> Geometry {
        let project = try JSONDecoder().decode(ProjectPhase.self,
            from: Data(#"{"phase":"\#(phase)","approved":false,"state":"pending"}"#.utf8))
        let status = PipelinePhasePresentation.resolve(phase: project, isCurrent: true, isRunning: false,
            checking: layout.checking, ready: current.approval.isReady)
        let stable = PipelinePhasePresentation.resolve(phase: project, isCurrent: true, isRunning: false,
            ready: layout.stable.approves)
        return try host(PhaseDockFixture(phase: phase, layout: layout, status: status, stableStatus: stable),
                        scale: scale, width: width)
    }

    private func measureRevision(_ layout: PhaseDockRevisionLayout, scale: Double, width: CGFloat) throws -> Geometry {
        try host(RevisionDockFixture(phase: phase, layout: layout), scale: scale, width: width)
    }

    private func host(_ fixture: some View, scale: Double, width: CGFloat) throws -> Geometry {
        let host = NSHostingView(rootView: fixture
            .environment(\.interfaceScale, scale)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true))
        host.setFrameSize(.init(width: width, height: AppTheme.Window.projectMin.height))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        let action = try #require(find("dock-primary", in: host))
        return Geometry(height: size.height, actionY: action.convert(action.bounds, to: host).minY)
    }

    private func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: PhaseDockMessage(text: text)
            .environment(\.interfaceScale, AppTheme.Typography.largestScale)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true))
        host.setFrameSize(.init(width: width, height: AppTheme.Window.projectMin.height))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func find(_ name: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == name { return view }
        return view.subviews.lazy.compactMap { find(name, in: $0) }.first
    }
}

// Mirrors PipelinePanelView's current-phase dock with its real components.
private struct PhaseDockFixture: View {
    let phase: String
    let layout: PhaseDockLayout
    let status: PipelinePhasePresentation
    let stableStatus: PipelinePhasePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            PhaseDockStatusLabel(phase: phase, status: status, stable: stableStatus)
            PhaseDockMessage(text: layout.message, reserved: layout.reservedMessage)
            PhaseDockPrimaryAction(settling: layout.settling) {
                if layout.stable.approves {
                    Button {} label: {
                        Text("Approve")
                            .fixedSize(horizontal: false, vertical: true)
                            .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                            .frame(minHeight: AppTheme.IconSize.smMd)
                    }
                    .buttonStyle(.inlineAction(.approval))
                    .disabled(layout.settling)
                } else {
                    Button("Continue \(PhaseDisplay.label(phase))") {}
                        .buttonStyle(.inlineAction(.pack))
                        .disabled(layout.settling)
                }
            }
            .background(PhaseDockGeometryProbe(name: "dock-primary"))
            if layout.stable.offersRetry {
                Button("Retry phase controls") {}.buttonStyle(.inlineAction(.neutral)).disabled(layout.settling)
            }
            if layout.stable.diagnostic != nil {
                Button("Diagnostics") {}.buttonStyle(.inlineAction(.neutral)).disabled(layout.settling)
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Mirrors PipelinePanelView's approved-phase dock with its real components.
private struct RevisionDockFixture: View {
    let phase: String
    let layout: PhaseDockRevisionLayout

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            PhaseDockStatusLabel(phase: phase, status: .approved)
            Text("Revising this phase resets its approval and all following approvals.")
                .interfaceFont(size: AppTheme.Typography.metadata)
            if let reason = layout.reason {
                PhaseDockMessage(text: reason, reserved: layout.reserved)
                if layout.offersRetry {
                    Button("Retry phase controls") {}.buttonStyle(.inlineAction(.neutral)).disabled(layout.settling)
                }
            }
            PhaseDockPrimaryAction(settling: layout.settling) {
                Button("Revise \(PhaseDisplay.label(phase))…") {}.buttonStyle(.inlineAction(.neutral))
                    .disabled(layout.settling)
            }
            .background(PhaseDockGeometryProbe(name: "dock-primary"))
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PhaseDockGeometryProbe: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
