import AVFoundation
import NexGenEngine
import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var queue = ExportQueue.shared
    @State private var mode: ExportMode = .video
    @State private var codec: VideoCodec = .h264
    @State private var resolution: ExportResolution = .matchTimeline
    @State private var fcpxmlVersion: FCPXMLVersion = .default
    @State private var fcpxmlTarget: FCPXMLTarget = .default
    @State private var deliveryTarget = DeliveryTargetKindV1.master
    @State private var requireSequenceReview = false
    @State private var preparingDelivery = false
    @State private var preview: NSImage?
    @State private var selectedJobID: String?
    @State private var exportError: String?
    @State private var ngvResult: String?
    @State private var ngvSummary: (collect: Int, missing: Int, bytes: Int64) = (0, 0, 0)

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            HStack(spacing: AppTheme.Spacing.none) {
                settingsPanel
                    .frame(width: AppTheme.ComponentSize.exportSidebarWidth)
                previewPanel
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)

            bottomBar
        }
        .frame(width: AppTheme.ComponentSize.exportWindow.width, height: AppTheme.ComponentSize.exportWindow.height)
        .presentationBackground {
            AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.emphasis)
                .background(.ultraThinMaterial)
        }
        .task {
            loadPreview()
            ngvSummary = computeNGVSummary()
            let recovered = queue.loadPersistedDeliveryJobs(
                ownerKey: editor.openWorkingCopyKey,
                dataRoot: editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
            )
            if recovered { editor.onPipelineChanged?() }
        }
    }

    private func panelHeader(_ title: String) -> some View {
        Text(title)
            .interfaceFont(size: AppTheme.Typography.display, weight: AppTheme.FontWeight.light)
            .tracking(AppTheme.Tracking.tight)
            .foregroundStyle(AppTheme.Text.primaryColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.vertical, AppTheme.Spacing.md)
    }

    // MARK: - Preview (right)

    private var previewPanel: some View {
        ZStack {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "film")
                    .interfaceFont(size: AppTheme.Typography.display, weight: AppTheme.FontWeight.light)
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.baseColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .padding(AppTheme.Spacing.xl)
    }

    // MARK: - Settings (left)

    private var settingsPanel: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            panelHeader("Export")

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            // Settings rows
            VStack(spacing: AppTheme.Spacing.none) {
                settingRow(label: "Format") {
                    Picker("", selection: $mode) {
                        ForEach(ExportMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .labelsHidden()
                }

                AppDivider().opacity(AppTheme.Opacity.dim)

                switch mode {
                case .video:
                    settingRow(label: "Target") {
                        Picker("", selection: $deliveryTarget) {
                            Text("Master").tag(DeliveryTargetKindV1.master)
                            Text("Derivative").tag(DeliveryTargetKindV1.derivative)
                        }
                        .labelsHidden()
                    }

                    AppDivider().opacity(AppTheme.Opacity.dim)

                    settingRow(label: "Codec") {
                        Picker("", selection: $codec) {
                            ForEach(VideoCodec.allCases) { c in
                                Text(c.rawValue).tag(c)
                            }
                        }
                        .labelsHidden()
                    }

                    AppDivider().opacity(AppTheme.Opacity.dim)

                    settingRow(label: "Resolution") {
                        Picker("", selection: $resolution) {
                            ForEach(ExportResolution.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .labelsHidden()
                    }

                    AppDivider().opacity(AppTheme.Opacity.dim)

                    settingRow(label: "Frame Rate") {
                        Text("\(editor.timeline.fps) fps")
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }

                    AppDivider().opacity(AppTheme.Opacity.dim)

                    Toggle("Require current sequence review", isOn: $requireSequenceReview)
                        .interfaceFont(size: AppTheme.Typography.ui)

                    Text("Export adopts the current timeline as the exact finish source and records output hash, media bindings and probe QC.")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .padding(.top, AppTheme.Spacing.sm)

                case .xml:
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Exports XMEML for Adobe Premiere Pro and legacy interchange workflows.")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.secondaryColor)

                        Text("Use Final Cut Pro XML for Final Cut Pro or DaVinci Resolve.")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.tertiaryColor)

                        Text("Text overlays, flips, adjustments, effects, and keyframe easing aren't included.")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppTheme.Spacing.sm)

                case .fcpxml:
                    settingRow(label: "Version") {
                        Picker("", selection: $fcpxmlVersion) {
                            ForEach(FCPXMLVersion.allCases) { version in
                                Text(version.rawValue).tag(version)
                            }
                        }
                        .labelsHidden()
                    }

                    AppDivider().opacity(AppTheme.Opacity.dim)

                    settingRow(label: "Target") {
                        Picker("", selection: $fcpxmlTarget) {
                            ForEach(FCPXMLTarget.allCases) { target in
                                Text(target.displayName).tag(target)
                            }
                        }
                        .labelsHidden()
                    }

                    AppDivider().opacity(AppTheme.Opacity.dim)

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(fcpxmlVersion.compatibilityNote)
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.secondaryColor)

                        Text("Exports exact clip timing, source timecode, titles, transforms, crop, opacity, and static gain. Unsupported properties are listed after export.")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppTheme.Spacing.sm)

                case .ngvProject:
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Saves a copy of this project with all media bundled inside, so it opens on any machine.")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.secondaryColor)

                        if ngvSummary.missing > 0 {
                            Text("\(ngvSummary.missing) media file\(ngvSummary.missing == 1 ? "" : "s") missing — they'll be skipped.")
                                .interfaceFont(size: AppTheme.Typography.ui)
                                .foregroundStyle(AppTheme.Status.errorColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppTheme.Spacing.sm)
                }
            }

            if !projectJobs.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text("Queue")
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    ForEach(projectJobs) { job in
                        exportJobRow(job)
                    }
                }
                .padding(.top, AppTheme.Spacing.md)
            }

            if let job = activeJob {
                VStack(spacing: AppTheme.Spacing.xs) {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                    Text("\(job.detail) · \(Int(job.progress * 100))%")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                .padding(.top, AppTheme.Spacing.md)
            }

            if let error = exportError ?? selectedJob?.failure {
                Text(error)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .padding(.top, AppTheme.Spacing.sm)
            }

            if let ngvResult {
                Text(ngvResult)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .padding(.top, AppTheme.Spacing.sm)
            }

            if selectedJob?.fcpxmlReport == nil {
                ForEach(Array((selectedJob?.warnings ?? []).enumerated()), id: \.offset) { _, warning in
                    Text(warning)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Status.warningColor)
                        .padding(.top, AppTheme.Spacing.sm)
                }
            }

            if let report = selectedJob?.fcpxmlReport {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Validated Apple DTD · FCPXML \(report.version.rawValue) · \(ByteCountFormatter.string(fromByteCount: report.outputByteCount, countStyle: .file))")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Text("SHA-256 \(report.outputSHA256)")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .textSelection(.enabled)
                    Text(report.validation.schemaProfile)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .textSelection(.enabled)
                    Text("Media proof · \(report.mediaBindings.count) asset\(report.mediaBindings.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: report.mediaByteCount, countStyle: .file))")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning.message)
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Status.warningColor)
                    }
                }
                .padding(.top, AppTheme.Spacing.sm)
            }

                Spacer()
                }
                .padding(AppTheme.Spacing.xl)
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            let duration = formatTimecode(frame: editor.timeline.totalFrames, fps: editor.timeline.fps)
            HStack(spacing: AppTheme.Spacing.lg) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "clock")
                    Text(duration)
                }
                switch mode {
                case .video:
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "doc")
                        Text("~\(estimatedFileSize)")
                    }
                    let out = resolution.renderSize(for: CGSize(width: editor.timeline.width, height: editor.timeline.height))
                    Text("\(Int(out.width))×\(Int(out.height))")
                case .xml, .fcpxml:
                    Text("\(editor.timeline.width)×\(editor.timeline.height)")
                case .ngvProject:
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "shippingbox")
                        Text("~\(ByteCountFormatter.string(fromByteCount: ngvSummary.bytes, countStyle: .file))")
                    }
                }
            }
            .interfaceFont(size: AppTheme.Typography.ui)
            .foregroundStyle(AppTheme.Text.mutedColor)

            Spacer()

            Button(activeJob?.status == .cancelling ? "Cancelling" : (activeJob != nil ? "Cancel Export" : "Cancel")) {
                if let activeJob {
                    queue.cancel(jobID: activeJob.id)
                } else {
                    editor.showExportDialog = false
                }
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .disabled(activeJob?.status == .cancelling)
            .keyboardShortcut(.cancelAction)
            Button("Export") { startExport() }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .disabled(preparingDelivery)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.lg)
    }

    private var projectJobs: [ExportJob] {
        let jobs = queue.jobs(ownerKey: editor.openWorkingCopyKey)
        guard let activeJob = queue.activeJob(ownerKey: editor.openWorkingCopyKey),
              !jobs.prefix(4).contains(where: { $0.id == activeJob.id }) else {
            return Array(jobs.prefix(4))
        }
        return [activeJob] + Array(jobs.filter { $0.id != activeJob.id }.prefix(3))
    }

    private var selectedJob: ExportJob? {
        if let selectedJobID,
           let selected = projectJobs.first(where: { $0.id == selectedJobID }) {
            return selected
        }
        return projectJobs.first
    }

    private var activeJob: ExportJob? {
        queue.activeJob(ownerKey: editor.openWorkingCopyKey)
    }

    private func exportJobRow(_ job: ExportJob) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: statusSymbol(job.status))
                    .foregroundStyle(statusColor(job.status))
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(job.title)
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                    Text("\(job.detail) · \(job.id.prefix(8))")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer()
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Cancel") { queue.cancel(jobID: job.id) }
                    .disabled(!job.canCancel)
                Button("Retry") {
                    do {
                        let retry = try queue.retry(jobID: job.id)
                        selectedJobID = retry.id
                        exportError = nil
                    } catch {
                        exportError = error.localizedDescription
                    }
                }
                .disabled(!queue.canRetry(jobID: job.id))
                Button("Reveal") {
                    if let url = job.destinationURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .disabled(!job.canReveal)
                Spacer()
            }
            .buttonStyle(.capsule(.secondary, size: .small))
        }
        .padding(AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(
                    selectedJob?.id == job.id
                        ? AppTheme.Background.prominentColor
                        : AppTheme.Background.raisedColor
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedJobID = job.id }
    }

    private func statusSymbol(_ status: ExportJobStatus) -> String {
        switch status {
        case .pending: "clock"
        case .preparing: "gearshape"
        case .exporting: "arrow.up.circle"
        case .cancelling: "xmark.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        case .interrupted: "pause.circle.fill"
        }
    }

    private func statusColor(_ status: ExportJobStatus) -> Color {
        switch status {
        case .completed: AppTheme.Status.successColor
        case .failed: AppTheme.Status.errorColor
        case .cancelled, .interrupted: AppTheme.Status.warningColor
        case .pending, .preparing, .exporting, .cancelling: AppTheme.Text.secondaryColor
        }
    }

    // MARK: - Helpers

    private func settingRow<Control: View>(label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            control()
        }
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private var estimatedFileSize: String {
        let seconds = Double(editor.timeline.totalFrames) / Double(max(1, editor.timeline.fps))
        // Bitrate scales with output pixel area, so any resolution is covered.
        let out = resolution.renderSize(for: CGSize(width: editor.timeline.width, height: editor.timeline.height))
        let megapixels = Double(out.width * out.height) / 1_000_000
        let bytesPerSecPerMP: Double = switch codec {
        case .h264:   0.63e6
        case .h265:   0.32e6
        case .prores: 9.0e6
        }
        let bytesPerSec = bytesPerSecPerMP * max(0.1, megapixels)
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSec * seconds), countStyle: .file)
    }

    private var exportFormat: ExportFormat {
        switch mode {
        case .xml, .ngvProject: .xml   // ngvProject has its own path; never rendered
        case .fcpxml: .fcpxml
        case .video: codec.exportFormat
        }
    }

    /// Quick estimate for exporting a NexGenVideo Project
    private func computeNGVSummary() -> (collect: Int, missing: Int, bytes: Int64) {
        var collect = 0, missing = 0
        var bytes: Int64 = 0
        for entry in editor.mediaManifest.entries {
            let url: URL? = switch entry.source {
            case .external(let path): URL(fileURLWithPath: path)
            case .project(let rel): editor.workingRoot?.appendingPathComponent(rel)
            }
            guard let url, FileManager.default.fileExists(atPath: url.path) else { missing += 1; continue }
            if case .external = entry.source { collect += 1 }
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (collect, missing, bytes)
    }

    private func loadPreview() {
        for track in editor.timeline.tracks where track.type == .video {
            for clip in track.clips {
                guard let url = editor.mediaResolver.resolveURL(for: clip.mediaRef) else { continue }
                let asset = AVURLAsset(url: url)
                guard !asset.tracks(withMediaType: .video).isEmpty else { continue }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.maximumSize = CGSize(width: 480, height: 270)
                generator.appliesPreferredTrackTransform = true
                let time = CMTime(value: CMTimeValue(clip.trimStartFrame), timescale: CMTimeScale(editor.timeline.fps))
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                    if let image {
                        Task { @MainActor in
                            preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                        }
                    }
                }
                return
            }
        }
    }

    private func startExport() {
        if mode == .ngvProject { startNGVExport(); return }
        let format = exportFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            format == .xml
                ? .xml
                : (format == .fcpxml
                    ? (UTType(filenameExtension: "fcpxml") ?? .xml)
                    : (format == .prores ? .movie : .mpeg4Movie))
        ]
        panel.nameFieldStringValue = "export.\(format.fileExtension)"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                preparingDelivery = true
                exportError = nil
                ngvResult = nil
                defer { preparingDelivery = false }
                do {
                    if mode == .xml || mode == .fcpxml {
                        let job = try queue.enqueueInterchange(
                            editor: editor,
                            format: format,
                            outputURL: url,
                            projectName: editor.projectURL?.deletingPathExtension().lastPathComponent ?? "Timeline Export",
                            fcpxmlVersion: fcpxmlVersion,
                            fcpxmlTarget: fcpxmlTarget
                        )
                        selectedJobID = job.id
                        ngvResult = "Queued · \(job.id.prefix(8))"
                        return
                    }
                    _ = try PipelineDeliveryStore.adoptCurrentTimeline(
                        editor: editor,
                        requireSequenceReview: requireSequenceReview
                    )
                    let target = deliveryTarget == .master ? "master" : "derivative"
                    let spec = try PipelineDeliveryStore.defaultSpec(
                        id: "\(target).\(codec.id).\(resolution.id)",
                        targetKind: deliveryTarget,
                        timeline: editor.timeline,
                        format: format,
                        resolution: resolution,
                        requireSequenceReview: requireSequenceReview
                    )
                    let job = try queue.enqueueDelivery(
                        editor: editor,
                        spec: spec,
                        format: format,
                        resolution: resolution,
                        outputURL: url
                    )
                    selectedJobID = job.id
                    ngvResult = "Queued · \(job.id.prefix(8))"
                } catch {
                    exportError = error.localizedDescription
                }
            }
        }
    }

    private func startNGVExport() {
        ngvResult = nil
        exportError = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(Project.typeIdentifier) ?? .package]
        let base = editor.projectURL?.deletingPathExtension().lastPathComponent ?? Project.defaultProjectName
        panel.nameFieldStringValue = "\(base).\(Project.fileExtension)"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                preparingDelivery = true
                defer { preparingDelivery = false }
                do {
                    let job = try queue.enqueueProjectPackage(
                        editor: editor,
                        outputURL: url
                    )
                    selectedJobID = job.id
                    ngvResult = "Queued · \(job.id.prefix(8))"
                } catch {
                    exportError = error.localizedDescription
                }
            }
        }
    }
}
