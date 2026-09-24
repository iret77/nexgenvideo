import Foundation

extension ToolExecutor {
    func exportProject(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: ExportProjectArgs = try decodeToolArgs(args, path: "export_project")
        let mode = try ExportProjectMode(named: input.mode)
        let overwrite = input.overwrite ?? true

        if mode != .video {
            if input.codec != nil {
                throw ToolError("export_project: codec only applies to video mode")
            }
            if input.resolution != nil {
                throw ToolError("export_project: resolution only applies to video mode")
            }
        }
        if mode != .fcpxml, input.version != nil || input.target != nil {
            throw ToolError("export_project: version and target only apply to fcpxml mode")
        }

        let format = try mode == .video ? ExportFormat.videoCodec(named: input.codec) : nil
        let resolution = try mode == .video ? ExportResolution.exportPreset(named: input.resolution) : .matchTimeline

        let outputURL = try exportDestination(
            outputPath: input.outputPath,
            mode: mode,
            format: format,
            editor: editor,
            overwrite: overwrite
        )

        switch mode {
        case .video:
            guard let format else {
                throw ToolError("export_project: codec is required for video mode")
            }
            guard editor.timeline.totalFrames > 0 else {
                throw ToolError("export_project: timeline is empty")
            }
            return try await exportVideo(
                editor,
                format: format,
                resolution: resolution,
                outputURL: outputURL,
                requestID: input.requestID
            )
        case .xml:
            return try await exportXML(editor, outputURL: outputURL, requestID: input.requestID)
        case .fcpxml:
            return try await exportFCPXML(
                editor,
                outputURL: outputURL,
                version: try FCPXMLVersion(named: input.version),
                target: try FCPXMLTarget(named: input.target),
                requestID: input.requestID
            )
        case .nexgen:
            return try await exportProjectPackage(
                editor,
                outputURL: outputURL,
                requestID: input.requestID
            )
        }
    }

    private func exportVideo(
        _ editor: EditorViewModel,
        format: ExportFormat,
        resolution: ExportResolution,
        outputURL: URL,
        requestID: String?
    ) async throws -> ToolResult {
        let specID = "agent.\(format.displayName).\(resolution.id)"
        let spec = try PipelineDeliveryStore.defaultSpec(
            id: specID,
            targetKind: .derivative,
            timeline: editor.timeline,
            format: format,
            resolution: resolution,
            requireSequenceReview: false
        )
        let timeline = editor.timeline
        let job: ExportJob
        if let joined = try ExportQueue.shared.joinedDeliveryJob(
            editor: editor,
            specID: specID,
            format: format,
            resolution: resolution,
            outputURL: outputURL,
            requestID: requestID
        ) {
            job = joined
        } else {
            _ = try PipelineDeliveryStore.adoptCurrentTimeline(
                editor: editor,
                requireSequenceReview: false
            )
            job = try ExportQueue.shared.enqueueDelivery(
                editor: editor,
                spec: spec,
                format: format,
                resolution: resolution,
                outputURL: outputURL,
                requestID: requestID
            )
        }

        return try jsonResult([
            "status": "started",
            "jobID": job.id,
            "mode": ExportProjectMode.video.rawValue,
            "path": outputURL.path,
            "codec": format.displayName,
            "resolution": resolution.rawValue,
            "durationFrames": job.durationFrames ?? timeline.totalFrames,
            "durationSeconds": Double(job.durationFrames ?? timeline.totalFrames)
                / Double(max(1, job.fps ?? timeline.fps)),
            "fps": job.fps ?? timeline.fps,
            "note": "Rendering in the background. A system notification will report completion or failure.",
        ])
    }

    private func exportXML(
        _ editor: EditorViewModel,
        outputURL: URL,
        requestID: String?
    ) async throws -> ToolResult {
        let timeline = editor.timeline
        let job = try ExportQueue.shared.enqueueInterchange(
            editor: editor,
            format: .xml,
            outputURL: outputURL,
            projectName: editor.projectURL?.deletingPathExtension().lastPathComponent ?? "Timeline Export",
            requestID: requestID
        )
        try await requireCompleted(job)
        return try jsonResult([
            "status": "exported",
            "jobID": job.id,
            "mode": ExportProjectMode.xml.rawValue,
            "path": outputURL.path,
            "width": job.width ?? timeline.width,
            "height": job.height ?? timeline.height,
            "durationFrames": job.durationFrames ?? timeline.totalFrames,
            "durationSeconds": Double(job.durationFrames ?? timeline.totalFrames)
                / Double(max(1, job.fps ?? timeline.fps)),
            "fps": job.fps ?? timeline.fps,
            "outputSha256": job.outputSHA256 ?? "",
            "outputByteCount": job.outputByteCount ?? 0,
            "warnings": [],
        ])
    }

