import SwiftUI

struct AgentActivityEvent: Equatable {
    let at: Date?
    let label: String

    static func appending(_ event: AgentActivityEvent, to events: [AgentActivityEvent], limit: Int = 8) -> [AgentActivityEvent] {
        guard events.last?.label != event.label else { return events }
        return Array((events + [event]).suffix(limit))
    }
}

struct AgentActivityTiming: Equatable {
    static let unconfirmedAfterSeconds = 60

    let startedAt: Date
    let lastEventAt: Date?
    var providerConfirmedAt: Date? = nil

    var lastSignalAt: Date? { [lastEventAt, providerConfirmedAt].compactMap { $0 }.max() }

    func elapsed(at now: Date) -> Int { Self.seconds(from: startedAt, to: now) }
    func silence(at now: Date) -> Int { Self.seconds(from: lastSignalAt ?? startedAt, to: now) }
    func isUnconfirmed(at now: Date) -> Bool { silence(at: now) >= Self.unconfirmedAfterSeconds }

    static func seconds(from start: Date, to end: Date) -> Int { max(0, Int(end.timeIntervalSince(start))) }

    static func clock(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

struct AgentActivityProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let timing: AgentActivityTiming
    let completed: Int
    let total: Int
    var scope: String = "in this operation"
    let events: [AgentActivityEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if total > 0 {
                ProgressView(value: Double(min(completed, total)), total: Double(total))
                    .progressViewStyle(.linear)
                    .accessibilityLabel("\(completed) of \(total) \(scope)")
                Text("\(completed) of \(total) \(scope)")
            }
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                let unconfirmed = timing.isUnconfirmed(at: context.date)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    if unconfirmed {
                        Text("No response for \(AgentActivityTiming.clock(timing.silence(at: context.date))). The current state cannot be confirmed.")
                            .foregroundStyle(AppTheme.Status.warningColor)
                    }
                    DisclosureGroup("Show activity") {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Text("Elapsed \(AgentActivityTiming.clock(timing.elapsed(at: context.date)))")
                            if let lastEventAt = timing.lastEventAt {
                                Text("Last progress event \(Self.ago(lastEventAt, at: context.date)) ago")
                            }
                            if let confirmed = timing.providerConfirmedAt {
                                Text("Provider reports running · \(Self.ago(confirmed, at: context.date)) ago")
                            }
                            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                                Text(eventText(event)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: unconfirmed) { _, isUnconfirmed in
                    let announcement = isUnconfirmed
                        ? "No recent response. The current state cannot be confirmed."
                        : "Response received"
                    AccessibilityNotification.Announcement(announcement).post()
                }
            }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.bottom, AppTheme.Spacing.sm)
    }

    private func eventText(_ event: AgentActivityEvent) -> String {
        guard let at = event.at else { return event.label }
        return "\(AgentActivityTiming.clock(AgentActivityTiming.seconds(from: timing.startedAt, to: at))) · \(event.label)"
    }

    private static func ago(_ date: Date, at now: Date) -> String {
        AgentActivityTiming.clock(AgentActivityTiming.seconds(from: date, to: now))
    }
}
