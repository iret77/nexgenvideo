import SwiftUI

struct AgentActivityTiming: Equatable {
    let startedAt: Date
    let lastEventAt: Date?

    func elapsed(at now: Date) -> Int { max(0, Int(now.timeIntervalSince(startedAt))) }
    func silence(at now: Date) -> Int { max(0, Int(now.timeIntervalSince(lastEventAt ?? startedAt))) }
    func isUnconfirmed(at now: Date) -> Bool { silence(at: now) >= 60 }
}

struct AgentActivityProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let timing: AgentActivityTiming
    let completed: Int
    let total: Int
    let events: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if total > 0 {
                ProgressView(value: Double(min(completed, total)), total: Double(total))
                    .progressViewStyle(.linear)
                Text("\(completed) of \(total) in this operation")
            } else {
                if !reduceMotion { ProgressView().progressViewStyle(.linear) }
                Text("Total work not yet known")
            }
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("Elapsed: \(timing.elapsed(at: context.date)) s")
                    Text(timing.lastEventAt == nil
                        ? "No backend response received yet"
                        : "Last activity: \(timing.silence(at: context.date)) s ago")
                    if timing.isUnconfirmed(at: context.date) {
                        Text("No recent response. The current state cannot be confirmed.")
                            .foregroundStyle(AppTheme.Status.warningColor)
                    }
                }
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            }
            if !events.isEmpty {
                DisclosureGroup("Show activity") {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        Text(event).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.bottom, AppTheme.Spacing.sm)
    }
}
