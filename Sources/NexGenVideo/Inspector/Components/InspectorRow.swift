import SwiftUI

private struct InspectorKeyframeAccessoryColumnKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var inspectorKeyframeAccessoryColumn: Bool {
        get { self[InspectorKeyframeAccessoryColumnKey.self] }
        set { self[InspectorKeyframeAccessoryColumnKey.self] = newValue }
    }
}

extension View {
    func inspectorKeyframeAccessoryColumn(_ reserved: Bool) -> some View {
        environment(\.inspectorKeyframeAccessoryColumn, reserved)
    }
}

private struct InspectorKeyframesLayout: Layout {
    let scale: CGFloat

    private var gap: CGFloat { AppTheme.Spacing.sm }
    private var separatorWidth: CGFloat { AppTheme.BorderWidth.thin }
    private var paneMinWidth: CGFloat { AppTheme.ComponentSize.inspectorInlineMinWidth * scale }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
            ?? paneMinWidth * 2 + gap * 2 + separatorWidth
        guard subviews.count == 3 else { return .zero }
        if usesHorizontalLayout(width: width) {
            let paneWidth = max(0, (width - gap * 2 - separatorWidth) / 2)
            let controls = subviews[0].sizeThatFits(ProposedViewSize(width: paneWidth, height: nil))
            let keyframes = subviews[2].sizeThatFits(ProposedViewSize(width: paneWidth, height: nil))
            return CGSize(width: width, height: max(controls.height, keyframes.height))
        }
        let controls = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let keyframes = subviews[2].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(
            width: width,
            height: controls.height + gap * 2 + separatorWidth + keyframes.height
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        if usesHorizontalLayout(width: bounds.width) {
            let paneWidth = max(0, (bounds.width - gap * 2 - separatorWidth) / 2)
            let controls = subviews[0].sizeThatFits(ProposedViewSize(width: paneWidth, height: nil))
            let keyframes = subviews[2].sizeThatFits(ProposedViewSize(width: paneWidth, height: nil))
            let height = max(controls.height, keyframes.height)
            subviews[0].place(
                at: bounds.origin,
                proposal: ProposedViewSize(width: paneWidth, height: controls.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX + paneWidth + gap, y: bounds.minY),
                proposal: ProposedViewSize(width: separatorWidth, height: height)
            )
            subviews[2].place(
                at: CGPoint(x: bounds.minX + paneWidth + gap * 2 + separatorWidth, y: bounds.minY),
                proposal: ProposedViewSize(width: paneWidth, height: keyframes.height)
            )
        } else {
            let controls = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let keyframes = subviews[2].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(
                at: bounds.origin,
                proposal: ProposedViewSize(width: bounds.width, height: controls.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + controls.height + gap),
                proposal: ProposedViewSize(width: bounds.width, height: separatorWidth)
            )
            subviews[2].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + controls.height + gap * 2 + separatorWidth),
                proposal: ProposedViewSize(width: bounds.width, height: keyframes.height)
            )
        }
    }

    private func usesHorizontalLayout(width: CGFloat) -> Bool {
        width >= paneMinWidth * 2 + gap * 2 + separatorWidth
    }
}

struct InspectorKeyframesContent<Controls: View, Keyframes: View>: View {
    let isPresented: Bool
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let keyframes: () -> Keyframes
    @Environment(\.interfaceScale) private var interfaceScale

    init(
        isPresented: Bool,
        @ViewBuilder controls: @escaping () -> Controls,
        @ViewBuilder keyframes: @escaping () -> Keyframes
    ) {
        self.isPresented = isPresented
        self.controls = controls
        self.keyframes = keyframes
    }

    @ViewBuilder
    var body: some View {
        if isPresented {
            InspectorKeyframesLayout(scale: CGFloat(interfaceScale)) {
                InspectorFormSlot { controls() }
                Rectangle().fill(AppTheme.Border.subtleColor)
                InspectorFormSlot { keyframes() }
            }
        } else {
            controls()
        }
    }
}

struct InspectorAdaptiveControlPair<First: View, Second: View>: View {
    let spacing: CGFloat
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second

