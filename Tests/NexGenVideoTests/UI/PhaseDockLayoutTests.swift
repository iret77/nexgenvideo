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
    private let checkingApproval = NativeGateApprovalReadiness.blocked("Checking approval readiness.")

    @Test func transientStatesNeverChangeTheDockHeightOrMoveItsAction() throws {
        let ready = PhaseDockReadiness(phase: phase, mutation: .ready, approval: .ready)
        let failed = PhaseDockReadiness(phase: phase, mutation: .failed("gates.yaml is unreadable."), approval: .ready)
        let transients: [(String, PhaseDockReadiness, Bool)] = [
            ("checking", .init(phase: phase, mutation: .checking, approval: checkingApproval), false),
            ("busy", .init(phase: phase, mutation: .busy("Approve \(phase)"), approval: checkingApproval), false),
            ("native edit", .init(phase: phase, mutation: .busy("Add reviewed source range"), approval: .ready), false),
        ]
        for scale in scales {
            for width in widths {
                for settled in [ready, blocked(longestIncompleteMessage), blocked(artifactMessage), failed] {
                    let layout = PhaseDockLayout.resolve(phase: phase, current: settled, settled: settled, saving: false)
                    let stable = try measure(layout, current: settled, scale: scale, width: width)
                    var states = transients.map { name, current, saving in
                        (name, PhaseDockLayout.resolve(phase: phase, current: current, settled: settled, saving: saving),
                         current, String?.none)
                    }
                    states.append(("saving", PhaseDockLayout.resolve(phase: phase, current: settled, settled: settled,
                                                                     saving: true), settled, nil))
                    states.append(("host decision text", layout, settled, "Review the phase decision below."))
                    for (name, transientLayout, current, activity) in states {
                        let transient = try measure(transientLayout, current: current, activity: activity,
                                                    scale: scale, width: width)
                        let context = "scale=\(scale), width=\(width), settled=\(settled.message), state=\(name)"
                        #expect(abs(transient.height - stable.height) < 0.5, "\(context): \(transient) vs \(stable)")
                        #expect(abs((transient.actionY ?? -1) - (stable.actionY ?? 1)) < 0.5,
                                "\(context): \(transient) vs \(stable)")
                    }
                }
            }
        }
    }

    @Test func theFirstCheckClaimsNoActionAndKeepsTheIncompleteHeight() throws {
        let placeholderReadiness = PhaseDockReadiness(phase: phase, mutation: .checking, approval: checkingApproval)
        let placeholder = PhaseDockLayout.resolve(phase: phase, current: placeholderReadiness, settled: nil, saving: false)
        let incomplete = blocked(artifactMessage)
        let ready = PhaseDockReadiness(phase: phase, mutation: .ready, approval: .ready)
        for scale in scales {
            for width in widths {
                let context = "scale=\(scale), width=\(width)"
                let first = try measure(placeholder, current: placeholderReadiness, scale: scale, width: width)
                #expect(first.actionY == nil && !first.offersAction, "\(context)")
                let continueResult = try measure(.resolve(phase: phase, current: incomplete, settled: incomplete, saving: false),
                                                 current: incomplete, scale: scale, width: width)
                #expect(abs(first.height - continueResult.height) < 0.5, "\(context): \(first) vs \(continueResult)")
                let readyResult = try measure(.resolve(phase: phase, current: ready, settled: ready, saving: false),
                                              current: ready, scale: scale, width: width)
                #expect(readyResult.height <= first.height + 0.5, "\(context): \(first) vs \(readyResult)")
            }
        }
    }

    @Test func approvedPhaseRevisionKeepsItsHeightWhileRecheckingAfterAnEdit() {
        for scale in scales {
            for width in widths {
                for settled in [PhaseControlReadiness.ready, .failed("gates.yaml is unreadable.")] {
                    let stable = measureRevision(.resolve(mutation: settled, settled: settled), scale: scale, width: width)
                    for transient in [PhaseControlReadiness.checking, .busy("Edit location")] {
                        let rechecking = measureRevision(.resolve(mutation: transient, settled: settled),
                                                             scale: scale, width: width)
                        let context = "scale=\(scale), width=\(width), settled=\(settled), transient=\(transient)"
                        #expect(abs(rechecking.height - stable.height) < 0.5, "\(context)")
                        #expect(abs((rechecking.actionY ?? -1) - (stable.actionY ?? 1)) < 0.5, "\(context)")
                    }
                }
            }
        }
    }

    @Test func theUnreservedTextsReproduceTheMeasuredWrap() throws {
        let scale = AppTheme.Typography.largestScale
        let range = AppTheme.Layout.previewMinWidth...(AppTheme.Window.projectMin.width - AppTheme.Layout.workflowSidebarMin)
        let wrapping = stride(from: range.upperBound, through: range.lowerBound, by: -AppTheme.Spacing.xs).first { width in
            let textWidth = width - 2 * AppTheme.Spacing.md
            let checking = textHeight(PhaseControlReadiness.checking.dockMessage ?? "", width: textWidth, scale: scale)
            return textHeight(PhaseDockReadiness.readyMessage, width: textWidth, scale: scale) > checking + AppTheme.Spacing.sm
        }
        let width = try #require(wrapping, "The ready text never wraps taller than the checking text within \(range)")
        let ready = PhaseDockReadiness(phase: phase, mutation: .ready, approval: .ready)
        let checking = PhaseDockReadiness(phase: phase, mutation: .checking, approval: checkingApproval)
        let stable = try measure(.resolve(phase: phase, current: ready, settled: ready, saving: false),
                                 current: ready, scale: scale, width: width)
        let transient = try measure(.resolve(phase: phase, current: checking, settled: ready, saving: false),
                                    current: checking, scale: scale, width: width)
        #expect(abs(transient.height - stable.height) < 0.5, "width=\(width): \(transient) vs \(stable)")
        #expect(abs((transient.actionY ?? -1) - (stable.actionY ?? 1)) < 0.5, "width=\(width): \(transient) vs \(stable)")
    }

    private var artifactMessage: String { PipelineReadinessPresentation.message(for: .artifact, phase: phase) }

    private var longestIncompleteMessage: String {
        let requirements: [PhaseArtifactFailure.Requirement] = [.document, .entities, .priorArtifacts, .projectIdentity,
            .style, .lighting, .referenceImages, .imageProvenance, .identityVariants, .locations, .locationViews,
            .characterViews, .props]
        return requirements.map { PipelineReadinessPresentation.message(for: $0, phase: phase) }
            .max { $0.count < $1.count } ?? ""
    }

    private func blocked(_ message: String) -> PhaseDockReadiness {
        PhaseDockReadiness(phase: phase, mutation: .ready, approval: .blocked("Artifact incomplete.", userMessage: message))
    }

    private struct Geometry: CustomStringConvertible {
        let height: CGFloat
        let actionY: CGFloat?
        let offersAction: Bool
        var description: String { "height=\(height), actionY=\(String(describing: actionY))" }
    }

    private func measure(_ layout: PhaseDockLayout, current: PhaseDockReadiness, activity: String? = nil,
                         scale: Double, width: CGFloat) throws -> Geometry {
        let project = try JSONDecoder().decode(ProjectPhase.self,
            from: Data(#"{"phase":"\#(phase)","approved":false,"state":"pending"}"#.utf8))
        let status = PipelinePhasePresentation.resolve(phase: project, isCurrent: true, isRunning: false,
            checking: layout.checking, waiting: layout.waiting, ready: current.approval.isReady)
        let view = PhaseDockCurrentPhaseView(phase: phase, status: status, layout: layout, activity: activity,
            approveEnabled: !layout.settling && current.approval.isReady, controlsReady: current.mutation.isReady,
            showsDiagnostics: .constant(false))
        return host(view, actions: ["pipeline.overview.approve.\(phase)", "pipeline.overview.dock.continue"],
                    scale: scale, width: width)
    }

    private func measureRevision(_ layout: PhaseDockRevisionLayout, scale: Double, width: CGFloat) -> Geometry {
        host(PhaseDockRevisionView(phase: phase, status: .approved, layout: layout, reviseEnabled: !layout.settling),
             actions: ["pipeline.overview.dock.revise"], scale: scale, width: width)
    }

    private func host(_ dock: some View, actions: [String], scale: Double, width: CGFloat) -> Geometry {
        let host = NSHostingView(rootView: dock
            .padding(AppTheme.Spacing.md)
            .environment(\.interfaceScale, scale)
            .environment(\.pipelineAcceptanceProbes, true)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true))
        host.setFrameSize(.init(width: width, height: AppTheme.Window.projectMin.height))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        let action = actions.lazy.compactMap { find($0, in: host) }.first
        return Geometry(height: size.height, actionY: action.map { $0.convert($0.bounds, to: host).minY },
                        offersAction: action != nil)
    }

    private func textHeight(_ text: String, width: CGFloat, scale: Double) -> CGFloat {
        let host = NSHostingView(rootView: PhaseDockMessage(text: text)
            .environment(\.interfaceScale, scale)
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
