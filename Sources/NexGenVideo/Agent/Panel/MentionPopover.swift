import SwiftUI

enum MentionTab: CaseIterable, Hashable {
    // `.document` is labeled "Text" — the file-backed text assets (scripts, lyrics, notes: .txt/.md/…).
    // ClipType.text is a title clip, never a library asset, so it needs no tab.
    case all, video, image, audio, document

    var label: String {
        switch self {
        case .all: "All"
        case .video: "Video"
        case .image: "Image"
        case .audio: "Audio"
        case .document: "Text"
        }
    }

    var clipType: ClipType? {
        switch self {
        case .all: nil
        case .video: .video
        case .image: .image
        case .audio: .audio
        case .document: .document
        }
    }

    var emptyLabel: String {
        switch self {
        case .all: "No media"
        case .video: "No video clips"
        case .image: "No images"
        case .audio: "No audio"
        case .document: "No text"
        }
    }
}

/// Pure render. State lives on `AgentInputBox` so keyboard nav follows the focused TextEditor.
struct MentionPopover: View {
    let query: String
    let candidates: [MediaAsset]
    @Binding var highlightedIndex: Int
    @Binding var tab: MentionTab
    let scrollTick: Int
    let onPick: (MediaAsset) -> Void
    let onUpload: () -> Void

    @State private var visibleIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            tabStrip
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: AppTheme.BorderWidth.hairline)
            contentArea
                .frame(height: AppTheme.ComponentSize.mentionPopoverHeight)
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: AppTheme.BorderWidth.hairline)
            uploadRow
        }
        .frame(width: AppTheme.ComponentSize.mentionPopoverWidth)
        .glassEffect(.clear, in: .rect(cornerRadius: AppTheme.Radius.md))
    }

    /// Pinned below the list so a new file is always one click away — the point of the picker is to
    /// name something the agent can act on, and the thing you want may not be in the library yet.
    /// Imports + @mentions the pick through the same path as the composer's paperclip.
    private var uploadRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "paperclip")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.smMd)
            Text("Upload a file\u{2026}")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture { onUpload() }
    }

    @ViewBuilder
    private var contentArea: some View {
        if candidates.isEmpty {
            Text(query.isEmpty ? tab.emptyLabel : "No matches for \"\(query)\"")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(AppTheme.Spacing.md)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: AppTheme.Spacing.none) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, asset in
                            AssetRow(asset: asset, isHighlighted: index == highlightedIndex)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(asset) }
                                .onHover { hovering in if hovering { highlightedIndex = index } }
                                .id(asset.id)
                                .onScrollVisibilityChange(threshold: 0.95) { visible in
                                    if visible {
                                        visibleIDs.insert(asset.id)
                                    } else {
                                        visibleIDs.remove(asset.id)
                                    }
                                }
                        }
                    }
                }
                .onChange(of: scrollTick) { _, _ in
                    scrollHighlightIntoViewIfNeeded(proxy: proxy)
                }
                .onChange(of: candidates.map(\.id)) { _, ids in
                    visibleIDs.formIntersection(ids)
                }
            }
        }
    }

    private func scrollHighlightIntoViewIfNeeded(proxy: ScrollViewProxy) {
        guard candidates.indices.contains(highlightedIndex) else { return }
        let targetID = candidates[highlightedIndex].id
        if visibleIDs.contains(targetID) { return }

        let visibleIndices = visibleIDs.compactMap { id in
            candidates.firstIndex { $0.id == id }
        }
        let anchor: UnitPoint = (visibleIndices.max().map { highlightedIndex > $0 } ?? false)
            ? .bottom
            : .top

        withAnimation(.easeOut(duration: AppTheme.Anim.quick)) {
            proxy.scrollTo(targetID, anchor: anchor)
        }
    }

    private var tabStrip: some View {
        HStack(spacing: AppTheme.Spacing.none) {
            ForEach(MentionTab.allCases, id: \.self) { t in
                Text(t.label)
                    .font(.system(size: AppTheme.FontSize.xs, weight: t == tab ? .semibold : .regular))
                    .foregroundStyle(t == tab ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppTheme.Spacing.xsSm)
                    .background(
                        t == tab
                            ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.selection)
                            : AppTheme.Background.clearColor,
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { tab = t }
            }
        }
        .padding(AppTheme.Spacing.xs)
    }

}
