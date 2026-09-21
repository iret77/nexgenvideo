import AVFoundation
import SwiftUI

struct SlipPreviewState: Equatable {
    let url: URL
    let inSourceFrame: Int
    let outSourceFrame: Int
    let fps: Int
}

struct SlipTwoUpView: View {
    let state: SlipPreviewState

    @State private var inImage: CGImage?
    @State private var outImage: CGImage?
    @State private var pendingState: SlipPreviewState?
    @State private var loaderTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            AppTheme.Background.previewCanvasColor
            HStack(spacing: AppTheme.Spacing.xxs) {
                pane(image: inImage, label: "Start", frame: state.inSourceFrame)
                pane(image: outImage, label: "End", frame: state.outSourceFrame)
            }
        }
        .onAppear { enqueue(state) }
        .onChange(of: state) { _, next in enqueue(next) }
        .onDisappear {
            loaderTask?.cancel()
            loaderTask = nil
            pendingState = nil
        }
        .allowsHitTesting(false)
    }

    private func enqueue(_ state: SlipPreviewState) {
        pendingState = state
        guard loaderTask == nil else { return }
        loaderTask = Task { @MainActor in
            while let state = pendingState {
                self.pendingState = nil
                await load(state)
                try? await Task.sleep(for: AppTheme.Anim.slipPreviewRefresh)
                guard !Task.isCancelled else { break }
            }
            loaderTask = nil
        }
    }

    private func load(_ state: SlipPreviewState) async {
        let images = await SlipFrameLoader.frames(
            inSourceFrame: state.inSourceFrame,
            outSourceFrame: state.outSourceFrame,
            url: state.url,
            fps: state.fps
        )
        guard !Task.isCancelled else { return }
        inImage = images.start
        outImage = images.end
    }

    private func pane(image: CGImage?, label: String, frame: Int) -> some View {
        ZStack(alignment: .topLeading) {
            AppTheme.Background.previewCanvasColor
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(label)
                    .interfaceFont(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(formatTimecode(frame: frame, fps: state.fps))
                    .interfaceFont(size: AppTheme.FontSize.xs, design: .monospaced)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(
                AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.strong),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
            )
            .padding(AppTheme.Spacing.sm)
        }
        .clipped()
    }
}

private enum SlipFrameLoader {
    static func frames(
        inSourceFrame: Int,
        outSourceFrame: Int,
        url: URL,
        fps: Int
    ) async -> (start: CGImage?, end: CGImage?) {
        guard fps > 0 else { return (nil, nil) }
        let timescale = CMTimeScale(fps)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: AppTheme.ComponentSize.slipPreviewMaxDimension,
            height: AppTheme.ComponentSize.slipPreviewMaxDimension
        )
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: timescale)
        let inTime = CMTime(value: CMTimeValue(max(0, inSourceFrame)), timescale: timescale)
        let outTime = CMTime(value: CMTimeValue(max(0, outSourceFrame)), timescale: timescale)
        var start: CGImage?
        var end: CGImage?
        for await result in generator.images(for: [inTime, outTime]) {
            guard case let .success(requestedTime, image, _) = result else { continue }
            if CMTimeCompare(requestedTime, inTime) == 0 { start = image }
            if CMTimeCompare(requestedTime, outTime) == 0 { end = image }
        }
        return (start, end)
    }
}
