import SwiftUI

// The app's only disclosure control. The toggle is an ordinary button, so pointer, keyboard, VoiceOver and acceptance input share one path.
struct DisclosureSection<Label: View, Content: View>: View {
    private let probe: String?
    private let isExpanded: Binding<Bool>?
    private let content: () -> Content
    private let label: () -> Label
    @State private var ownExpanded = false

    init(probe: String? = nil, isExpanded: Binding<Bool>? = nil, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder label: @escaping () -> Label) {
        self.probe = probe
        self.isExpanded = isExpanded
        self.content = content
        self.label = label
    }

    var body: some View {
        let expanded = isExpanded ?? $ownExpanded
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            if let probe {
                toggle(expanded).reviewAcceptanceProbe(probe, text: expanded.wrappedValue ? "expanded" : "collapsed")
            } else {
                toggle(expanded)
            }
            if expanded.wrappedValue {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) { content() }
                    .padding(.leading, AppTheme.IconSize.xxs + AppTheme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "chevron.right")
                    .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    .animation(.easeInOut(duration: AppTheme.Anim.selection), value: expanded.wrappedValue)
                    .frame(width: AppTheme.IconSize.xxs)
                    .accessibilityHidden(true)
                label()
            }
        }
        .buttonStyle(DisclosureSectionButtonStyle())
        .accessibilityValue(expanded.wrappedValue ? Text("Expanded") : Text("Collapsed"))
        .accessibilityHint(Text("Shows or hides the section"))
    }
}

extension DisclosureSection where Label == Text {
    init(_ title: LocalizedStringKey, probe: String? = nil, isExpanded: Binding<Bool>? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(probe: probe, isExpanded: isExpanded, content: content) { Text(title) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, probe: String? = nil, isExpanded: Binding<Bool>? = nil,
                            @ViewBuilder content: @escaping () -> Content) {
        self.init(probe: probe, isExpanded: isExpanded, content: content) { Text(title) }
    }
}

private struct DisclosureSectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? AppTheme.Text.primaryColor : AppTheme.Text.disabledControlColor)
                .opacity(isEnabled ? (configuration.isPressed ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
                    : AppTheme.Opacity.disabledControl)
                .contentShape(Rectangle())
                .modifier(ControlKeyboardFocusRing(radius: AppTheme.Radius.xs))
        }
    }
}
