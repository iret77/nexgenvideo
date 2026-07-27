import SwiftUI

struct ClipGeneratingOverlay: View {
    var body: some View {
        ZStack {
            AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.strong)
            GeneratingOverlay()
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Timeline.clipCornerRadius))
        .allowsHitTesting(false)
    }
}
