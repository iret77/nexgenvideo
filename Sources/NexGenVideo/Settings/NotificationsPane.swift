import SwiftUI

struct NotificationsPane: View {
    @State private var notificationsEnabled: Bool
    private let save: @MainActor (Bool) -> Void
    private let configure: @MainActor () -> Void

    init(enabled: Bool = AppNotifications.isEnabled,
         save: @escaping @MainActor (Bool) -> Void = { AppNotifications.isEnabled = $0 },
         configure: @escaping @MainActor () -> Void = { AppNotifications.configure() }) {
        _notificationsEnabled = State(initialValue: enabled)
        self.save = save; self.configure = configure
    }

    var body: some View {
        SettingsSection("Notifications") {
            SettingsCard {
                SettingsToggleRow(
                    title: "Show system notifications",
                    subtitle: "Notify when generations and background exports finish or fail.",
                    isOn: $notificationsEnabled
                )
                .onChange(of: notificationsEnabled) { _, newValue in
                    save(newValue)
                    if newValue {
                        configure()
                    }
                }
                .reviewAcceptanceProbe("settings.general.notifications", text: String(notificationsEnabled))
            }
        }
    }
}
