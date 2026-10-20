import AVFoundation
import NexGenEngine
import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    enum Presentation { case sheet, workspaceSettings }
    var presentation: Presentation = .sheet
    @Environment(EditorViewModel.self) var editor
    @State private var queue = ExportQueue.shared
    @State private var mode: ExportMode = .video
    @State private var codec: VideoCodec = .h264
    @State private var resolution: ExportResolution = .matchTimeline
    @State private var fcpxmlVersion: FCPXMLVersion = .default
    @State private var fcpxmlTarget: FCPXMLTarget = .default
    @State private var deliveryTarget = DeliveryTargetKindV1.master
    @State private var requireSequenceReview = false
    @State private var preparation = ExportPreparation(cancelJob: { ExportQueue.shared.cancel(jobID: $0) })
    private var preparingDelivery: Bool { preparation.isPreparing }
    @State private var destinationPanel: NSSavePanel?
    private var choosingDestination: Bool { destinationPanel != nil }
    @State private var preview: NSImage?
    @State private var selectedJobID: String?
    @State private var exportError: String?
    @State private var ngvResult: String?
    @State private var ngvSummary: (collect: Int, missing: Int, bytes: Int64) = (0, 0, 0)
    @State private var hdrCapability: HDRExportCapability?
    @State private var artworkSelection: ExportArtworkSelection?
    @State private var choosingArtwork = false

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            HStack(spacing: AppTheme.Spacing.none) {
                settingsPanel
                    .frame(width: presentation == .sheet ? AppTheme.ComponentSize.exportSidebarWidth : nil)
                if presentation == .sheet {
                    previewPanel.frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            if presentation == .sheet { bottomBar }
            else { workspaceActions }
        }
        .frame(width: presentation == .sheet ? AppTheme.ComponentSize.exportWindow.width : nil,
               height: presentation == .sheet ? AppTheme.ComponentSize.exportWindow.height : nil)
        .presentationBackground(AppTheme.Background.surfaceColor)
        .task(id: editor.openWorkingCopyKey) {
            preview = nil
            if presentation == .sheet { await loadPreview() }
            guard !Task.isCancelled else { return }
            ngvSummary = computeNGVSummary()
            if presentation == .sheet {
                let recovered = queue.loadPersistedDeliveryJobs(ownerKey: editor.openWorkingCopyKey,
                    dataRoot: editor.workingRoot.flatMap { try? ExportDataRoot.resolve(in: $0) })
                if recovered { editor.onPipelineChanged?() }
            }
        }
        .task(id: hdrCapabilityKey) {
            guard codec == .hdr else {
                hdrCapability = nil
                return
            }
            let capability = await HDRVideoExporter.capability(
                renderSize: selectedRenderSize,
                fps: editor.timeline.fps
            )
            guard !Task.isCancelled else { return }
            hdrCapability = capability
        }
        .onChange(of: editor.openWorkingCopyKey) {
            cancelDestinationSelection()
            preparation.cancel()
            preparation = ExportPreparation(cancelJob: { queue.cancel(jobID: $0) })
            artworkSelection = nil
            selectedJobID = nil
            exportError = nil
            ngvResult = nil
        }
        .onChange(of: editor.timelineRenderRevision) {
            if let artworkSelection, artworkSelection.timelineSHA256 != (try? ExportArtwork.timelineHash(editor.timeline)) {
                self.artworkSelection = nil
                exportError = "The film changed. Choose its poster image again before exporting with artwork."
            }
        }
        .onDisappear { cancelDestinationSelection(); preparation.cancel() }
    }

    private func panelHeader(_ title: String) -> some View {
        Text(title)
            .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
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
        .overlay(alignment: .bottomTrailing) {
            if codec == .hdr {
                Text("Timeline preview · Rec. 709 SDR")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .background(AppTheme.Background.raisedColor.opacity(AppTheme.Opacity.strong))
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                    .padding(AppTheme.Spacing.xxl)
            }
        }
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
                        .reviewAcceptanceProbe("export.mode", text: mode.rawValue)
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
                        .reviewAcceptanceProbe("export.target", text: deliveryTarget.rawValue)
                    }

                    AppDivider().opacity(AppTheme.Opacity.dim)

                    settingRow(label: "Codec") {
                        Picker("", selection: $codec) {
                            ForEach(VideoCodec.allCases) { c in
                                Text(c.rawValue).tag(c)
                            }
                        }
                        .labelsHidden()
                        .reviewAcceptanceProbe("export.codec", text: codec.rawValue)
                    }

                    AppDivider().opacity(AppTheme.Opacity.dim)

                    settingRow(label: "Resolution") {
                        Picker("", selection: $resolution) {
                            ForEach(ExportResolution.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .labelsHidden()
                        .reviewAcceptanceProbe("export.resolution", text: resolution.rawValue)
                    }

                    AppDivider().opacity(AppTheme.Opacity.dim)

                    settingRow(label: "Frame Rate") {
                        Text("\(editor.timeline.fps) fps")
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }

                    AppDivider().opacity(AppTheme.Opacity.dim)

                    if codec == .hdr {
                        settingRow(label: "Color") {
                            Text("BT.2020 · HLG · 10-bit")
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }

                        Text("Maps the Rec. 709 SDR timeline white to 75% HLG reference white. No HDR highlight detail is synthesized.")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .padding(.bottom, AppTheme.Spacing.sm)

                        if let hdrCapability, !hdrCapability.isSupported {
                            Text(hdrCapability.reason ?? "HDR export is unavailable.")
                                .interfaceFont(size: AppTheme.Typography.ui)
                                .foregroundStyle(AppTheme.Status.errorColor)
                                .padding(.bottom, AppTheme.Spacing.sm)
                        }

                        AppDivider().opacity(AppTheme.Opacity.dim)
                    }

                    if editor.usesProductionPlanningV2 {
                        Text("A current film review is required before export.")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .reviewAcceptanceProbe("export.require-sequence", state: true)
                    } else {
                    Toggle("Require current sequence review", isOn: $requireSequenceReview)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .accessibilityIdentifier("export.require-sequence")
                        .background {
                            if WorkspaceUIAcceptance.isRequested || MusicvideoHostFlowAcceptance.isRequested {
                                AppRelaunchClickProbe(identifier: "export.require-sequence", acceptanceState: requireSequenceReview)
                            }
                        }
                    }

                    Text("Exports the current timeline and checks the saved video's format, duration, and media files.")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .padding(.top, AppTheme.Spacing.sm)

                    artworkPicker.padding(.top, AppTheme.Spacing.md)

                case .xml:
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Exports XMEML for Adobe Premiere Pro and legacy interchange workflows.")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.secondaryColor)

                        Text("Use Final Cut Pro XML for Final Cut Pro or DaVinci Resolve.")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.tertiaryColor)

                        ForEach(Array(XMLExporter.limitationSummary(timeline: editor.timeline).enumerated()), id: \.offset) { index, warning in
                            Text(warning)
                                .reviewAcceptanceProbe("export.xml.warning.\(index)", text: warning)
                                .interfaceFont(size: AppTheme.Typography.ui)
                                .foregroundStyle(AppTheme.Status.warningColor)
                        }
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
                        .reviewAcceptanceProbe("export.fcpxml.version", text: fcpxmlVersion.rawValue)
                    }

                    AppDivider().opacity(AppTheme.Opacity.dim)

                    settingRow(label: "Target") {
                        Picker("", selection: $fcpxmlTarget) {
                            ForEach(FCPXMLTarget.allCases) { target in
                                Text(target.displayName).tag(target)
                            }
                        }
                        .labelsHidden()
                        .reviewAcceptanceProbe("export.fcpxml.target", text: fcpxmlTarget.rawValue)
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
                                .reviewAcceptanceProbe("export.project.missing", text: String(ngvSummary.missing))
                                .interfaceFont(size: AppTheme.Typography.ui)
                                .foregroundStyle(AppTheme.Status.errorColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppTheme.Spacing.sm)
                }
            }

            if presentation == .sheet && !projectJobs.isEmpty {
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
                        .reviewAcceptanceProbe("export.progress", text: "\(job.id):\(job.progress)")
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
                    .background {
                        if WorkspaceUIAcceptance.isRequested || MusicvideoHostFlowAcceptance.isRequested {
                            AppRelaunchClickProbe(identifier: "export.error", acceptanceText: error)
                        }
                    }
            }

            if let ngvResult {
                Text(ngvResult)
                    .reviewAcceptanceProbe("export.result", text: ngvResult)
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
                        .reviewAcceptanceProbe("export.fcpxml.report", text: report.version.rawValue + ":" + report.outputSHA256)
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

    private var artworkPicker: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Poster image (optional)").fontWeight(AppTheme.FontWeight.semibold)
            Text(artworkSelection?.displayName ?? "No poster image")
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .reviewAcceptanceProbe("export.artwork.selection", text: artworkSelection?.displayName ?? "none")
            WrapLayout(spacing: AppTheme.Spacing.sm) {
                Button("Use film frame") {
                    do { artworkSelection = try ExportArtwork.filmFrame(editor: editor); exportError = nil }
                    catch { exportError = error.localizedDescription }
                }
                .disabled(editor.activePreviewTab != .timeline || editor.timeline.totalFrames <= 0)
                .reviewAcceptanceProbe("export.artwork.frame")
                LibraryAssetPickerButton(purpose: .workspace(.export), acceptedTypes: [.image], title: "Choose image") { asset in
                    choosingArtwork = true
                    Task {
                        defer { choosingArtwork = false }
                        do {
                            artworkSelection = try await ExportArtwork.projectImage(asset: asset, editor: editor)
                            editor.selectMediaAsset(asset)
                            exportError = nil
                        }
                        catch { exportError = error.localizedDescription }
                    }
                }
                if artworkSelection != nil {
                    Button("Remove image") { artworkSelection = nil }
                        .reviewAcceptanceProbe("export.artwork.remove")
                }
                if editor.activePreviewTab != .timeline {
                    Button("Show film") { editor.selectPreviewTab(id: PreviewTab.timeline.id) }
                        .reviewAcceptanceProbe("export.artwork.show-film")
                }
            }
            .buttonStyle(.capsule(.secondary, size: .small))
            .disabled(choosingArtwork || preparingDelivery)
            if choosingArtwork { ProgressView("Checking image…") }
            if artworkSelection != nil {
                Text("A PNG poster is saved beside the video. Both files must succeed.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
    }

    private var workspaceActions: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            AppDivider()
            preparationStatus
            Text("\(formatTimecode(frame: editor.timeline.totalFrames, fps: editor.timeline.fps)) · \(editor.timeline.fps) fps")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
            WrapLayout(spacing: AppTheme.Spacing.sm) {
                if choosingDestination {
                    Button("Cancel") { cancelDestinationSelection() }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                } else if preparingDelivery {
                    Button(preparation.isCancelling ? "Cancelling…" : "Cancel Export") { preparation.cancel() }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .disabled(preparation.isCancelling)
                        .reviewAcceptanceProbe("export.cancel-preparation", state: !preparation.isCancelling)
                } else if let activeJob {
                    Button(activeJob.status == .cancelling ? "Cancelling" : "Cancel Export") { queue.cancel(jobID: activeJob.id) }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .disabled(!activeJob.canCancel)
                        .reviewAcceptanceProbe("export.cancel", text: activeJob.id)
                }
                Button("Export…") { startExport() }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(choosingDestination || preparingDelivery || choosingArtwork || (mode == .video && codec == .hdr && hdrCapability?.isSupported != true))
                    .reviewAcceptanceProbe("export.start")
            }
        }
        .padding(AppTheme.Spacing.md)
    }

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

            preparationStatus
            Button(choosingDestination ? "Cancel" : (preparation.isCancelling ? "Cancelling…" : (activeJob?.status == .cancelling ? "Cancelling" : (activeJob != nil || preparingDelivery ? "Cancel Export" : "Cancel")))) {
                if choosingDestination {
                    cancelDestinationSelection()
                } else if preparingDelivery {
                    preparation.cancel()
                } else if let activeJob {
                    queue.cancel(jobID: activeJob.id)
                } else {
                    editor.showExportDialog = false
                }
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .disabled(preparation.isCancelling || (!choosingDestination && !preparingDelivery && activeJob != nil && activeJob?.canCancel != true))
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("export.cancel")
            .background {
                if WorkspaceUIAcceptance.isRequested || MusicvideoHostFlowAcceptance.isRequested {
                        AppRelaunchClickProbe(identifier: "export.cancel", acceptanceState: !preparation.isCancelling && (choosingDestination || preparingDelivery || activeJob == nil || activeJob?.canCancel == true))
                }
            }
            Button("Export") { startExport() }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .disabled(choosingDestination || preparingDelivery || choosingArtwork || (mode == .video && codec == .hdr && hdrCapability?.isSupported != true))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("export.start")
                .background {
                    if WorkspaceUIAcceptance.isRequested || MusicvideoHostFlowAcceptance.isRequested {
                        AppRelaunchClickProbe(identifier: "export.start", acceptanceState: !choosingDestination && !preparingDelivery && !choosingArtwork && (mode != .video || codec != .hdr || hdrCapability?.isSupported == true))
                    }
                }
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.lg)
    }

    @ViewBuilder private var preparationStatus: some View {
        if choosingDestination {
            Text("Choose an export destination in the Save dialog.")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .reviewAcceptanceProbe("export.choosing-destination", text: "choosing")
        } else if preparingDelivery {
            let label = preparation.isCancelling ? "Cancelling export…" : "Preparing export…"
            ProgressView(label)
                .controlSize(.small)
                .interfaceFont(size: AppTheme.Typography.ui)
                .reviewAcceptanceProbe("export.preparing", text: label)
        }
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
                    .accessibilityIdentifier("export.job.\(job.id).cancel")
                    .background { exportActionProbe(job: job, action: "cancel") }
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
                .accessibilityIdentifier("export.job.\(job.id).retry")
                .background { exportActionProbe(job: job, action: "retry") }
                Button("Reveal") {
                    if let url = job.destinationURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        ExportActionsSelfTest.recordReveal(url)
                    }
                }
                .disabled(!job.canReveal)
                .accessibilityIdentifier("export.job.\(job.id).reveal")
                .background { exportActionProbe(job: job, action: "reveal") }
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

    @ViewBuilder
    private func exportActionProbe(job: ExportJob, action: String) -> some View {
        if ExportActionsSelfTest.isRequested {
            AppRelaunchClickProbe(identifier: "export.job.\(job.id).\(action)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
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
        ViewThatFits(in: .horizontal) {
            HStack {
                settingLabel(label)
                Spacer(minLength: AppTheme.Spacing.sm)
                control().fixedSize()
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                settingLabel(label)
                control()
            }
        }
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private func settingLabel(_ label: String) -> some View {
        Text(label)
            .interfaceFont(size: AppTheme.Typography.ui)
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .fixedSize(horizontal: false, vertical: true)
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
        case .hdr:    0.45e6
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

    private var selectedRenderSize: CGSize {
        resolution.renderSize(for: CGSize(
            width: editor.timeline.width,
            height: editor.timeline.height
        ))
    }

    private var hdrCapabilityKey: String {
        "\(editor.openWorkingCopyKey ?? "")-\(codec.id)-\(resolution.id)-\(Int(selectedRenderSize.width))x\(Int(selectedRenderSize.height))-\(editor.timeline.fps)"
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

    private func loadPreview() async {
        let ownerKey = editor.openWorkingCopyKey
        let revision = editor.timelineRenderRevision
        let timeline = editor.timeline
        let frame = min(max(0, editor.currentFrame), timeline.totalFrames - 1)
        guard timeline.totalFrames > 0 else { return }
        let resolver = editor.mediaResolver.snapshot()
        let canvas = CGSize(width: timeline.width, height: timeline.height)
        guard let result = try? await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { resolver.resolveURL(for: $0) },
            renderSize: canvas
        ), (try? await result.composition.loadTracks(withMediaType: .video).first) != nil else {
            return
        }
        let generator = AVAssetImageGenerator(asset: result.composition)
        generator.videoComposition = result.videoComposition
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(
            value: CMTimeValue(frame),
            timescale: CMTimeScale(max(1, timeline.fps))
        )
        guard let video = try? await generator.image(at: time).image,
              !Task.isCancelled, ownerKey == editor.openWorkingCopyKey,
              revision == editor.timelineRenderRevision else { return }
        preview = NSImage(
            cgImage: video,
            size: NSSize(width: video.width, height: video.height)
        )
    }

    private func chooseDestination(_ panel: NSSavePanel, onChoose: @escaping (URL) -> Void) {
        guard destinationPanel == nil, !preparingDelivery else { return }
        destinationPanel = panel
        panel.begin { response in
            guard destinationPanel === panel else { return }
            defer { if destinationPanel === panel { destinationPanel = nil } }
            guard response == .OK, let url = panel.url else { return }
            onChoose(url)
        }
    }

    private func cancelDestinationSelection() {
        let panel = destinationPanel
        destinationPanel = nil
        panel?.cancel(nil)
    }

    private func startExport() {
        guard !choosingDestination, !preparingDelivery else { return }
        let mode = self.mode
        if mode == .ngvProject { startNGVExport(); return }
        let codec = self.codec
        let resolution = self.resolution
        let deliveryTarget = self.deliveryTarget
        let requireSequenceReview = editor.usesProductionPlanningV2 || self.requireSequenceReview
        let fcpxmlVersion = self.fcpxmlVersion
        let fcpxmlTarget = self.fcpxmlTarget
        let artworkSelection = mode == .video ? self.artworkSelection : nil
        let ownerKey = editor.openWorkingCopyKey
        let format = exportFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            format == .xml
                ? .xml
                : (format == .fcpxml
                    ? (UTType(filenameExtension: "fcpxml") ?? .xml)
                    : (format == .prores || format.isHDR ? .movie : .mpeg4Movie))

        ]
        panel.nameFieldStringValue = "export.\(format.fileExtension)"

        chooseDestination(panel) { url in
            guard ownerKey != nil, editor.openWorkingCopyKey == ownerKey else {
                exportError = "The project changed while choosing the export destination."
                return
            }
            var preserveExistingPoster = false
            if artworkSelection != nil, FileManager.default.fileExists(atPath: ExportArtwork.outputURL(for: url).path) {
                let alert = NSAlert()
                alert.messageText = String(localized: "Replace the existing poster image?")
                alert.informativeText = ExportArtwork.outputURL(for: url).lastPathComponent
                alert.addButton(withTitle: String(localized: "Replace"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            } else if mode == .video, FileManager.default.fileExists(atPath: ExportArtwork.outputURL(for: url).path) {
                let alert = NSAlert()
                alert.messageText = String(localized: "Keep the existing poster unchanged?")
                alert.informativeText = String(localized: "This export has no poster selected. The existing image will remain beside the new video and may belong to an earlier film.")
                alert.addButton(withTitle: String(localized: "Export Video Only"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                preserveExistingPoster = true
            }
            let keepUnboundPoster = preserveExistingPoster
            preparation.start { requestID in
                exportError = nil
                ngvResult = nil
                try Task.checkCancellation()
                guard ownerKey != nil, editor.openWorkingCopyKey == ownerKey else {
                    throw ToolError("The project changed while choosing the export destination.")
                }
                if mode == .xml || mode == .fcpxml {
                    let job = try await queue.enqueueInterchange(
                        editor: editor,
                        format: format,
                        outputURL: url,
                        projectName: editor.projectURL?.deletingPathExtension().lastPathComponent ?? "Timeline Export",
                        fcpxmlVersion: fcpxmlVersion,
                        fcpxmlTarget: fcpxmlTarget,
                        requestID: requestID
                    )
                    try Task.checkCancellation()
                    selectedJobID = job.id
                    ngvResult = "Queued · \(job.id.prefix(8))"
                    return
                }
                _ = try await PipelineDeliveryStore.adoptCurrentTimeline(
                    editor: editor,
                    requireSequenceReview: requireSequenceReview
                )
                try Task.checkCancellation()
                let target = deliveryTarget == .master ? "master" : "derivative"
                let artworkRefs: [String]
                if let artworkSelection { artworkRefs = try await ExportArtwork.prepare(artworkSelection, editor: editor) }
                else { artworkRefs = [] }
                try Task.checkCancellation()
                let spec = try PipelineDeliveryStore.defaultSpec(
                    id: "\(target).\(codec.id).\(resolution.id)",
                    targetKind: deliveryTarget,
                    timeline: editor.timeline,
                    format: format,
                    resolution: resolution,
                    requireSequenceReview: requireSequenceReview,
                    extensionRefs: artworkRefs
                )
                let job = try await queue.enqueueDelivery(
                    editor: editor,
                    spec: spec,
                    format: format,
                    resolution: resolution,
                    outputURL: url,
                    requestID: requestID,
                    preserveExistingPoster: keepUnboundPoster
                )
                try Task.checkCancellation()
                selectedJobID = job.id
                ngvResult = "Queued · \(job.id.prefix(8))"
            } failure: { error in
                guard editor.openWorkingCopyKey == ownerKey else { return }
                if error is CancellationError { ngvResult = "Export cancelled." }
                else { exportError = error.localizedDescription }
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
        let ownerKey = editor.openWorkingCopyKey
        let sourceRoot = editor.workingRoot
        let document = NSDocumentController.shared.documents.compactMap { $0 as? VideoProject }
            .first { $0.editorViewModel === editor }
        let sourceWindow = document?.windowControllers.compactMap(\.window).first { $0.isVisible }

        chooseDestination(panel) { url in
            guard let ownerKey, editor.openWorkingCopyKey == ownerKey, editor.workingRoot == sourceRoot,
                  let document, NSDocumentController.shared.documents.contains(where: { $0 === document }),
                  let sourceWindow, sourceWindow.isVisible,
                  document.windowControllers.contains(where: { $0.window === sourceWindow }) else {
                exportError = "The project changed while choosing the export destination."
                return
            }
            preparation.start { requestID in
                try Task.checkCancellation()
                guard editor.openWorkingCopyKey == ownerKey, editor.workingRoot == sourceRoot,
                      NSDocumentController.shared.documents.contains(where: { $0 === document }), sourceWindow.isVisible,
                      document.windowControllers.contains(where: { $0.window === sourceWindow }) else {
                    throw ToolError("The project changed while choosing the export destination.")
                }
                let job = try await queue.enqueueProjectPackage(
                    editor: editor,
                    outputURL: url,
                    requestID: requestID
                )
                try Task.checkCancellation()
                selectedJobID = job.id
                ngvResult = "Queued · \(job.id.prefix(8))"
            } failure: { error in
                guard editor.openWorkingCopyKey == ownerKey else { return }
                if error is CancellationError { ngvResult = "Export cancelled." }
                else { exportError = error.localizedDescription }
            }
        }
    }
}
