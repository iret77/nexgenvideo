import AppKit
import NexGenEngine
import SwiftUI

struct ExportWorkspaceView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var queue = ExportQueue.shared
    @State private var selectedID: String?
    @State private var attempt: DeliveryAttemptV1?
    @State private var artwork: ExportArtworkSnapshot?
    @State private var posterImage: NSImage?
    @State private var currentTimelineSHA256: String?
    @State private var evidenceError: String?
    @State private var actionError: String?
    @State private var loadingEvidence = false
    @State private var verificationRevision = 0

    private var jobs: [ExportJob] { queue.jobs(ownerKey: editor.openWorkingCopyKey) }
    private var selected: ExportJob? { jobs.first { $0.id == selectedID } ?? jobs.first }
    private var evidenceKey: String {
        "\(editor.openWorkingCopyKey ?? "closed")/\(selected?.id ?? "none")/\(selected?.status.rawValue ?? "none")/\(verificationRevision)"
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            HStack {
                Text("Exports").interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                Spacer(minLength: AppTheme.Spacing.sm)
                Text("\(jobs.count)").foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .panelHeaderBar()
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    filmSummary
                    ExportCoverUtilityView()
                    if jobs.isEmpty {
                        Text("Choose output settings, then export the current film.")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    } else {
                        ForEach(jobs) { job in
                            jobRow(job)
                            if selected?.id == job.id { jobEvidence(job) }
                        }
                    }
                    if let actionError { Text(actionError).foregroundStyle(AppTheme.Status.errorColor) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppTheme.Spacing.md)
            }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .background(AppTheme.Background.surfaceColor)
        .task(id: editor.openWorkingCopyKey) {
            if queue.loadPersistedDeliveryJobs(ownerKey: editor.openWorkingCopyKey,
                dataRoot: editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }) {
                editor.onPipelineChanged?()
            }
        }
        .task(id: editor.timelineRenderRevision) {
            currentTimelineSHA256 = try? ExportArtwork.timelineHash(editor.timeline)
        }
        .task(id: evidenceKey) { await loadEvidence() }
    }

    private var filmSummary: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Current film").fontWeight(AppTheme.FontWeight.semibold)
            Text("\(editor.timeline.width) × \(editor.timeline.height) · \(editor.timeline.fps) fps · \(formatTimecode(frame: editor.timeline.totalFrames, fps: editor.timeline.fps))")
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if let attempt {
                Text(attempt.finishedTimelineSHA256 == currentTimelineSHA256 ? "Selected export matches the current timeline." : "The timeline has changed since this export.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .reviewAcceptanceProbe("export.film-binding", text: attempt.finishedTimelineSHA256)
            }
        }
    }

    private func jobRow(_ job: ExportJob) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Button {
                selectedID = job.id
                actionError = nil
            } label: {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(job.title).fontWeight(AppTheme.FontWeight.medium)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(job.detail).foregroundStyle(AppTheme.Text.secondaryColor)
                    Text(job.createdAt, style: .date).foregroundStyle(AppTheme.Text.secondaryColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected?.id == job.id ? .isSelected : [])
            .reviewAcceptanceProbe("export.history.\(job.id)", text: job.status.rawValue)
            if !job.status.isTerminal {
                ProgressView(value: job.progress)
                Text("\(Int(job.progress * 100))%").monospacedDigit().foregroundStyle(AppTheme.Text.secondaryColor)
            }
            WrapLayout(spacing: AppTheme.Spacing.sm) {
                Button("Cancel") { queue.cancel(jobID: job.id) }
                    .disabled(!job.canCancel)
                    .reviewAcceptanceProbe("export.job.\(job.id).cancel")
                Button("Retry") {
                    do { selectedID = try queue.retry(jobID: job.id).id; actionError = nil }
                    catch { actionError = error.localizedDescription }
                }
                .disabled(!queue.canRetry(jobID: job.id))
                .reviewAcceptanceProbe("export.job.\(job.id).retry")
                Button("Reveal") {
                    if let url = job.destinationURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .disabled(!job.canReveal)
                .reviewAcceptanceProbe("export.job.\(job.id).reveal")
            }
            .buttonStyle(.capsule(.secondary, size: .small))
        }
        .padding(AppTheme.Spacing.sm)
        .background(selected?.id == job.id ? AppTheme.Background.prominentColor : AppTheme.Background.raisedColor,
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
    }

    @ViewBuilder private func jobEvidence(_ job: ExportJob) -> some View {
        AppDivider()
        Text("Output details").fontWeight(AppTheme.FontWeight.semibold)
        if let url = job.destinationURL { Text(url.path).textSelection(.enabled).foregroundStyle(AppTheme.Text.secondaryColor) }
        if let failure = job.failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor) }
        ForEach(Array(job.warnings.enumerated()), id: \.offset) { _, warning in
            Text(warning).foregroundStyle(AppTheme.Status.warningColor)
        }
        if loadingEvidence { ProgressView("Checking output…") }
        if let evidenceError { Text(evidenceError).foregroundStyle(AppTheme.Status.errorColor) }
        if job.kind == .video && job.status == .completed {
            Button("Check files again") { verificationRevision += 1 }
                .buttonStyle(.capsule(.secondary, size: .small))
                .disabled(loadingEvidence)
                .reviewAcceptanceProbe("export.qc.recheck")
        }
        if let attempt, let qc = attempt.probeQC {
            Text("Verified output").fontWeight(AppTheme.FontWeight.semibold)
                .reviewAcceptanceProbe("export.qc", text: qc.passed ? "passed" : "failed")
            Text("\(qc.width) × \(qc.height) · \(qc.fpsNumerator)/\(qc.fpsDenominator) fps · \(qc.videoCodec)")
            Text("Duration: \(Double(qc.durationValue) / Double(max(1, qc.durationTimescale)), format: .number.precision(.fractionLength(2))) s")
            Text(qc.audioCodec.map { "Audio: \($0) · \(qc.audioChannels) channels" } ?? "No audio track")
            Text(attempt.sequenceReviewSHA256 == nil ? "Sequence review was optional." : "Current sequence review was bound to this export.")
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if let artwork {
                Text("Poster image · \(artwork.width) × \(artwork.height)").fontWeight(AppTheme.FontWeight.medium)
                    .reviewAcceptanceProbe("export.artwork.verified", text: artwork.pngSHA256)
                Text(artwork.selection.displayName).foregroundStyle(AppTheme.Text.secondaryColor)
                if let posterImage {
                    Image(nsImage: posterImage).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxHeight: AppTheme.ComponentSize.toolImagePreviewMaxHeight)
                        .accessibilityLabel("Exported poster image")
                }
                if let output = job.destinationURL {
                    Button("Reveal poster") {
                        NSWorkspace.shared.activateFileViewerSelecting([ExportArtwork.outputURL(for: output)])
                    }
                    .buttonStyle(.capsule(.secondary, size: .small))
                    .reviewAcceptanceProbe("export.artwork.reveal")
                }
            }
            DisclosureGroup("Source and file checksums") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Film: \(attempt.finishedTimelineSHA256)")
                    Text("Output: \(attempt.outputSHA256 ?? "—")")
                    if let artwork { Text("Poster: \(artwork.pngSHA256)") }
                }.textSelection(.enabled)
            }
        } else if let report = job.fcpxmlReport {
            Text("Validated Apple DTD · FCPXML \(report.version.rawValue)")
            Text("\(report.mediaBindings.count) bound media assets · \(ByteCountFormatter.string(fromByteCount: report.outputByteCount, countStyle: .file))")
            ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning.message).foregroundStyle(AppTheme.Status.warningColor)
            }
        } else if let bytes = job.outputByteCount {
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
    }

    private func loadEvidence() async {
        let identity = evidenceKey
        let jobID = selected?.kind == .video && selected?.status.isTerminal == true ? selected?.id : nil
        let root = editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
        attempt = nil; artwork = nil; posterImage = nil; evidenceError = nil; loadingEvidence = jobID != nil
        do {
            let evidence = try await Task.detached(priority: .utility) {
                let value = try jobID.flatMap { id in
                    try root.map { try PipelineDeliveryStore.loadAttempt(id: id, dataRoot: $0) }
                }
                let artwork: ExportArtworkSnapshot?
                let png: Data?
                if let value, value.status == .succeeded, let root {
                    artwork = try ExportArtwork.load(spec: value.spec, dataRoot: root, timelineSHA256: value.finishedTimelineSHA256)
                    png = try artwork.map { try Data(contentsOf: ProjectLocalFile.resolve($0.pngPath, dataRoot: root)) }
                } else { artwork = nil; png = nil }
                return (value, artwork, png)
            }.value
            guard !Task.isCancelled, identity == evidenceKey else { return }
            attempt = evidence.0
            artwork = evidence.1
            posterImage = evidence.2.flatMap { NSImage(data: $0) }
        } catch {
            guard !Task.isCancelled, identity == evidenceKey else { return }
            evidenceError = error.localizedDescription
        }
        loadingEvidence = false
    }
}
