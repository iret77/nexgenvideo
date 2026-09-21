import SwiftUI

private struct InspectorControlChrome: ViewModifier {
    var focused = false
    var mixed = false
    var error = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.xsSm)
                    .fill(isEnabled ? AppTheme.Background.baseColor : AppTheme.Background.raisedColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.xsSm)
                    .strokeBorder(border, lineWidth: AppTheme.BorderWidth.thin)
            )
            .opacity(isEnabled ? AppTheme.Opacity.opaque : AppTheme.Opacity.disabled)
            .onHover { hovered = isEnabled && $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: AppTheme.Anim.hover), value: hovered)
    }

    private var border: Color {
        guard isEnabled else { return AppTheme.Border.subtleColor }
        if error { return AppTheme.Status.errorColor }
        if focused { return AppTheme.Accent.primary }
        if mixed { return AppTheme.Border.primaryColor }
        return hovered ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor
    }
}

extension View {
    func inspectorControlChrome(focused: Bool = false, mixed: Bool = false, error: Bool = false) -> some View {
        modifier(InspectorControlChrome(focused: focused, mixed: mixed, error: error))
    }
}

private struct InspectorFormLayout: Layout {
    let scale: CGFloat
    let stacked: Bool
    private var gap: CGFloat { AppTheme.Spacing.sm }
    private var labelWidth: CGFloat { AppTheme.ComponentSize.inspectorLabelWidth * scale }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
            ?? AppTheme.ComponentSize.inspectorInlineMinWidth * scale
        guard subviews.count == 2 else {
            let height = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)).height ?? 0
            return CGSize(width: width, height: height)
        }
        let sizes = measuredSizes(width: width, subviews: subviews)
        return CGSize(
            width: width,
            height: sizes.inline
                ? max(sizes.label.height, sizes.control.height)
                : sizes.label.height + gap + sizes.control.height
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let sizes = measuredSizes(width: bounds.width, subviews: subviews)
        if sizes.inline {
            let height = max(sizes.label.height, sizes.control.height)
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + (height - sizes.label.height) / 2),
                proposal: ProposedViewSize(width: labelWidth, height: sizes.label.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX - sizes.control.width, y: bounds.minY + (height - sizes.control.height) / 2),
                proposal: ProposedViewSize(width: sizes.control.width, height: sizes.control.height)
            )
        } else {
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                proposal: ProposedViewSize(width: bounds.width, height: sizes.label.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX - sizes.control.width, y: bounds.minY + sizes.label.height + gap),
                proposal: ProposedViewSize(width: sizes.control.width, height: sizes.control.height)
            )
        }
    }

    private func measuredSizes(width: CGFloat, subviews: Subviews) -> (label: CGSize, control: CGSize, inline: Bool) {
        let inline = !stacked && width >= AppTheme.ComponentSize.inspectorInlineMinWidth * scale
        let controlWidth = inline ? max(0, width - labelWidth - gap) : width
        let inlineControl = subviews[1].sizeThatFits(ProposedViewSize(width: controlWidth, height: nil))
        let fitsInline = inline && inlineControl.width <= controlWidth
        let control = fitsInline
            ? inlineControl
            : subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let label = subviews[0].sizeThatFits(ProposedViewSize(width: fitsInline ? labelWidth : width, height: nil))
        return (label, control, fitsInline)
    }
}

struct InspectorFormRow<Trailing: View>: View {
    let label: String
    var icon: String? = nil
    var labelHelp: String? = nil
    var stacked = false
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.interfaceScale) private var interfaceScale

    var body: some View {
        InspectorFormLayout(scale: CGFloat(interfaceScale), stacked: stacked) {
            labelContent
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var labelContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
            if let icon {
                Image(systemName: icon)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, alignment: .leading)
                    .accessibilityHidden(true)
            }
            Text(label)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if let labelHelp {
                Image(systemName: "info.circle")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                    .help(labelHelp)
                    .accessibilityLabel(labelHelp)
            }
        }
    }
}

struct InspectorRow<Trailing: View>: View {
    let icon: String
    let label: String
    var labelHelp: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        InspectorFormRow(label: label, icon: icon, labelHelp: labelHelp, trailing: trailing)
    }
}

extension InspectorRow where Trailing == EmptyView {
    init(icon: String, label: String) {
        self.init(icon: icon, label: label, trailing: { EmptyView() })
    }
}
