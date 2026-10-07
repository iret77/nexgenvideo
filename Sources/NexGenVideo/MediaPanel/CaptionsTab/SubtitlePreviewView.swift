import SwiftUI

struct SubtitlePreviewView: View {
    let url: URL?

    @State private var document: SubtitleDocument?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView(
                    "Caption file unavailable",
                    systemImage: "captions.bubble",
                    description: Text(errorMessage)
                )
            } else if let document {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        ForEach(Array(document.cues.enumerated()), id: \.offset) { offset, cue in
                            cueRow(number: offset + 1, cue: cue)
                        }
                    }
                    .padding(AppTheme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.previewCanvasColor)
        .task(id: url) {
            guard let url else {
                document = nil
                errorMessage = "Relink the caption file."
                return
            }
            do {
                let parsed = try await SubtitleFileParser.parseFile(at: url)
                guard !Task.isCancelled else { return }
                document = parsed
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                document = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cueRow(number: Int, cue: SubtitleCue) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(verbatim: "\(number)")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(verbatim: "\(timestamp(cue.start)) → \(timestamp(cue.end))")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .interfaceFont(size: AppTheme.Typography.metadata)

            Text(verbatim: cue.text)
                .interfaceFont(size: AppTheme.Typography.reading)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .textSelection(.enabled)
        }
    }

    private func timestamp(_ value: SubtitleTimestamp) -> String {
        let total = value.milliseconds
        let hours = total / 3_600_000
        let minutes = total / 60_000 % 60
        let seconds = total / 1_000 % 60
        let milliseconds = total % 1_000
        return String(format: "%02lld:%02lld:%02lld.%03lld", hours, minutes, seconds, milliseconds)
    }
}
