import AVFoundation
import AppKit

enum ExportError: LocalizedError {
    case unsupportedPreset
    case invalidFormat
    case xmlEncodingFailed(format: String)
    case xmlValidationFailed(version: String, reason: String)
    case xmlTimingInvalid(reason: String)
    case xmlInvalidCharacter(context: String, codePoint: String)
    case xmlWriteFailed(destination: URL, reason: String)
    case xmlMediaReadFailed(source: URL, reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPreset: "Export preset not supported on this system"
        case .invalidFormat: "Invalid export format"
        case .xmlEncodingFailed(let format):
            "The timeline couldn't be encoded as \(format). Try the export again."
        case .xmlValidationFailed(let version, _):
            "FCPXML \(version) validation failed. Try the export again or select another FCPXML version."
        case .xmlTimingInvalid(let reason):
            "The timeline contains a time value FCPXML cannot represent: \(reason)"
        case .xmlInvalidCharacter(let context, let codePoint):
            "\(context) contains the XML-incompatible control character \(codePoint). Remove it and export again."
        case .xmlWriteFailed(let destination, _):
            "Couldn’t export FCPXML to “\(destination.lastPathComponent)”. Choose another writable location and try again."
        case .xmlMediaReadFailed(let source, _):
            "Couldn’t read “\(source.lastPathComponent)” for FCPXML export. Relink the media and try again."
        }
    }

    var failureReason: String? {
        switch self {
        case .xmlValidationFailed(_, let reason),
             .xmlTimingInvalid(let reason),
             .xmlInvalidCharacter(let reason, _),
             .xmlWriteFailed(_, let reason),
             .xmlMediaReadFailed(_, let reason):
            reason
        case .unsupportedPreset, .invalidFormat, .xmlEncodingFailed(_):
            nil
        }
    }
}

struct ExportRunReport {
    let outputSize: CGSize
    let offlineMediaRefs: Set<String>
    let unprocessableMediaRefs: Set<String>
}

final class ExportCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func reset() {
        lock.withLock { value = false }
    }

    func cancel() {
        lock.withLock { value = true }
    }

    var isCancelled: Bool {
        lock.withLock { value }
    }
}

@Observable
@MainActor
final class ExportService {
    enum Event: Sendable, Equatable {
        case preparing
        case exporting
        case progress(Double)
    }

    var progress: Double = 0
    var isExporting = false
    var error: String?
    var lastReport: ExportRunReport?
    var lastFCPXMLReport: FCPXMLExportReport?

    func cancel() {
        cancelRequested = true
        cancellationFlag.cancel()
        activeExportSession?.cancelExport()
    }

