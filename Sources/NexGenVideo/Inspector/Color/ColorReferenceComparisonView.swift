import AppKit
import NexGenEngine
import SwiftUI

struct ColorReferenceComparisonView: View {
    let clipID: String
    @Environment(EditorViewModel.self) private var editor
    @State private var expanded = false
    @State private var referenceID: String?
    @State private var comparison = ColorReferenceComparisonStore()

    private var available: Bool {
        !comparison.busy && !editor.agentService.isStreaming && !editor.agentService.isComposerBlocked
            && editor.selectedClipIds == [clipID]
    }

    var body: some View {
        DisclosureGroup("Reference color comparison", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text("Graded clip at playhead (clamped to clip) · raw reference midpoint")
                    .interfaceFont(size: AppTheme.Typography.metadata).foregroundStyle(AppTheme.Text.secondaryColor)
                LibraryAssetPickerButton(purpose: .generationSlot("color-reference/" + clipID), acceptedTypes: [.image, .video],
                    title: referenceID.flatMap { id in editor.mediaAssets.first(where: { $0.id == id })?.name } ?? "Choose reference…") {
                    referenceID = $0.id; comparison.discard()
                }
                .disabled(!available)
                .reviewAcceptanceProbe("color.reference.choose", state: available, text: referenceID ?? "")
                Button("Measure comparison") {
                    if let referenceID { Task { await comparison.measure(clipID: clipID, referenceID: referenceID, editor: editor) } }
                }.buttonStyle(InlineActionButtonStyle()).disabled(!available || referenceID == nil)
                    .reviewAcceptanceProbe("color.reference.measure", state: available && referenceID != nil)
                if comparison.busy { ProgressView("Checking color and source bytes…") }
                if let snapshot = comparison.snapshot {
                    frame(snapshot.images[0], title: "Measured graded clip", id: "clip")
                    frame(snapshot.images[1], title: "Raw reference · " + snapshot.referenceName, id: "reference")
                    measurements(snapshot.measurements)
                        .reviewAcceptanceProbe("color.reference.comparison", text: snapshot.id.uuidString)
                    Text("Measured values describe these frames. They do not certify a creative match.")
                        .interfaceFont(size: AppTheme.Typography.metadata).foregroundStyle(AppTheme.Text.secondaryColor)
                    ForEach(snapshot.measurements.gap.hints, id: \.self) { Text($0).foregroundStyle(AppTheme.Text.secondaryColor) }
                    Button("Ask AI for correction") { Task { await comparison.requestProposal(editor: editor) } }
                        .buttonStyle(InlineActionButtonStyle()).disabled(!available)
                        .reviewAcceptanceProbe("color.reference.propose", state: available)
                }
                if let proposal = comparison.proposal {
                    Text("AI proposal").interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                        .reviewAcceptanceProbe("color.reference.proposal", text: proposal.comparisonID.uuidString)
                    Text(proposal.rationale).textSelection(.enabled)
                        .reviewAcceptanceProbe("color.reference.rationale", text: proposal.rationale)
                    ForEach(proposal.grade.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(proposal.grade[key] ?? 0, specifier: "%.3f")")
                            .reviewAcceptanceProbe("color.reference.control." + key, text: String(proposal.grade[key] ?? 0))
                    }
                    WrapLayout(spacing: AppTheme.Spacing.sm) {
                        Button("Discard") { comparison.discard() }.buttonStyle(InlineActionButtonStyle()).disabled(!available)
                            .reviewAcceptanceProbe("color.reference.discard", state: available)
                        Button("Apply correction") { Task { await comparison.apply(editor: editor) } }
                            .buttonStyle(.capsule(.primary, size: .regular)).disabled(!available)
                            .reviewAcceptanceProbe("color.reference.apply", state: available)
                    }
                }
                if let message = comparison.message {
                    Text(message).foregroundStyle(AppTheme.Text.secondaryColor).reviewAcceptanceProbe("color.reference.status", text: message)
                }
                if let error = comparison.error {
                    Text(error).foregroundStyle(AppTheme.Status.errorColor).reviewAcceptanceProbe("color.reference.error", text: error)
                }
            }.padding(.vertical, AppTheme.Spacing.sm)
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .padding(AppTheme.Spacing.md)
        .reviewAcceptanceProbe("color.reference.open", text: expanded ? "open" : "closed")
        .onChange(of: clipID) { _, _ in comparison.discard(); referenceID = nil }
        .onChange(of: editor.agentService.isStreaming) { _, streaming in
            if !streaming { comparison.agentFinished(editor: editor) }
        }
        .onDisappear { comparison.discard() }
    }

    private func frame(_ data: Data, title: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title).interfaceFont(size: AppTheme.Typography.metadata)
            if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: AppTheme.Layout.previewMinHeight) }
        }.reviewAcceptanceProbe("color.reference.frame." + id, text: FileDigest.sha256(of: data))
    }

    private func measurements(_ values: ColorReferenceMeasurements) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Measurement · clip / reference / difference")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
            row("Mean luma", values.clip.luma.mean, values.reference.luma.mean, values.gap.lumaMean, id: "mean")
            row("Black point", values.clip.luma.black, values.reference.luma.black, values.gap.lumaBlack, id: "black")
            row("White point", values.clip.luma.white, values.reference.luma.white, values.gap.lumaWhite, id: "white")
            row("Saturation", values.clip.saturation, values.reference.saturation, values.gap.saturation, id: "saturation")
            row("Warm / cool", values.clip.balance.warmCool, values.reference.balance.warmCool, values.gap.warmCool, id: "warmCool")
            row("Green / magenta", values.clip.balance.greenMagenta, values.reference.balance.greenMagenta, values.gap.greenMagenta, id: "greenMagenta")
            Text("Clipped low / high · clip \(values.clip.luma.clipLowPct, specifier: "%.3f")% / \(values.clip.luma.clipHighPct, specifier: "%.3f")% · reference \(values.reference.luma.clipLowPct, specifier: "%.3f")% / \(values.reference.luma.clipHighPct, specifier: "%.3f")%")
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .reviewAcceptanceProbe("color.reference.measured.clipping", text: "\(values.clip.luma.clipLowPct)|\(values.clip.luma.clipHighPct)|\(values.reference.luma.clipLowPct)|\(values.reference.luma.clipHighPct)")
        }
    }

    private func row(_ label: String, _ clip: Double, _ reference: Double, _ gap: Double, id: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(label)
            Text("\(clip, specifier: "%.3f") / \(reference, specifier: "%.3f") / \(gap, specifier: "%+.3f")")
                .monospacedDigit().foregroundStyle(AppTheme.Text.secondaryColor)
        }.reviewAcceptanceProbe("color.reference.measured." + id, text: "\(clip)|\(reference)|\(gap)")
    }
}
