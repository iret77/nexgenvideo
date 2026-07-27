import SwiftUI

struct NotificationsPane: View {
    @State private var notificationsEnabled: Bool = AppNotifications.isEnabled

    var body: some View {
        SettingsSection("Notifications") {
            SettingsCard {
                SettingsToggleRow(
                    title: "Show system notifications",
                    subtitle: "Notify when generations and background exports finish or fail.",
                    isOn: $notificationsEnabled
                )
                .onChange(of: notificationsEnabled) { _, newValue in
                    AppNotifications.isEnabled = newValue
                    if newValue {
                        AppNotifications.configure()
                    }
                }
            }
        }
    }
}
