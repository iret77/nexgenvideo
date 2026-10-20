import AVKit
import ImageIO
import NexGenEngine
import SwiftUI

struct ProductionInputRange: Sendable, Equatable {
    let timebase: RationalTimebaseV1
    let startTicks: Int64
    let durationTicks: Int64

    func timeRange() throws -> CMTimeRange {
        try timebase.validate()
        let end = startTicks.addingReportingOverflow(durationTicks)
        guard startTicks >= 0, durationTicks > 0, !end.overflow else { throw ToolError("The source range is invalid.") }
        return CMTimeRange(start: CMTime(value: startTicks, timescale: Int32(timebase.ticksPerSecond)),
            duration: CMTime(value: durationTicks, timescale: Int32(timebase.ticksPerSecond)))
    }
}

@MainActor
enum ProductionSourceVideoPreview {
    nonisolated static func thumbnail(source: AVAsset, range: ProductionInputRange?) async throws -> CGImage {
        guard !(try await source.loadTracks(withMediaType: .video)).isEmpty else {
            throw ToolError("This input has no readable video track.")
        }
        let generator = AVAssetImageGenerator(asset: source)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let interval = try range?.timeRange()
        if let interval {
            let duration = try await source.load(.duration)
            guard duration.isNumeric, CMTimeCompare(duration, interval.end) >= 0 else {
                throw ToolError("The source video is shorter than the selected range.")
            }
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        let (image, _) = try await generator.image(at: interval?.start ?? .zero)
        return image
    }

    static func asset(source: AVAsset, range: ProductionInputRange) async throws -> AVMutableComposition {
        let interval = try range.timeRange()
        let duration = try await source.load(.duration)
        guard duration.isNumeric, CMTimeCompare(duration, interval.end) >= 0 else {
            throw ToolError("The source video is shorter than the selected range.")
        }
        let sourceTracks = try await source.loadTracks(withMediaType: .video)
        guard !sourceTracks.isEmpty else { throw ToolError("This input has no readable video track.") }
        let composition = AVMutableComposition()
        try await composition.insertTimeRange(interval, of: source, at: .zero)
        for mutable in composition.tracks(withMediaType: .video) {
            guard let sourceID = mutable.segments.first(where: { !$0.isEmpty })?.sourceTrackID,
                  let original = sourceTracks.first(where: { $0.trackID == sourceID }) else {
                throw ToolError("The source video's display orientation could not be preserved.")
            }
            mutable.preferredTransform = try await original.load(.preferredTransform)
        }
        return composition
    }
}

struct ProductionInputPreview: View {
    let reference: CanonicalArtifactReferenceV1
    let dataRoot: URL
    let title: String
    var sourceRange: ProductionInputRange?
    @State private var image: CGImage?
    @State private var failure: String?
    @State private var inspecting = false
    @State private var generation = UUID()

    private var isImage: Bool { ProjectMediaExtensions.images.contains((reference.path as NSString).pathExtension.lowercased()) }
    private var isAudio: Bool { AudioProjectLayout.audioExtensions.contains((reference.path as NSString).pathExtension.lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(title).fontWeight(AppTheme.FontWeight.medium)
            if isAudio {
                ProductionAudioInputPreview(reference: reference, dataRoot: dataRoot, sourceRange: sourceRange)
            } else if let image {
                Button { inspecting = true } label: {
                    Image(image, scale: 1, label: Text(title)).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity).frame(height: AppTheme.Layout.previewMinHeight)
                }.buttonStyle(.plain).accessibilityLabel(isImage ? "Inspect \(title)" : "Play \(title)")
            } else if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor) }
            else { ProgressView("Loading input…") }
            if image != nil {
                Button(isImage ? "Inspect image" : "Play source video") { inspecting = true }
                    .buttonStyle(InlineActionButtonStyle())
                    .reviewAcceptanceProbe("production.input.\(isImage ? "image" : "video").open.\(reference.id)")
            }
            if let sourceRange {
                Text("Source \(ProductionTimeEntry.seconds(sourceRange.startTicks, timebase: sourceRange.timebase)) s · \(ProductionTimeEntry.seconds(sourceRange.durationTicks, timebase: sourceRange.timebase)) s duration")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
        .task(id: "\(dataRoot.path):\(reference.path):\(reference.sha256):\(String(describing: sourceRange))") { if !isAudio { await load() } }
        .onDisappear { generation = UUID() }
        .sheet(isPresented: $inspecting) {
            if isImage {
                ProductionImageInspectionView(url: dataRoot.appendingPathComponent(reference.path), sha256: reference.sha256, title: title)
            } else {
                ProductionVideoInspectionView(reference: reference, dataRoot: dataRoot, title: title, sourceRange: sourceRange)
            }
        }
    }

