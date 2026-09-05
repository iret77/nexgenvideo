import SwiftUI

struct PipelinePhaseProgressView: View {
    let snapshot: PipelinePhaseExecutionSnapshot

    private var presentation: PipelinePhaseProgressPresentation {
        PipelinePhaseProgressPresentation(stageID: snapshot.stageID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "waveform")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Accent.timecodeColor)
                    .frame(
                        width: AppTheme.IconSize.lg,
                        height: AppTheme.IconSize.lg
                    )
                    .background(
                        Circle().fill(
                            AppTheme.Accent.timecodeColor.opacity(
                                AppTheme.Opacity.subtle
                            )
                        )
                    )
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(PhaseDisplay.label(snapshot.phase))
                        .interfaceFont(
                            size: AppTheme.Typography.ui,
                            weight: AppTheme.FontWeight.semibold
                        )
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(snapshot.sourceFilename ?? "Assigned track")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: AppTheme.Spacing.sm)
                if snapshot.totalUnitCount > 0 {
                    Text(
                        "\(snapshot.completedUnitCount) of \(snapshot.totalUnitCount)"
                    )
                    .interfaceFont(size: AppTheme.Typography.ui).monospacedDigit()
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(presentation.title)
                    .interfaceFont(
                        size: AppTheme.Typography.ui,
                        weight: AppTheme.FontWeight.semibold
                    )
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text(presentation.detail)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if snapshot.totalUnitCount > 0 {
                ProgressView(
                    value: Double(snapshot.completedUnitCount),
                    total: Double(snapshot.totalUnitCount)
                )
                .progressViewStyle(.linear)
                .tint(AppTheme.Accent.timecodeColor)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            if let nextStageID = snapshot.nextStageID {
                Text(
                    "Next: \(PipelinePhaseProgressPresentation(stageID: nextStageID).title)"
                )
                .interfaceFont(size: AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.md,
                style: .continuous
            )
            .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.md,
                style: .continuous
            )
            .strokeBorder(
                AppTheme.Border.subtleColor,
                lineWidth: AppTheme.BorderWidth.hairline
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(PhaseDisplay.label(snapshot.phase)), \(presentation.title), "
                + "\(snapshot.completedUnitCount) of \(snapshot.totalUnitCount)"
        )
    }
}

struct PipelinePhaseProgressPresentation {
    let title: String
    let detail: String

    init(stageID: String?) {
        switch stageID {
        case "decode_audio":
            title = "Reading the track"
            detail = "Decoding the assigned audio into measured samples."
        case "measure_structure":
            title = "Measuring rhythm and structure"
            detail = "Finding tempo, energy, sections and musical features."
        case "separate_stems":
            title = "Isolating vocals and stems"
            detail = "Separating the mix for cleaner musical and lyric analysis."
        case "resolve_beat_grid":
            title = "Resolving tempo and beat grid"
            detail = "Validating the measured rhythm grid for the track."
        case "detect_harmony":
            title = "Detecting key and chords"
            detail = "Reading the harmonic structure of the track."
        case "align_lyrics":
            title = "Aligning lyrics"
            detail = "Matching supplied lyrics to measured song timing."
        case "write_analysis":
            title = "Saving measured analysis"
            detail = "Validating and writing the canonical analysis artifact."
        default:
            title = "Preparing audio analysis"
            detail = "Starting the deterministic analysis pipeline."
        }
    }
}