    init(
        spacing: CGFloat,
        @ViewBuilder first: @escaping () -> First,
        @ViewBuilder second: @escaping () -> Second
    ) {
        self.spacing = spacing
        self.first = first
        self.second = second
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) {
                first()
                second()
            }
            .fixedSize()
            VStack(alignment: .trailing, spacing: spacing) {
                first()
                second()
            }
            .fixedSize()
        }
    }
}

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
    let accessoryColumn: Bool
    private var gap: CGFloat { AppTheme.Spacing.sm }
    private var labelWidth: CGFloat { AppTheme.ComponentSize.inspectorLabelWidth * scale }
    private var accessoryWidth: CGFloat {
        accessoryColumn ? AppTheme.Timeline.keyframeControlsColumnWidth : 0
    }
    private var accessoryGap: CGFloat { accessoryColumn ? gap : 0 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
            ?? AppTheme.ComponentSize.inspectorInlineMinWidth * scale
        guard subviews.count >= 2 else {
            let height = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)).height ?? 0
            return CGSize(width: width, height: height)
        }
        let sizes = measuredSizes(width: width, subviews: subviews)
        return CGSize(width: width, height: rowHeight(sizes))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let sizes = measuredSizes(width: bounds.width, subviews: subviews)
        let controlMaxX = sizes.accessoryAlongside
            ? bounds.maxX - accessoryWidth - accessoryGap
            : bounds.maxX
        if sizes.inline {
            let height = max(sizes.label.height, max(sizes.control.height, sizes.accessory.height))
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + (height - sizes.label.height) / 2),
                proposal: ProposedViewSize(width: labelWidth, height: sizes.label.height)
            )
            subviews[1].place(
                at: CGPoint(x: controlMaxX - sizes.control.width, y: bounds.minY + (height - sizes.control.height) / 2),
                proposal: ProposedViewSize(width: sizes.control.width, height: sizes.control.height)
            )
            placeAccessoryAlongside(
                in: bounds,
                lineY: bounds.minY,
                lineHeight: height,
                subviews: subviews,
                size: sizes.accessory
            )
        } else {
            let controlLineHeight = sizes.accessoryAlongside
                ? max(sizes.control.height, sizes.accessory.height)
                : sizes.control.height
            let controlLineY = bounds.minY + sizes.label.height + gap
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                proposal: ProposedViewSize(width: bounds.width, height: sizes.label.height)
            )
            subviews[1].place(
                at: CGPoint(
                    x: max(bounds.minX, controlMaxX - sizes.control.width),
                    y: controlLineY + (controlLineHeight - sizes.control.height) / 2
                ),
                proposal: ProposedViewSize(width: sizes.control.width, height: sizes.control.height)
            )
            if sizes.accessoryAlongside {
                placeAccessoryAlongside(
                    in: bounds,
                    lineY: controlLineY,
                    lineHeight: controlLineHeight,
                    subviews: subviews,
                    size: sizes.accessory
                )
            } else if sizes.accessoryPresent {
                subviews[2].place(
                    at: CGPoint(
                        x: max(bounds.minX, bounds.maxX - accessoryWidth),
                        y: controlLineY + sizes.control.height + gap
                    ),
                    proposal: ProposedViewSize(width: min(accessoryWidth, bounds.width), height: sizes.accessory.height)
                )
            }
        }
    }

    private struct Sizes {
        let label: CGSize
        let control: CGSize
        let accessory: CGSize
        let inline: Bool
        let accessoryPresent: Bool
        let accessoryAlongside: Bool
    }

    private func measuredSizes(
        width: CGFloat,
        subviews: Subviews
    ) -> Sizes {
        let canUseColumns = width >= AppTheme.ComponentSize.inspectorInlineMinWidth * scale
        let contentWidth = max(0, width - accessoryWidth - accessoryGap)
        let controlWidth = canUseColumns ? max(0, contentWidth - labelWidth - gap) : width
        let inlineControl = subviews[1].sizeThatFits(ProposedViewSize(width: controlWidth, height: nil))
        let fitsInline = !stacked && canUseColumns && inlineControl.width <= controlWidth
        let control = fitsInline
            ? inlineControl
            : subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let label = subviews[0].sizeThatFits(ProposedViewSize(width: fitsInline ? labelWidth : width, height: nil))
        let accessory = accessoryColumn && subviews.count > 2
            ? subviews[2].sizeThatFits(ProposedViewSize(width: accessoryWidth, height: nil))
            : CGSize.zero
        let accessoryPresent = accessory.width > 0 && accessory.height > 0
        let accessoryAlongside = accessoryColumn
            && canUseColumns
            && control.width + accessoryWidth + accessoryGap <= width
        return Sizes(
            label: label,
            control: control,
            accessory: accessory,
            inline: fitsInline,
            accessoryPresent: accessoryPresent,
            accessoryAlongside: accessoryAlongside
        )
    }

    private func rowHeight(_ sizes: Sizes) -> CGFloat {
        if sizes.inline {
            return max(sizes.label.height, max(sizes.control.height, sizes.accessory.height))
        }
        let controlHeight = sizes.accessoryAlongside
            ? max(sizes.control.height, sizes.accessory.height)
            : sizes.control.height
        let separateAccessoryHeight = sizes.accessoryPresent && !sizes.accessoryAlongside
            ? gap + sizes.accessory.height
            : 0
        return sizes.label.height + gap + controlHeight + separateAccessoryHeight
    }

    private func placeAccessoryAlongside(
        in bounds: CGRect,
        lineY: CGFloat,
        lineHeight: CGFloat,
        subviews: Subviews,
        size: CGSize
    ) {
        guard accessoryColumn, subviews.count > 2 else { return }
        subviews[2].place(
            at: CGPoint(x: bounds.maxX - accessoryWidth, y: lineY + (lineHeight - size.height) / 2),
            proposal: ProposedViewSize(width: accessoryWidth, height: size.height)
        )
    }
}

