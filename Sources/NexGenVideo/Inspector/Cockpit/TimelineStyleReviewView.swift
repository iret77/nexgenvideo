import SwiftUI

struct TimelineStyleReviewView: View {
    private enum ReviewChoice: String, CaseIterable {
        case pass
        case fail
        case acceptedDeviation = "accepted_deviation"
        case notApplicable = "not_applicable"
        case notObserved = "not_observed"

        var label: String {
            switch self {
            case .pass: "Meets criterion"
            case .fail: "Does not meet criterion"
            case .acceptedDeviation: "Accept observed deviation"
            case .notApplicable: "Not applicable"
            case .notObserved: "Not observed"
            }
        }

        var result: TimelineStyleFinding.Result {
            switch self {
            case .pass: .pass
            case .fail, .acceptedDeviation: .fail
            case .notApplicable: .notApplicable
            case .notObserved: .notObserved
            }
        }

        var acceptsDeviation: Bool { self == .acceptedDeviation }
    }

    @Environment(EditorViewModel.self) private var editor
    @State private var snapshot: TimelineStyleReview.Snapshot?
    @State private var choices: [String: ReviewChoice] = [:]
    @State private var observations: [String: String] = [:]
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Timeline style review").fontWeight(AppTheme.FontWeight.semibold)
            Text("Review the actual cut in the Timeline player. Image, motion, editing and sound criteria remain unreviewed until you record an observation or explicitly accept a deviation.")
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Button("Review current timeline") {
                busy = true
                Task {
                    let home = editor.workingRoot
                    let timeline = editor.timeline
                    do {
                        let value = try await TimelineStyleReview.capture(timeline: timeline, resolver: editor.mediaResolver.snapshot())
                        guard home == editor.workingRoot, timeline == editor.timeline else {
                            busy = false; message = "The project or cut changed. Start the review again."; return
                        }
                        snapshot = value
                        choices = Dictionary(uniqueKeysWithValues:
                            (value?.style.criteria ?? []).compactMap { criterion in
                                guard value?.targetsByCriterion[criterion.auditKey]?.isEmpty
                                    == true else { return nil }
                                return (criterion.auditKey, ReviewChoice.notObserved)
                            }
                        )
                        observations = [:]
                        message = value == nil ? "Choose and approve Production Design before starting a style review." : nil
                    } catch { if home == editor.workingRoot { message = error.localizedDescription } }
                    busy = false
                }
            }
            .buttonStyle(InlineActionButtonStyle(variant: .approval))
            .disabled(busy)
            if let snapshot, snapshot.home == editor.workingRoot {
                ForEach(snapshot.style.criteria, id: \.auditKey) { criterion in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(criterion.expected).fontWeight(AppTheme.FontWeight.semibold)
                        Text("Evidence: \(criterion.scope.rawValue) · \(criterion.evidenceKind.rawValue)")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Picker("Finding", selection: Binding<String>(
                            get: { choices[criterion.auditKey]?.rawValue ?? "unreviewed" },
                            set: { choices[criterion.auditKey] = ReviewChoice(rawValue: $0) }
                        )) {
                            Text("Not reviewed").tag("unreviewed")
                            ForEach(ReviewChoice.allCases, id: \.rawValue) { choice in
                                Text(choice.label).tag(choice.rawValue)
                            }
                        }
                        .disabled(snapshot.targetsByCriterion[criterion.auditKey]?.isEmpty == true)
                        TextField("Observation and time range, or reason for accepting the deviation", text: Binding(
                            get: { observations[criterion.auditKey] ?? "" }, set: { observations[criterion.auditKey] = $0 }))
                    }
                }
                Button("Record this timeline review") {
                    let findings = snapshot.style.criteria.compactMap { criterion -> TimelineStyleFinding? in
                        guard let choice = choices[criterion.auditKey] else { return nil }
                        return TimelineStyleReview.makeFinding(
                            criterion: criterion,
                            result: choice.result,
                            acceptedDeviation: choice.acceptsDeviation,
                            observation: observations[criterion.auditKey] ?? "",
                            snapshot: snapshot
                        )
                    }
                    busy = true
                    Task {
                        do {
                            try await TimelineStyleReview.save(snapshot: snapshot, findings: findings, editor: editor)
                            let unresolved = findings.contains {
                                $0.result == .notObserved
                                    || ($0.result == .fail && !$0.acceptedDeviation)
                            }
                            message = unresolved
                                ? "Review recorded. Export remains blocked until every unobserved or failed criterion is resolved."
                                : "Review recorded for this exact cut. Any change to the cut, source media or style requires another review."
                            self.snapshot = nil
                        } catch { if snapshot.home == editor.workingRoot { message = error.localizedDescription } }
                        busy = false
                    }
                }
                .buttonStyle(InlineActionButtonStyle(variant: .approval))
                .disabled(busy || snapshot.style.criteria.contains {
                    choices[$0.auditKey] == nil || (observations[$0.auditKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
            }
            if let message { Text(message).foregroundStyle(AppTheme.Text.secondaryColor) }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .onChange(of: editor.workingRoot) { _, _ in snapshot = nil; choices = [:]; observations = [:]; message = nil }
    }
}
