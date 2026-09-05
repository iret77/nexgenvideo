import SwiftUI

struct AppearancePane: View {
    @AppStorage(AppTheme.Typography.scaleKey) private var textScale = AppTheme.Typography.standardScale

    var body: some View {
        SettingsSection("Appearance") {
            SettingsCard {
                SettingsRow(title: "Interface text", subtitle: "Increase text and controls without changing timeline timing or media.") {
                    Picker("Interface text", selection: $textScale) {
                        Text("Standard").tag(AppTheme.Typography.standardScale)
                        Text("Larger · 125%").tag(AppTheme.Typography.largeScale)
                        Text("Largest · 150%").tag(AppTheme.Typography.largestScale)
                    }
                    .labelsHidden()
                    .accessibilityLabel("Interface text size")
                }
            }
        }
    }
}
