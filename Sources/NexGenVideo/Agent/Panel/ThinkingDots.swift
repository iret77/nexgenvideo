import SwiftUI

struct ThinkingDots: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xsSm) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.ComponentSize.thinkingDotDiameter, height: AppTheme.ComponentSize.thinkingDotDiameter)
                    .opacity(phase == i ? AppTheme.Opacity.opaque : AppTheme.Opacity.moderate)
                    .animation(.easeInOut(duration: AppTheme.Anim.pulse), value: phase)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}
