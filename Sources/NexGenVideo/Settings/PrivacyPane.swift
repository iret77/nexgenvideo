import SwiftUI

struct PrivacyPane: View {
    @State private var telemetryEnabled: Bool = Telemetry.isEnabled

    private var didChange: Bool {
        telemetryEnabled != Telemetry.enabledForCurrentLaunch
    }

    var body: some View {
        SettingsSection("Diagnostics") {
            SettingsCard {
                SettingsToggleRow(
                    title: "Share crash and error reports",
                    subtitle: "Sends technical diagnostics and coarse project statistics to Sentry. Media files are never attached.",
                    isOn: $telemetryEnabled
                )
                .onChange(of: telemetryEnabled) { _, newValue in
                    Telemetry.isEnabled = newValue
                }

                if didChange {
                    SettingsDivider()
                    SettingsNotice(
                        text: "Restart NexGenVideo to apply this change.",
                        systemImage: "arrow.clockwise",
                        tone: .neutral
                    )
                }
            }
        }
    }
}
