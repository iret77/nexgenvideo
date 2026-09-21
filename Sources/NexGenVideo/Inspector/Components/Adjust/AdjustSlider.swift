import SwiftUI

struct AdjustSlider: View {
    let value: Double?
    let range: ClosedRange<Double>
    var gradient: [Color]? = nil
    var defaultValue: Double = 0
    var accessibilityName: String? = nil
    let onChanged: (Double) -> Void
    let onCommit: (Double) -> Void
    @Environment(\.isEnabled) private var isEnabled

    private var fraction: Double? {
        guard let value else { return nil }
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return nil }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    private func value(atX x: CGFloat, width: CGFloat) -> Double {
        let f = width > 0 ? min(1, max(0, x / width)) : 0
        return range.lowerBound + f * (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let thumbX = CGFloat(fraction ?? 0) * w
            ZStack(alignment: .leading) {
                track(width: w)
                if fraction != nil {
                    Circle()
                        .fill(AppTheme.Accent.primary)
                        .frame(width: AppTheme.Slider.thumbSize, height: AppTheme.Slider.thumbSize)
                        .overlay(Circle().strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin))
                        .shadow(AppTheme.Shadow.sm)
                        .position(x: thumbX, y: geo.size.height / 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { _ in if isEnabled { onCommit(defaultValue) } }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onChanged(value(atX: $0.location.x, width: w)) }
                    .onEnded { onCommit(value(atX: $0.location.x, width: w)) }
            )
        }
        .frame(height: AppTheme.Slider.thumbSize)
        .allowsHitTesting(isEnabled)
        .opacity(isEnabled ? AppTheme.Opacity.opaque : AppTheme.Opacity.disabled)
        .accessibilityLabel(accessibilityName ?? "Adjustment")
        .accessibilityValue(value.map { String($0) } ?? "Mixed values")
    }

    @ViewBuilder
    private func track(width: CGFloat) -> some View {
        if let gradient {
            Capsule()
                .fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                .frame(height: AppTheme.Slider.trackHeight)
        } else {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.Background.prominentColor)
                    .frame(height: AppTheme.Slider.trackHeight)
                Capsule()
                    .fill(AppTheme.Text.tertiaryColor)
                    .frame(width: max(0, CGFloat(fraction ?? 0) * width), height: AppTheme.Slider.trackHeight)
            }
        }
    }
}
