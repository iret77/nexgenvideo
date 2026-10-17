import NexGenEngine

enum PipelineReadinessPresentation {
    static func message(for requirement: PhaseArtifactFailure.Requirement, phase: String) -> String {
        let name = PhaseDisplay.label(phase)
        let missing: String = switch requirement {
        case .document: "a valid document with reference images for every subject"
        case .entities: "at least one character, group, or location"
        case .priorArtifacts: "the approved Brief, Production Design, and Storyboard"
        case .projectIdentity: "a document belonging to this project"
        case .style: "the approved Production Design style"
        case .lighting: "the approved lighting reference"
        case .referenceImages: "reference images that are available in this project"
        case .imageProvenance: "verified generation records or confirmed identities for its images"
        case .identityVariants: "valid links between identity variants and their references"
        case .locations: "all locations used in the Storyboard"
        case .locationViews: "the location views required by the Storyboard"
        case .characterViews: "the character views required by the Storyboard"
        case .props: "reference images for the props required by the Storyboard"
        }
        return "\(name) is incomplete: it needs \(missing)."
    }

    static func message(for stage: NativeGateApprovalStage, phase: String) -> String {
        let name = PhaseDisplay.label(phase)
        return switch stage {
        case .phaseAccess: "\(name) needs its required input before approval."
        case .priorApprovals: "\(name) needs the preceding phases to be approved."
        case .artifact: "\(name)’s artifact is missing, incomplete, or no longer matches the approved work."
        case .productionStyle: "Production Design needs a complete style record."
        case .treatment: "Treatment needs current story relationships."
        case .storyboard: "Storyboard needs current story relationships."
        case .frames: "Frames needs review against the approved production style."
        case .render: "Render needs approved takes for the current shots."
        case .executionPlan: "Shot List needs a matching execution plan."
        }
    }
}

enum PipelinePhasePresentation: Equatable {
    case running, approved, outdated, needsRevision, ready, incomplete, upcoming

    static func resolve(phase: ProjectPhase, isCurrent: Bool, isRunning: Bool, ready: Bool) -> Self {
        if isRunning { return .running }
        if phase.approvalCurrent { return .approved }
        if phase.approved { return .outdated }
        if phase.state == "needs_revision" { return .needsRevision }
        if isCurrent { return ready ? .ready : .incomplete }
        return .upcoming
    }

    var label: String {
        switch self {
        case .running: "In progress"
        case .approved: "Approved"
        case .outdated: "Approval outdated"
        case .needsRevision: "Needs revision"
        case .ready: "Ready for review"
        case .incomplete: "Incomplete"
        case .upcoming: "Upcoming"
        }
    }

    var symbol: String {
        switch self {
        case .running: "circle.dotted.circle"
        case .approved: "checkmark.circle.fill"
        case .outdated, .needsRevision: "exclamationmark.triangle.fill"
        case .ready: "checkmark.circle"
        case .incomplete: "circle.lefthalf.filled"
        case .upcoming: "circle"
        }
    }
}
