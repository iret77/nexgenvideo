import AVFoundation
import CoreImage

/// Immutable per-clip snapshot read on the render queue — never the live timeline.
struct LayerPlan: Sendable {
    let trackID: CMPersistentTrackID
    let clip: Clip
    /// Display size (preferredTransform applied), matching `clipNaturalSizes`.
    let natSize: CGSize
    let preferredTransform: CGAffineTransform
    var stillImage: CIImage? = nil
}

/// One timeline segment between clip boundaries. Layers are ordered bottom → top.
final class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    // Values are sampled per frame; never let AVFoundation cache one frame per instruction.
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [LayerPlan]
    let renderSize: CGSize
    let fps: Int

    init(timeRange: CMTimeRange, layers: [LayerPlan], renderSize: CGSize, fps: Int) {
        self.timeRange = timeRange
        self.layers = layers
        self.renderSize = renderSize
        self.fps = fps
        var seen = Set<CMPersistentTrackID>()
        self.requiredSourceTrackIDs = layers.compactMap {
            $0.stillImage == nil && $0.clip.mediaType != .text && seen.insert($0.trackID).inserted
                ? NSNumber(value: $0.trackID) : nil
        }
        super.init()
    }
}
