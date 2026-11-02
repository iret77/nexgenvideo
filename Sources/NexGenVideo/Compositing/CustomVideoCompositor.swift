import AVFoundation
import CoreImage
import Metal

/// Core Image compositor shared by preview (AVPlayerItem) and export (AVAssetExportSession).
final class CustomVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

    struct RenderError: Error {}

    static let ciContext = VideoRenderContext.context

    private let queue = DispatchQueue(label: "de.h5ventures.nexgenvideo.compositor", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: AVAsynchronousVideoCompositionRequest] = [:]

    override init() {
        super.init()
        FilmReviewExportDiagnostic.created(self)
    }

    deinit {
        FilmReviewExportDiagnostic.destroyed(self, pendingCount: pending.count)
    }

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let instance = FilmReviewExportDiagnostic.identity(self)
        FilmReviewExportDiagnostic.request("started", instance: instance, request: request)
        lock.lock()
        pending[ObjectIdentifier(request)] = request
        lock.unlock()

        queue.async { [weak self] in
            guard let self else {
                FilmReviewExportDiagnostic.request("dropped", instance: instance, request: request)
                return
            }
            self.lock.lock()
            let live = self.pending.removeValue(forKey: ObjectIdentifier(request)) != nil
            self.lock.unlock()
            guard live else { return }
            Self.process(request, instance: instance)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        let cancelled = pending.values
        pending.removeAll()
        lock.unlock()
        for request in cancelled {
            request.finishCancelledRequest()
            FilmReviewExportDiagnostic.request("cancelled", instance: FilmReviewExportDiagnostic.identity(self), request: request)
        }
    }

    private static func process(_ request: AVAsynchronousVideoCompositionRequest, instance: Int) {
        guard let instruction = request.videoCompositionInstruction as? CompositorInstruction else {
            // Foreign instruction (shouldn't happen): pass the first source through.
            if let first = request.sourceTrackIDs.first,
               let buffer = request.sourceFrame(byTrackID: first.int32Value) {
                request.finish(withComposedVideoFrame: buffer)
                FilmReviewExportDiagnostic.request("frame", instance: instance, request: request)
            } else {
                request.finish(with: RenderError())
                FilmReviewExportDiagnostic.request("error", instance: instance, request: request)
            }
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: RenderError())
            FilmReviewExportDiagnostic.request("error", instance: instance, request: request)
            return
        }
        FrameRenderer.render(
            instruction: instruction,
            sourceFrame: { request.sourceFrame(byTrackID: $0) },
            compositionTime: request.compositionTime,
            into: output,
            context: ciContext
        )
        request.finish(withComposedVideoFrame: output)
        FilmReviewExportDiagnostic.request("frame", instance: instance, request: request)
    }
}