private struct InspectorFormSlot<Content: View>: View {
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
    }
}

struct InspectorFormRow<Trailing: View, Accessory: View>: View {
    let label: String
    let icon: String?
    let labelHelp: String?
    let stacked: Bool
    let reservesAccessoryColumn: Bool
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let accessory: () -> Accessory
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.inspectorKeyframeAccessoryColumn) private var groupReservesAccessoryColumn

    init(
        label: String,
        icon: String? = nil,
        labelHelp: String? = nil,
        stacked: Bool = false,
        reservesAccessoryColumn: Bool = true,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.label = label
        self.icon = icon
        self.labelHelp = labelHelp
        self.stacked = stacked
        self.reservesAccessoryColumn = reservesAccessoryColumn
        self.trailing = trailing
        self.accessory = accessory
    }

    var body: some View {
        InspectorFormLayout(
            scale: CGFloat(interfaceScale),
            stacked: stacked,
            accessoryColumn: reservesAccessoryColumn || groupReservesAccessoryColumn
        ) {
            InspectorFormSlot { labelContent }
            InspectorFormSlot { trailing() }
            InspectorFormSlot { accessory() }
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

extension InspectorFormRow where Accessory == EmptyView {
    init(
        label: String,
        icon: String? = nil,
        labelHelp: String? = nil,
        stacked: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(
            label: label,
            icon: icon,
            labelHelp: labelHelp,
            stacked: stacked,
            reservesAccessoryColumn: false,
            trailing: trailing,
            accessory: { EmptyView() }
        )
    }
}

struct InspectorAnimatableFormRow<Fields: View, Accessory: View>: View {
    let label: String
    let showsAccessory: Bool
    @ViewBuilder let fields: () -> Fields
    @ViewBuilder let accessory: () -> Accessory

    init(
        label: String,
        showsAccessory: Bool = true,
        @ViewBuilder fields: @escaping () -> Fields,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.label = label
        self.showsAccessory = showsAccessory
        self.fields = fields
        self.accessory = accessory
    }

    var body: some View {
        InspectorFormRow(
            label: label,
            reservesAccessoryColumn: showsAccessory,
            trailing: fields,
            accessory: accessory
        )
        .frame(minHeight: AppTheme.Timeline.keyframeRowHeight)
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