    private func load() async {
        let token = UUID(); generation = token; image = nil; failure = nil
        do {
            let reference = reference, root = dataRoot, imageInput = isImage, sourceRange = sourceRange
            let value = try await Task.detached(priority: .userInitiated) {
                let url = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)
                if imageInput {
                    let bytes = try Data(contentsOf: url)
                    guard FileDigest.sha256(of: bytes) == reference.sha256,
                          let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1280,
                          ] as CFDictionary) else { throw ToolError("The input image changed or cannot be opened.") }
                    return image
                }
                let asset = AVURLAsset(url: url)
                let image = try await ProductionSourceVideoPreview.thumbnail(source: asset, range: sourceRange)
                _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)
                return image
            }.value
            guard !Task.isCancelled, generation == token else { return }
            image = value
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            failure = error.localizedDescription
        }
    }
}

private struct ProductionAudioInputPreview: View {
    let reference: CanonicalArtifactReferenceV1
    let dataRoot: URL
    let sourceRange: ProductionInputRange?
    @State private var controller = PlaybackRangeAudioController()
    @State private var range: ProductionInputRange?
    @State private var failure: String?
    @State private var generation = UUID()
    @State private var playbackTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if let range {
                HStack(spacing: AppTheme.Spacing.md) {
                    Button(controller.playing || controller.preparing ? "Stop audio" : "Play audio") {
                        playbackTask?.cancel()
                        if controller.playing || controller.preparing { controller.stop() }
                        else {
                            playbackTask = Task {
                                await controller.play(audio: reference, timebase: range.timebase, startTicks: range.startTicks,
                                    endTicks: range.startTicks + range.durationTicks, dataRoot: dataRoot)
                            }
                        }
                    }.buttonStyle(InlineActionButtonStyle())
                    if controller.preparing { ProgressView().controlSize(.small) }
                    Text("\(ProductionTimeEntry.seconds(controller.playing ? controller.positionTicks - range.startTicks : 0, timebase: range.timebase)) / \(ProductionTimeEntry.seconds(range.durationTicks, timebase: range.timebase)) s")
                        .monospacedDigit().foregroundStyle(AppTheme.Text.secondaryColor)
                }
            } else if failure == nil { ProgressView("Reading audio…") }
            if let message = failure ?? controller.failure { Text(message).foregroundStyle(AppTheme.Status.errorColor) }
        }
        .task(id: "\(dataRoot.path):\(reference.path):\(reference.sha256):\(String(describing: sourceRange))") { await load() }
        .onDisappear { generation = UUID(); playbackTask?.cancel(); controller.stop() }
    }

    private func load() async {
        let token = UUID(); generation = token
        playbackTask?.cancel(); controller.stop(); range = nil; failure = nil
        do {
            let reference = reference, root = dataRoot, requested = sourceRange
            let value = try await Task.detached(priority: .userInitiated) {
                let url = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                guard duration.isNumeric, duration.value > 0, duration.timescale > 0,
                      !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                    throw ToolError("This input has no readable audio track.")
                }
                let result = requested ?? ProductionInputRange(timebase: .init(ticksPerSecond: Int64(duration.timescale), fpsNumerator: 1),
                    startTicks: 0, durationTicks: duration.value)
                guard CMTimeCompare(try result.timeRange().end, duration) <= 0 else {
                    throw ToolError("The audio input is shorter than its selected range.")
                }
                _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)
                return result
            }.value
            guard generation == token, !Task.isCancelled else { return }
            range = value
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
}

private struct ProductionVideoInspectionView: View {
    let reference: CanonicalArtifactReferenceV1
    let dataRoot: URL
    let title: String
    let sourceRange: ProductionInputRange?
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var failure: String?
    @State private var generation = UUID()

    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            HStack {
                Text(title).fontWeight(AppTheme.FontWeight.semibold)
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .reviewAcceptanceProbe("production.input.video.close")
            }
            if let player { VideoPlayer(player: player).reviewAcceptanceProbe("production.input.video.player", text: reference.sha256) }
            else if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor) }
            else { ProgressView("Opening video…") }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        .task { await load() }
        .onDisappear { generation = UUID(); player?.pause(); player = nil }
    }

    private func load() async {
        let token = UUID(); generation = token
        do {
            let reference = reference, root = dataRoot
            let url = try await Task.detached(priority: .userInitiated) {
                try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)
            }.value
            guard !Task.isCancelled, generation == token else { return }
            let asset = AVURLAsset(url: url)
            let prepared: AVPlayer
            if let sourceRange {
                let composition = try await ProductionSourceVideoPreview.asset(source: asset, range: sourceRange)
                prepared = AVPlayer(playerItem: AVPlayerItem(asset: composition))
            } else { prepared = AVPlayer(playerItem: AVPlayerItem(asset: asset)) }
            guard let item = prepared.currentItem else { throw ToolError("The source video could not be opened.") }
            let deadline = ContinuousClock.now + .seconds(10)
            while (prepared.status == .unknown || item.status == .unknown),
                  prepared.status != .failed, item.status != .failed, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                guard generation == token else { return }
            }
            guard prepared.status == .readyToPlay, item.status == .readyToPlay else {
                throw item.error ?? prepared.error ?? ToolError("The source video could not be opened.")
            }
            guard !Task.isCancelled, generation == token else { return }
            player = prepared
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            failure = error.localizedDescription
        }
    }
}
