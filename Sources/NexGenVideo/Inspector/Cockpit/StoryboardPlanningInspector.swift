import NexGenEngine
import SwiftUI

struct StoryboardPlanningSelection: Equatable {
    let home: URL
    let fingerprint: String
    let shot: StoryboardTimingV1.PlannedShot
    let number: Int
    let steps: [StoryboardV2.StoryStep]
    let timebase: RationalTimebaseV1
    var sketchProblems: [String: String] = [:]
}

struct StoryboardPlanningInspector: View {
    let selection: StoryboardPlanningSelection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text("Shot \(selection.number)").interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                ForEach(selection.steps, id: \.id) { step in Text(step.action).textSelection(.enabled) }
                field("Starts at", seconds(selection.shot.startTicks))
                field("Duration", seconds(selection.shot.durationTicks))
                field("Framing", selection.shot.framing.scale)
                field("Camera view", selection.shot.framing.cameraView)
                field("Composition", selection.shot.framing.composition)
                if let camera = selection.shot.cameraID { field("Camera", camera) }
                Text("Sketch moments").fontWeight(AppTheme.FontWeight.semibold)
                ForEach(Array(selection.shot.moments.enumerated()), id: \.element.id) { index, moment in
                    field("Moment \(index + 1) · \(seconds(moment.offsetTicks))", moment.intent)
                    if let problem = selection.sketchProblems[moment.id] {
                        Label(problem, systemImage: "photo.badge.exclamationmark").foregroundStyle(AppTheme.Status.warningColor)
                    } else if moment.asset == nil {
                        Label("Sketch missing", systemImage: "photo.badge.exclamationmark").foregroundStyle(AppTheme.Status.warningColor)
                    }
                }
            }
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .interfaceFont(size: AppTheme.Typography.ui)
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(title).foregroundStyle(AppTheme.Text.secondaryColor)
            Text(value).textSelection(.enabled)
        }
    }

    private func seconds(_ ticks: Int64) -> String { String(format: "%.2f s", selection.timebase.seconds(for: ticks)) }
}