    private func exportFCPXML(
        _ editor: EditorViewModel,
        outputURL: URL,
        version: FCPXMLVersion,
        target: FCPXMLTarget,
        requestID: String?
    ) async throws -> ToolResult {
        let timeline = editor.timeline
        let job = try ExportQueue.shared.enqueueInterchange(
            editor: editor,
            format: .fcpxml,
            outputURL: outputURL,
            projectName: editor.projectURL?.deletingPathExtension().lastPathComponent ?? "Timeline Export",
            fcpxmlVersion: version,
            fcpxmlTarget: target,
            requestID: requestID
        )
        try await requireCompleted(job)
        guard let report = job.fcpxmlReport else {
            throw ToolError("export_project: FCPXML evidence is unavailable")
        }
        let warnings = report.warnings.map { warning -> [String: Any] in
            var value: [String: Any] = ["code": warning.code, "message": warning.message]
            if let clipID = warning.clipID { value["clipId"] = clipID }
            return value
        }
        let bindings = report.mediaBindings.map { binding -> [String: Any] in
            var value: [String: Any] = [
                "assetId": binding.assetID,
                "mediaRef": binding.mediaRef,
                "mediaRefs": binding.mediaRefs,
                "filename": binding.filename,
                "originalFilename": binding.originalFilename,
                "sourceUrl": binding.sourceURL,
                "mediaSha256": binding.mediaSHA256,
                "mediaByteCount": binding.mediaByteCount,
                "stagedProjectMedia": binding.stagedProjectMedia,
            ]
            if let origin = binding.sourceTimecodeOrigin { value["sourceTimecodeOrigin"] = origin.rawValue }
            if let frame = binding.sourceTimecodeFrame { value["sourceTimecodeFrame"] = frame }
            if let quanta = binding.sourceTimecodeQuanta { value["sourceTimecodeQuanta"] = quanta }
            if let dropFrame = binding.sourceTimecodeDropFrame { value["sourceTimecodeDropFrame"] = dropFrame }
            return value
        }
        let featureMatrix = FCPXMLFeatureMatrix.rows(for: report.version).map { row in
            [
                "feature": row.feature,
                "disposition": row.disposition.rawValue,
                "detail": row.detail,
            ]
        }
        return try jsonResult([
            "status": warnings.isEmpty ? "exported" : "exportedWithWarnings",
            "jobID": job.id,
            "mode": ExportProjectMode.fcpxml.rawValue,
            "path": outputURL.path,
            "version": report.version.rawValue,
            "target": report.target.rawValue,
            "width": job.width ?? timeline.width,
            "height": job.height ?? timeline.height,
            "durationFrames": job.durationFrames ?? timeline.totalFrames,
            "durationSeconds": Double(job.durationFrames ?? timeline.totalFrames)
                / Double(max(1, job.fps ?? timeline.fps)),
            "fps": job.fps ?? timeline.fps,
            "schemaProfile": report.validation.schemaProfile,
            "assetCount": report.validation.assetCount,
            "storyElementCount": report.validation.storyElementCount,
            "outputSha256": report.outputSHA256,
            "outputByteCount": report.outputByteCount,
            "mediaByteCount": report.mediaByteCount,
            "stagedProjectMediaCount": report.stagedProjectMediaCount,
            "mediaBindings": bindings,
            "featureMatrix": featureMatrix,
            "warnings": warnings,
        ])
    }

    private func exportProjectPackage(
        _ editor: EditorViewModel,
        outputURL: URL,
        requestID: String?
    ) async throws -> ToolResult {
        let job = try ExportQueue.shared.enqueueProjectPackage(
            editor: editor,
            outputURL: outputURL,
            requestID: requestID
        )
        try await requireCompleted(job)
        guard let report = job.projectReport else {
            throw ToolError("export_project: NexGenVideo project export evidence is unavailable")
        }

        let missing = report.missing.map { ["id": $0.id, "name": $0.name] }
        let warnings = missing.isEmpty
            ? []
            : ["Exported, but \(missing.count) media file\(missing.count == 1 ? "" : "s") were missing and could not be included."]

        return try jsonResult([
            "status": warnings.isEmpty ? "exported" : "exportedWithWarnings",
            "jobID": job.id,
            "mode": ExportProjectMode.nexgen.rawValue,
            "path": outputURL.path,
            "collectedMediaRefs": report.collected,
            "copiedInternalMediaCount": report.copiedInternal,
            "missingMedia": missing,
            "totalBytes": report.totalBytes,
            "warnings": warnings,
        ])
    }

    private func requireCompleted(_ job: ExportJob) async throws {
        let completed = await withTaskCancellationHandler {
            await ExportQueue.shared.waitForCompletion(jobID: job.id)
        } onCancel: {
            Task { @MainActor in ExportQueue.shared.cancel(jobID: job.id) }
        }
        guard let completed, completed.status == .completed else {
            throw ToolError("export_project: \(completed?.failure ?? "export did not complete")")
        }
    }

