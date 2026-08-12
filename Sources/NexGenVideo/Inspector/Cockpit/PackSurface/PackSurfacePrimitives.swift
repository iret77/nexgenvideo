import SwiftUI

// The host's fixed vocabulary of cockpit-surface primitives (docs/ui/pack-surfaces.html). A pack
// declares WHICH surface kind it wants; the host renders it from these. All values via AppTheme.

/// Section band / swatch colors, cycled by section index so adjacent sections stay distinct.
enum PackSurfacePalette {
    private static let colors: [Color] = [
        AppTheme.Accent.timecodeColor, AppTheme.Status.successColor, AppTheme.Status.warningColor, AppTheme.Accent.pack,
    ]
    static func section(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

enum PackSurfaceFormat {
    /// `m:ss` timecode. Guards non-finite/negative so a malformed value never renders "nan".
    static func mmss(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func measuredTimecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.00" }
        let centiseconds = Int((seconds * 100).rounded())
        return String(
            format: "%d:%02d.%02d",
            centiseconds / 6000,
            (centiseconds % 6000) / 100,
            centiseconds % 100
        )
    }
}

/// A labelled value tile. `id` is the label (labels are unique within a row).
struct StatTile: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let value: String
    var muted: Bool = false
}

/// A wrapping row of stat tiles (label + value).
struct StatRow: View {
    let tiles: [StatTile]
    private let columns = [GridItem(.adaptive(minimum: 116), spacing: AppTheme.Spacing.sm)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.sm) {
            ForEach(tiles) { tile in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(tile.label.uppercased())
                        .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.semibold))
                        .tracking(AppTheme.Tracking.wide)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text(tile.value)
                        .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(tile.muted ? AppTheme.Text.mutedColor : AppTheme.Text.primaryColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .background(AppTheme.Background.surfaceColor)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
            }
        }
    }
}

/// The beat grid: section bands across the top, beat ticks below, downbeats emphasized. Drawn on a
/// Canvas so hundreds of beats render as marks, not hundreds of views.
struct BeatTimeline: View {
    let duration: Double
    let beats: [Double]
    let downbeats: [Double]
    let sections: [AnalysisSurfaceData.Section]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Canvas { ctx, size in
                guard duration > 0 else { return }
                let w = size.width, h = size.height
                let bandHeight = AppTheme.ComponentSize.beatTimelineBandHeight
                func x(_ t: Double) -> CGFloat { CGFloat(min(max(t, 0), duration) / duration) * w }

                for section in sections {
                    let x0 = x(section.start), x1 = x(section.end)
                    let rect = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: bandHeight)
                    ctx.fill(Path(rect), with: .color(PackSurfacePalette.section(section.index).opacity(AppTheme.Opacity.prominent)))
                }
                let top = bandHeight + AppTheme.Spacing.xs
                for beat in beats {
                    var path = Path()
                    path.move(to: CGPoint(x: x(beat), y: top + (h - top) * 0.55))
                    path.addLine(to: CGPoint(x: x(beat), y: h))
                    ctx.stroke(path, with: .color(AppTheme.Text.mutedColor), lineWidth: AppTheme.BorderWidth.thin)
                }
                for downbeat in downbeats {
                    var path = Path()
                    path.move(to: CGPoint(x: x(downbeat), y: top))
                    path.addLine(to: CGPoint(x: x(downbeat), y: h))
                    ctx.stroke(path, with: .color(AppTheme.Accent.timecodeColor), lineWidth: AppTheme.BorderWidth.medium)
                }
            }
            .frame(height: AppTheme.ComponentSize.packSurfaceRowHeight)
            .background(AppTheme.Background.surfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
            )
            ruler
        }
    }

    private var ruler: some View {
        HStack(spacing: AppTheme.Spacing.none) {
            ForEach(0..<5) { i in
                Text(PackSurfaceFormat.mmss(duration * Double(i) / 4))
                    .font(.system(size: AppTheme.FontSize.micro))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : (i == 4 ? .trailing : .center))
            }
        }
    }
}

struct StructureHierarchyList: View {
    let sections: [AnalysisSurfaceData.HierarchySection]

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            ForEach(sections) { section in
                VStack(spacing: AppTheme.Spacing.none) {
                    sectionRow(section)
                    ForEach(section.segments.indices, id: \.self) { segmentOffset in
                        let segment = section.segments[segmentOffset]
                        segmentRow(segment, number: segmentOffset + 1)
                        ForEach(segment.phrases.indices, id: \.self) { phraseOffset in
                            phraseRow(segment.phrases[phraseOffset], number: phraseOffset + 1)
                        }
                    }
                }
                if section.id != sections.last?.id {
                    AppDivider()
                }
            }
        }
        .background(AppTheme.Background.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private func sectionRow(_ row: AnalysisSurfaceData.HierarchySection) -> some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                .fill(PackSurfacePalette.section(row.section.index))
                .frame(width: AppTheme.IconSize.xxs, height: AppTheme.IconSize.xxs)
            Text(row.section.label ?? "Section \(row.section.index + 1)")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            if let source = row.section.source {
                Text(source)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            range(row.section.start, row.section.end, color: AppTheme.Text.secondaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    private func segmentRow(_ segment: AnalysisSurfaceData.HierarchySegment, number: Int) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "rectangle.split.3x1")
                .frame(width: AppTheme.IconSize.xs)
            Text("Segment \(number)")
            Spacer(minLength: AppTheme.Spacing.sm)
            range(segment.start, segment.end, color: AppTheme.Text.tertiaryColor)
        }
        .font(.system(size: AppTheme.FontSize.xs))
        .foregroundStyle(AppTheme.Text.tertiaryColor)
        .padding(.leading, AppTheme.Spacing.xl)
        .padding(.trailing, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .background(AppTheme.Background.raisedColor.opacity(AppTheme.Opacity.faint))
    }

    private func phraseRow(_ phrase: AnalysisSurfaceData.HierarchyPhrase, number: Int) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "minus")
                .frame(width: AppTheme.IconSize.xs)
            Text("Phrase \(number)")
            Spacer(minLength: AppTheme.Spacing.sm)
            range(phrase.start, phrase.end, color: AppTheme.Text.mutedColor)
        }
        .font(.system(size: AppTheme.FontSize.micro))
        .foregroundStyle(AppTheme.Text.mutedColor)
        .padding(.leading, AppTheme.Spacing.xxl)
        .padding(.trailing, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xxs)
    }

    private func range(_ start: Double, _ end: Double, color: Color) -> some View {
        Text("\(PackSurfaceFormat.measuredTimecode(start)) – \(PackSurfaceFormat.measuredTimecode(end))")
            .foregroundStyle(color)
            .monospacedDigit()
    }
}
