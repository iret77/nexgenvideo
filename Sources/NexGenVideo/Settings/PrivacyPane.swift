import SwiftUI

struct PrivacyPane: View {
    @State private var telemetryEnabled: Bool
    private let launchEnabled: Bool
    private let save: (Bool) -> Void

    init(enabled: Bool = Telemetry.isEnabled, launchEnabled: Bool = Telemetry.enabledForCurrentLaunch,
         save: @escaping (Bool) -> Void = { Telemetry.isEnabled = $0 }) {
        _telemetryEnabled = State(initialValue: enabled)
        self.launchEnabled = launchEnabled; self.save = save
    }

    private var didChange: Bool {
        telemetryEnabled != launchEnabled
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
                    save(newValue)
                }
                .reviewAcceptanceProbe("settings.general.telemetry", text: String(telemetryEnabled))

                if didChange {
                    SettingsDivider()
                    SettingsNotice(
                        text: "Restart NexGenVideo to apply this change.",
                        systemImage: "arrow.clockwise",
                        tone: .neutral
                    )
                    .reviewAcceptanceProbe("settings.general.telemetry.restart")
                }
            }
        }
    }
}