    private func exportDestination(
        outputPath: String?,
        mode: ExportProjectMode,
        format: ExportFormat?,
        editor: EditorViewModel,
        overwrite: Bool
    ) throws -> URL {
        guard let outputPath else {
            return try downloadsExportURL(mode: mode, format: format, editor: editor)
        }

        let url = try directExportURL(outputPath, mode: mode, format: format)
        if !overwrite, FileManager.default.fileExists(atPath: url.path) {
            throw ToolError("export_project: output file already exists")
        }
        return url
    }

    private func directExportURL(_ path: String, mode: ExportProjectMode, format: ExportFormat?) throws -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw ToolError("export_project: outputPath must be absolute")
        }

        let fm = FileManager.default
        let rawURL = URL(fileURLWithPath: expanded)
        let expectedExtension = mode.fileExtension(format: format)
        let rawExtension = rawURL.pathExtension.lowercased()
        var url = rawURL
        if rawExtension.isEmpty {
            url.appendPathExtension(expectedExtension)
        } else if rawExtension != expectedExtension {
            throw ToolError("export_project: \(mode.label(format: format)) exports must use .\(expectedExtension)")
        }

        var isDirectory = ObjCBool(false)
        if fm.fileExists(atPath: expanded, isDirectory: &isDirectory),
           isDirectory.boolValue,
           !(mode == .nexgen && rawExtension == expectedExtension) {
            throw ToolError("export_project: outputPath must include a filename")
        }

        let parent = url.deletingLastPathComponent()
        var parentIsDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw ToolError("export_project: output directory does not exist")
        }
        return url.standardizedFileURL
    }

    private func downloadsExportURL(
        mode: ExportProjectMode,
        format: ExportFormat?,
        editor: EditorViewModel
    ) throws -> URL {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw ToolError("export_project: Downloads folder not found")
        }
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        return uniqueExportURL(downloads.appendingPathComponent(mode.defaultFilename(format: format, editor: editor)))
    }

    private func uniqueExportURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let filename = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(filename)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func jsonResult(_ payload: [String: Any]) throws -> ToolResult {
        guard let json = Self.jsonString(payload) else {
            throw ToolError("export_project: failed to encode export report")
        }
        return .ok(json)
    }
}

private struct ExportProjectArgs: DecodableToolArgs {
    static let allowedKeys: Set<String> = [
        "mode", "codec", "resolution", "version", "target", "outputPath", "overwrite", "requestID",
    ]

    var mode: String?
    var codec: String?
    var resolution: String?
    var version: String?
    var target: String?
    var outputPath: String?
    var overwrite: Bool?
    var requestID: String?
}

private enum ExportProjectMode: String {
    case video
    case xml
    case fcpxml
    case nexgen

    init(named raw: String?) throws {
        guard let raw else {
            self = .video
            return
        }
        let normalized = raw.normalizedExportOption
        guard let mode = Self(rawValue: normalized) else {
            throw ToolError("export_project: mode must be video, xml, fcpxml, or nexgen")
        }
        self = mode
    }

    func fileExtension(format: ExportFormat?) -> String {
        switch self {
        case .video: format?.fileExtension ?? ExportFormat.h264.fileExtension
        case .xml: "xml"
        case .fcpxml: "fcpxml"
        case .nexgen: Project.fileExtension
        }
    }

    @MainActor
    func defaultFilename(format: ExportFormat?, editor: EditorViewModel) -> String {
        let base = editor.projectURL?.deletingPathExtension().lastPathComponent ?? Project.defaultProjectName
        return "\(base).\(fileExtension(format: format))"
    }

    func label(format: ExportFormat?) -> String {
        switch self {
        case .video: format?.displayName ?? "Video"
        case .xml: "XML"
        case .fcpxml: "FCPXML"
        case .nexgen: "NexGenVideo Project"
        }
    }
}

private extension ExportFormat {
    static func videoCodec(named raw: String?) throws -> ExportFormat {
        guard let raw else { return .h264 }
        switch raw.normalizedExportOption {
        case "h.264", "h264": return VideoCodec.h264.exportFormat
        case "h.265", "h265", "hevc": return VideoCodec.h265.exportFormat
        case "prores": return VideoCodec.prores.exportFormat
        default:
            throw ToolError("export_project: codec must be H.264, H.265, or ProRes")
        }
    }
}

private extension ExportResolution {
    static func exportPreset(named raw: String?) throws -> ExportResolution {
        guard let raw else { return .matchTimeline }
        switch raw.normalizedExportOption {
        case "720p": return .r720p
        case "1080p": return .r1080p
        case "2k": return .r1440p
        case "4k": return .r4k
        case "matchtimeline": return .matchTimeline
        default:
            throw ToolError("export_project: resolution must be 720p, 1080p, 2K, 4K, or Match Timeline")
        }
    }
}

private extension String {
    var normalizedExportOption: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}
