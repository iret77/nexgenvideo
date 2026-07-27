import Foundation
import SwiftUI

extension EditorViewModel {
    var agentPickableMediaAssets: [MediaAsset] {
        mediaAssets.filter { asset in
            !asset.isGenerating
                && !missingMediaRefs.contains(asset.id)
                && !offlineMediaRefs.contains(asset.id)
                && FileManager.default.fileExists(atPath: asset.url.path)
        }
    }
}

/// One library-asset row — a thumbnail (or a type-symbol fallback), the name, and the type. The single
/// asset row shared by the `@`-mention popover, the composer's Reference picker, and the file-intake
/// card, so every asset list in the agent surface is the same element (not three look-alikes).
struct AssetRow: View {
    let asset: MediaAsset
    var isHighlighted: Bool = false
    /// Trailing affordance hinting the row adds the asset on tap (e.g. `plus.circle`); nil in the
    /// `@`-mention popover, where the whole row is already the target.
    var trailingSystemImage: String? = nil

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Group {
                if let thumb = asset.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: asset.type.sfSymbolName)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
            }
            .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.smMd)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.micro) {
                Text(asset.mentionDisplayName)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Text(asset.type.rawValue)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(isHighlighted ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted) : AppTheme.Background.clearColor)
    }
}

/// The library-asset picker shared by the composer (a popover opened from "Reference asset") and the
/// file-intake card (inline, below the drop well). The caller pre-filters `assets` and owns the pick —
/// the composer turns it into an `@`mention, the intake into the chosen file — so this view knows
/// neither path. It only picks something already in the library; adding a NEW file stays on the
/// composer's paperclip and the card's Choose button.
struct LibraryAssetPicker: View {
    let assets: [MediaAsset]
    var showsSearch: Bool = false
    var showsTypeTabs: Bool = false
    /// Scroll the rows within this height (the composer popover, over the whole library); nil lays them
    /// out at natural height (the intake card's short accept-filtered list).
    var scrollHeight: CGFloat? = nil
    /// Floated to the top and marked — the composer passes the currently inspected asset so the user's
    /// selection is the obvious first pick (docs/UI_UX_CONCEPT.md §2.2).
    var pinnedId: String? = nil
    var emptyLabel: String = "Nothing in your library yet"
    let onPick: (MediaAsset) -> Void

    @State private var query: String = ""
    @State private var tab: MentionTab = .all

    private var visible: [MediaAsset] {
        var out = assets
        if let clip = tab.clipType { out = out.filter { $0.type == clip } }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            out = out.filter {
                $0.mentionDisplayName.lowercased().contains(q) || $0.name.lowercased().contains(q)
            }
        }
        if let pinnedId, let idx = out.firstIndex(where: { $0.id == pinnedId }) {
            out.insert(out.remove(at: idx), at: 0)
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if showsSearch { searchField }
            if showsTypeTabs { tabStrip }
            if visible.isEmpty {
                Text(query.isEmpty ? emptyLabel : "No matches for \u{201C}\(query)\u{201D}")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppTheme.Spacing.sm)
            } else {
                rows
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        let list = LazyVStack(spacing: AppTheme.Spacing.none) {
            ForEach(visible) { asset in
                Button { onPick(asset) } label: {
                    AssetRow(asset: asset,
                             isHighlighted: asset.id == pinnedId,
                             trailingSystemImage: "plus.circle")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
                .help("Reference \u{201C}\(asset.mentionDisplayName)\u{201D}")
            }
        }
        if let scrollHeight {
            ScrollView { list }.frame(maxHeight: scrollHeight)
        } else {
            list
        }
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField("Search your library\u{2026}", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.muted))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private var tabStrip: some View {
        HStack(spacing: AppTheme.Spacing.none) {
            ForEach(MentionTab.allCases, id: \.self) { t in
                Text(t.label)
                    .font(.system(size: AppTheme.FontSize.xs, weight: t == tab ? .semibold : .regular))
                    .foregroundStyle(t == tab ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                    .background(
                        t == tab ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted) : AppTheme.Background.clearColor,
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { tab = t }
            }
        }
    }
}