    func export(
        timeline: Timeline,
        resolver liveResolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution,
        outputURL: URL,
        projectName: String = "Timeline Export",
        fcpxmlVersion: FCPXMLVersion = .default,
        fcpxmlTarget: FCPXMLTarget = .default,
        referenceOutputURL: URL? = nil,
        stagedMediaDirectoryURL: URL? = nil,
        preserveOutputIdentity: Bool = false,
        acquireSlot: Bool = true,
        event: (@MainActor @Sendable (Event) -> Void)? = nil
    ) async {
        error = nil
        lastReport = nil
        lastFCPXMLReport = nil
        cancelRequested = false
        cancellationFlag.reset()
        isExporting = true
        progress = 0
        event?(.preparing)
        defer { isExporting = false }
        let resolver = liveResolver.snapshot()
        if acquireSlot {
            await ExportCoordinator.acquireExport()
        }
        defer { if acquireSlot { ExportCoordinator.endExport() } }
        var styleReview: TimelineStyleReview.Snapshot?
        if format != .xml && format != .fcpxml {
            do {
                styleReview = try await TimelineStyleReview.capture(timeline: timeline, resolver: resolver)
                if let review = styleReview {
                    try TimelineStyleReview.requireCurrent(review)
                }
            } catch { self.error = error.localizedDescription; return }
        }

        if format == .xml || format == .fcpxml {
            let formatName = format.fileExtension
            Log.export.notice(
                "export requested format=\(formatName)",
                telemetry: "Export started",
                data: [
                    "format": formatName,
                    "tracks": timeline.tracks.count,
                    "clips": timeline.tracks.reduce(0) { $0 + $1.clips.count },
                ]
            )
            do {
                event?(.exporting)
                if format == .xml {
                    let cancellationFlag = cancellationFlag
                    try await Task.detached(priority: .userInitiated) {
                        try XMLExporter.export(
                            timeline: timeline,
                            resolver: resolver,
                            outputURL: outputURL,
                            preserveOutputIdentity: preserveOutputIdentity,
                            isCancelled: { cancellationFlag.isCancelled }
                        )
                    }.value
                } else {
                    lastFCPXMLReport = try await FCPXMLExporter.export(
                        timeline: timeline,
                        resolver: resolver,
                        projectName: projectName,
                        version: fcpxmlVersion,
                        target: fcpxmlTarget,
                        outputURL: outputURL,
                        publishedOutputURL: referenceOutputURL,
                        stagedMediaDirectoryURL: stagedMediaDirectoryURL,
                        preserveOutputIdentity: preserveOutputIdentity,
                        isCancelled: { [weak self] in self?.cancelRequested ?? true },
                        progress: { [weak self] value in
                            self?.progress = value
                            event?(.progress(value))
                        }
                    )
                }
                progress = 1.0
                event?(.progress(1.0))
                var evidence: [String: Any] = ["format": formatName]
                if let report = lastFCPXMLReport {
                    evidence["version"] = report.version.rawValue
                    evidence["target"] = report.target.rawValue
                    evidence["schemaProfile"] = report.validation.schemaProfile
                    evidence["assets"] = report.validation.assetCount
                    evidence["storyElements"] = report.validation.storyElementCount
                    evidence["sha256"] = report.outputSHA256
                    evidence["bytes"] = report.outputByteCount
                    evidence["mediaBytes"] = report.mediaByteCount
                    evidence["stagedProjectMedia"] = report.stagedProjectMediaCount
                    evidence["warnings"] = report.warnings.count
                }
                Log.export.notice(
                    "export ok format=\(formatName)",
                    telemetry: "Export finished",
                    data: evidence
                )
            } catch {
                let cancelled = cancelRequested || error is CancellationError
                self.error = cancelled ? "Export was cancelled" : error.localizedDescription
                Log.export.error(
                    "export failed format=\(formatName): \(Log.detail(error))",
                    telemetry: "Export failed",
                    data: ["format": formatName, "destination": outputURL.path, "error": Log.detail(error)]
                )
            }
            return
        }

        Log.export.notice(
            "export requested format=\(String(describing: format)) resolution=\(resolution.rawValue)",
            telemetry: "Export started",
            data: [
                "format": String(describing: format),
                "resolution": resolution.rawValue,
                "tracks": timeline.tracks.count,
                "clips": timeline.tracks.reduce(0) { $0 + $1.clips.count },
                "totalFrames": timeline.totalFrames,
                "fps": timeline.fps
            ]
        )

        do {
            if cancelRequested { throw CancellationError() }
            try await TimelineStyleReview.revalidate(styleReview, timeline: timeline, resolver: resolver)
            if cancelRequested { throw CancellationError() }
            let prepared = try await makeExportSession(
                timeline: timeline, resolver: resolver,
                format: format, resolution: resolution
            )
            if cancelRequested { throw CancellationError() }
            if styleReview != nil {
                guard prepared.result.offlineMediaRefs.isEmpty, prepared.result.unprocessableMediaRefs.isEmpty else {
                    throw ToolError("The export cannot reproduce the reviewed cut because media is offline or unprocessable. Repair the media and review the resulting cut again.")
                }
            }
            let session = prepared.session
            guard let fileType = format.utType else { throw ExportError.invalidFormat }
            if cancelRequested { throw CancellationError() }
            activeExportSession = session
            defer { activeExportSession = nil }

            // AVAssetExportSession fails if the file already exists
            try? FileManager.default.removeItem(at: outputURL)

            nonisolated(unsafe) let unsafeSession = session
            event?(.exporting)
            let progressTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    let p = Double(unsafeSession.progress)
                    if p != self.progress {
                        self.progress = p
                        event?(.progress(p))
                    }
                }
            }

            do {
                try await session.export(to: outputURL, as: fileType)
                try await TimelineStyleReview.revalidate(styleReview, timeline: timeline, resolver: resolver)
                let outputSize = await Self.encodedVideoSize(of: outputURL) ?? prepared.renderSize
                lastReport = ExportRunReport(
                    outputSize: outputSize,
                    offlineMediaRefs: prepared.result.offlineMediaRefs,
                    unprocessableMediaRefs: prepared.result.unprocessableMediaRefs
                )
                progress = 1.0
                event?(.progress(1.0))
                Log.export.notice(
                    "export ok",
                    telemetry: "Export finished",
                    data: ["format": String(describing: format), "resolution": resolution.rawValue]
                )
            } catch {
                if cancelRequested || error is CancellationError
                    || ((error as NSError).domain == NSCocoaErrorDomain
                        && (error as NSError).code == NSUserCancelledError) {
                    self.error = "Export was cancelled"
                    Log.export.notice(
                        "export cancelled",
                        telemetry: "Export cancelled",
                        data: ["format": String(describing: format), "resolution": resolution.rawValue]
                    )
                } else {
                    self.error = Log.detail(error)
                    Log.export.error(
                        "export failed: \(Log.detail(error))",
                        telemetry: "Export failed",
                        data: ["format": String(describing: format), "resolution": resolution.rawValue, "error": Log.detail(error)]
                    )
                }
            }

