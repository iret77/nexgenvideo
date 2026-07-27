import SwiftUI

struct GeneratingOverlay: View {
    enum Size {
        case thumbnail
        case preview

        var fontSize: CGFloat { self == .preview ? AppTheme.FontSize.xl : AppTheme.FontSize.xs }
        var spacing: CGFloat { self == .preview ? AppTheme.Spacing.lg : AppTheme.Spacing.smMd }
        var barWidth: CGFloat {
            self == .preview
                ? AppTheme.Generating.previewBarWidth
                : AppTheme.Generating.thumbnailBarWidth
        }
        var barHeight: CGFloat {
            self == .preview
                ? AppTheme.Generating.previewBarHeight
                : AppTheme.Generating.thumbnailBarHeight
        }
    }

    var label: String = "Generating…"
    var size: Size = .thumbnail

    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .shimmering(active: !reduceMotion)
            .onAppear {
                if reduceMotion {
                    progress = AppTheme.Generating.progressTarget
                } else {
                    withAnimation(.easeOut(duration: AppTheme.Generating.progressDuration)) {
                        progress = AppTheme.Generating.progressTarget
                    }
                }
            }
    }

    private var content: some View {
        VStack(spacing: size.spacing) {
            Text(label)
                .font(.system(size: size.fontSize, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.aiGradient)
            progressBar
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.muted))
                Capsule()
                    .fill(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.strong))
                    .frame(width: geo.size.width * progress)
            }
        }
        .frame(width: size.barWidth, height: size.barHeight)
    }
}

private struct ShimmerModifier: ViewModifier {
    let active: Bool

    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { geo in
                        LinearGradient(
                            stops: [
                                .init(color: AppTheme.Background.clearColor, location: 0),
                                .init(
                                    color: AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.shimmer),
                                    location: 0.48
                                ),
                                .init(color: AppTheme.Background.clearColor, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: geo.size.width * AppTheme.Generating.shimmerWidthFraction)
                        .rotationEffect(.degrees(AppTheme.Generating.shimmerRotationDegrees))
                        .offset(x: geo.size.width * phase)
                    }
                    .blendMode(.screen)
                    .mask(content)
                }
            }
            .onAppear {
                guard active else { return }
                phase = -1
                withAnimation(
                    .linear(duration: AppTheme.Generating.shimmerDuration)
                        .repeatForever(autoreverses: false)
                ) {
                    phase = 2
                }
            }
    }
}

private extension View {
    func shimmering(active: Bool) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}
