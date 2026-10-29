import AppKit
import NexGenEngine
import SwiftUI
import UniformTypeIdentifiers

struct StoryboardNativeSketchSheet: View {
    enum Mode { case sourceFrame, external }
    let home: URL
    let shotID: String
    let momentID: String
    let intent: String
    let fingerprint: String
    let mode: Mode
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFile = false
    @State private var operation: Task<Void, Never>?
    @State private var source: PipelineStoryboardNativeMedia.SourceSnapshot?
    @State private var frame: PipelineStoryboardNativeMedia.FrameCandidate?
    @State private var external: PipelineStoryboardNativeMedia.ExternalCandidate?
    @State private var sourceSeconds = "0"
    @State private var sourceDescription = ""
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var inspecting = false
    @State private var previewSHA256 = ""

    private var active: Bool {
        guard operation == nil, editor.workingRoot == home, editor.projectState?.nextPhaseName == "storyboard",
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let root = DataRootResolver.dataRoot(of: home) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }
    private var ready: Bool { active && image != nil && (mode == .sourceFrame ? frame != nil : external != nil && !sourceDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text(mode == .sourceFrame ? "Sketch from source video" : "Import external sketch")
                .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text(intent).textSelection(.enabled)
                    Button(mode == .sourceFrame ? "Choose source video…" : "Choose external sketch…") { choosingFile = true }
                        .buttonStyle(InlineActionButtonStyle()).disabled(!active)
                        .reviewAcceptanceProbe("storyboard.native-sketch.choose", state: active)
                    if let source, let root = DataRootResolver.dataRoot(of: home) {
                        ProductionInputPreview(reference: source.source, dataRoot: root, title: source.originalFilename)
                        TextField("Source position (seconds)", text: $sourceSeconds).disabled(!active)
                            .reviewAcceptanceProbe("storyboard.native-sketch.source-seconds", text: sourceSeconds)
                        Text("Source duration: \(String(format: "%.6f", source.timebase.seconds(for: source.durationTicks))) s")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Button("Preview frame") { extract() }.buttonStyle(InlineActionButtonStyle()).disabled(!active)
                            .reviewAcceptanceProbe("storyboard.native-sketch.preview-frame", state: active)
                    }
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(height: AppTheme.Layout.productionAssetPreviewHeight).frame(maxWidth: .infinity)
                            .accessibilityLabel("Selected sketch preview")
                            .reviewAcceptanceProbe("storyboard.native-sketch.image", text: previewSHA256)
                        Button("Inspect image") { inspecting = true }.buttonStyle(InlineActionButtonStyle())
                            .reviewAcceptanceProbe("storyboard.native-sketch.inspect")
                        if let frame {
                            Text("Decoded source frame: \(String(format: "%.6f", frame.timebase.seconds(for: frame.sourceTick))) s")
                                .monospacedDigit().foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                    }
                    if let external {
                        Text(external.originalFilename).textSelection(.enabled)
                        TextField("Source or author of this sketch", text: $sourceDescription, axis: .vertical).disabled(!active)
                            .reviewAcceptanceProbe("storyboard.native-sketch.source-description", text: sourceDescription)
                        Text("Confirm that this external image represents the planned moment shown above.")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    if operation != nil { ProgressView("Preparing sketch…") }
                    if let failure {
                        Text(failure).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled)
                            .reviewAcceptanceProbe("storyboard.native-sketch.failure", text: failure)
                    }
                }
            }
            HStack {
                Button(operation == nil ? "Cancel" : "Cancel operation") {
                    if let operation { operation.cancel() } else { dismiss() }
                }.buttonStyle(InlineActionButtonStyle()).keyboardShortcut(.cancelAction)
                    .reviewAcceptanceProbe("storyboard.native-sketch.cancel")
                Spacer()
                Button(mode == .sourceFrame ? "Assign source frame" : "Confirm external sketch") { assign() }
                    .buttonStyle(.capsule(.prominent, size: .regular)).disabled(!ready)
                    .reviewAcceptanceProbe("storyboard.native-sketch.confirm", state: ready)
            }
        }
        .padding(AppTheme.Spacing.lg).interfaceFont(size: AppTheme.Typography.ui)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        .reviewAcceptanceProbe("storyboard.native-sketch.sheet", text: mode == .sourceFrame ? "sourceFrame" : "external")
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: mode == .sourceFrame ? [.movie] : [.image]) { result in
            switch result {
            case .success(let url): choose(url)
            case .failure(let error): failure = error.localizedDescription
            }
        }
        .onChange(of: sourceSeconds) { _, _ in frame = nil; image = nil; previewSHA256 = "" }
        .onChange(of: editor.workingRoot) { _, value in if value != home { operation?.cancel(); dismiss() } }
        .onDisappear { operation?.cancel() }.interactiveDismissDisabled(operation != nil)
        .sheet(isPresented: $inspecting) {
            if let full = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ProductionImageInspectionView(image: full, title: intent)
            }
        }
    }

    private func choose(_ url: URL) {
        guard active else { return }
        failure = nil; frame = nil; external = nil; image = nil; previewSHA256 = ""
        operation = Task {
            defer { operation = nil }
            do {
                if mode == .sourceFrame {
                    let result = try await PipelineStoryboardNativeMedia.importSource(from: url, expectedFingerprint: fingerprint, editor: editor)
                    guard !Task.isCancelled, editor.workingRoot == home else { return }
                    source = result; sourceSeconds = "0"
                } else {
                    let result = try await PipelineStoryboardNativeMedia.prepareExternal(from: url, shotID: shotID,
                        momentID: momentID, expectedFingerprint: fingerprint, editor: editor)
                    guard !Task.isCancelled, editor.workingRoot == home else { return }
                    guard let preview = NSImage(data: result.previewData) else { throw GateBlocked("The sketch could not be displayed.") }
                    external = result; image = preview; previewSHA256 = FileDigest.sha256(of: result.previewData)
                }
            } catch is CancellationError { failure = "The operation was cancelled." }
            catch { failure = error.localizedDescription }
        }
    }

    private func extract() {
        guard active, let source else { return }
        failure = nil; frame = nil; image = nil; previewSHA256 = ""
        let seconds = sourceSeconds
        operation = Task {
            defer { operation = nil }
            do {
                let tick = try StoryboardSourceTimeEntry.tick(seconds, clock: source.timebase, durationTicks: source.durationTicks)
                let result = try await PipelineStoryboardNativeMedia.prepareFrame(source: source, sourceTick: tick, shotID: shotID,
                    momentID: momentID, expectedFingerprint: fingerprint, editor: editor)
                guard !Task.isCancelled, editor.workingRoot == home else { return }
                guard let preview = NSImage(data: result.previewData) else { throw GateBlocked("The source frame could not be displayed.") }
                frame = result; image = preview; previewSHA256 = FileDigest.sha256(of: result.previewData)
            } catch is CancellationError { failure = "The operation was cancelled." }
            catch { failure = error.localizedDescription }
        }
    }

    private func assign() {
        guard ready else { return }
        let frame = frame, external = external, description = sourceDescription
        failure = nil
        operation = Task {
            defer { operation = nil }
            do {
                if let frame { _ = try await PipelineStoryboardNativeMedia.assignFrame(frame, editor: editor) }
                else if let external { _ = try await PipelineStoryboardNativeMedia.confirmExternal(external, sourceDescription: description, editor: editor) }
                else { return }
                dismiss()
            } catch is CancellationError { failure = "The operation was cancelled." }
            catch { failure = error.localizedDescription }
        }
    }
}

enum StoryboardSourceTimeEntry {
    static func tick(_ text: String, clock: SourceMediaTimebaseV1, durationTicks: Int64) throws -> Int64 {
        try clock.validate()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^[0-9]+(?:[.,][0-9]+)?$", options: .regularExpression) != nil,
              let seconds = Decimal(string: value.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")),
              !seconds.isNaN, seconds >= 0 else { throw GateBlocked("Enter a source position in seconds.") }
        var ticks = seconds * Decimal(clock.ticksPerSecond)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &ticks, 0, .plain)
        guard !rounded.isNaN, rounded >= 0, rounded < Decimal(durationTicks) else {
            throw GateBlocked("Choose a position before the end of the source video.")
        }
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}