            progressTask.cancel()
        } catch {
            if cancelRequested || error is CancellationError {
                self.error = "Export was cancelled"
                Log.export.notice(
                    "export cancelled during setup",
                    telemetry: "Export cancelled",
                    data: ["format": String(describing: format), "resolution": resolution.rawValue]
                )
            } else {
                self.error = Log.detail(error)
                Log.export.error(
                    "export setup failed: \(Log.detail(error))",
                    telemetry: "Export setup failed",
                    data: ["format": String(describing: format), "resolution": resolution.rawValue, "error": Log.detail(error)]
                )
            }
        }

    }

    /// Writes a self-contained `.ngv` bundle (all media collected internally).
    @discardableResult
    func exportProjectPackage(
        timeline: Timeline,
        manifest: MediaManifest,
        generationLog: GenerationLog,
        sourceProjectURL: URL?,
        outputURL: URL,
        stagingURL: URL? = nil,
        acquireSlot: Bool = true,
        event: (@MainActor @Sendable (Event) -> Void)? = nil
    ) async -> ProjectPackageExporter.Report? {
        isExporting = true
        progress = 0
        error = nil
        lastReport = nil
        cancelRequested = false
        cancellationFlag.reset()
        event?(.preparing)
        defer { isExporting = false }

        if acquireSlot {
            await ExportCoordinator.acquireExport()
        }
        defer { if acquireSlot { ExportCoordinator.endExport() } }

        do {
            event?(.exporting)
            let cancellationFlag = cancellationFlag
            Log.export.notice(
                "ngv export start url=\(outputURL.lastPathComponent)",
                telemetry: "NexGenVideo project export started",
                data: [
                    "tracks": timeline.tracks.count,
                    "clips": timeline.tracks.reduce(0) { $0 + $1.clips.count },
                    "media": manifest.entries.count,
                    "generationLogEntries": generationLog.entries.count
                ]
            )
            let report = try await Task.detached(priority: .userInitiated) {
                try ProjectPackageExporter.export(
                    timeline: timeline, manifest: manifest, generationLog: generationLog,
                    sourceProjectURL: sourceProjectURL, to: outputURL,
                    stagingURL: stagingURL,
                    isCancelled: { cancellationFlag.isCancelled },
                    progress: { p in
                        Task { @MainActor in
                            self.progress = p
                            event?(.progress(p))
                        }
                    }
                )
            }.value
            progress = 1.0
            event?(.progress(1.0))
            Log.export.notice(
                "ngv export ok collected=\(report.collected.count) missing=\(report.missing.count)",
                telemetry: "NexGenVideo project export finished",
                data: ["collected": report.collected.count, "missing": report.missing.count]
            )
            return report
        } catch {
            self.error = Log.detail(error)
            Log.export.error(
                "ngv export failed: \(Log.detail(error))",
                telemetry: "NexGenVideo project export failed",
                data: ["error": Log.detail(error)]
            )
            return nil
        }
    }

    /// Encoded dimensions of the written file (natural size with preferred
    /// transform applied), the source of truth when a preset clamped the size.
    private static func encodedVideoSize(of url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let size = naturalSize.applying(transform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    private func makeExportSession(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution
    ) async throws -> (session: AVAssetExportSession, result: CompositionResult, renderSize: CGSize) {
        let timelineCanvas = CGSize(width: timeline.width, height: timeline.height)
        let renderSize = resolution.renderSize(for: timelineCanvas)

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { resolver.resolveURL(for: $0) },
            renderSize: renderSize
        )

        let presetName = exportPresetName(format: format, resolution: resolution)
        guard let session = AVAssetExportSession(asset: result.composition, presetName: presetName) else {
            throw ExportError.unsupportedPreset
        }
        session.audioMix = result.audioMix

        let mutableVC = result.videoComposition.mutableCopy() as! AVMutableVideoComposition
        if TextLayerController.hasVisibleText(in: timeline) {
            let (parent, videoLayer) = TextLayerController.buildForExport(
                timeline: timeline,
                fps: timeline.fps,
                renderSize: renderSize
            )
            mutableVC.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer,
                in: parent
            )
        }
        session.videoComposition = mutableVC
        return (session, result, renderSize)
    }

    // MARK: - Export preset mapping

    private func exportPresetName(format: ExportFormat, resolution: ExportResolution) -> String {
        switch format {
        case .h264:
            switch resolution {
            case .r720p: AVAssetExportPreset1280x720
            case .r1080p: AVAssetExportPreset1920x1080
            case .r4k: AVAssetExportPreset3840x2160
            // Size-named presets clamp dimensions; HighestQuality honours the
            // composition's renderSize, so 2K / Match Timeline export at their true size.
            case .r1440p, .matchTimeline: AVAssetExportPresetHighestQuality
            }
        case .h265:
            switch resolution {
            case .r720p: AVAssetExportPresetHEVCHighestQuality
            case .r1080p: AVAssetExportPresetHEVC1920x1080
            case .r4k: AVAssetExportPresetHEVC3840x2160
            case .r1440p, .matchTimeline: AVAssetExportPresetHEVCHighestQuality
            }
        case .prores:
            AVAssetExportPresetAppleProRes422LPCM
        case .xml, .fcpxml:
            AVAssetExportPresetPassthrough // unreachable — interchange exports return early
        }
    }

    private var activeExportSession: AVAssetExportSession?
    private var cancelRequested = false
    private let cancellationFlag = ExportCancellationFlag()
}
