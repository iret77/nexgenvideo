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
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
            }
            .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.smMd)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.micro) {
                Text(asset.mentionDisplayName)
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Text(asset.type.rawValue)
                    .interfaceFont(size: AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .interfaceFont(size: AppTheme.Typography.ui)
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
    var state: MediaPickerState? = nil
    var onReveal: ((MediaAsset) -> Void)? = nil
    let onPick: (MediaAsset) -> Void

    @State private var localState = MediaPickerState()
    private var pickerState: MediaPickerState { state ?? localState }
    private var query: String {
        get { pickerState.query }
        nonmutating set { pickerState.query = newValue }
    }
    private var visible: [MediaAsset] {
        let types: Set<ClipType> = showsTypeTabs ? (pickerState.type.map { Set([$0]) } ?? []) : []
        var out = MediaLibraryQuery(text: query, types: types).apply(to: assets)
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
                    .interfaceFont(size: AppTheme.Typography.ui)
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
                Button {
                    pickerState.selectedAssetID = asset.id
                    onPick(asset)
                } label: {
                    AssetRow(asset: asset,
                             isHighlighted: asset.id == (pickerState.selectedAssetID ?? pinnedId),
                             trailingSystemImage: "plus.circle")
                        .contentShape(Rectangle())
                }
                .id(asset.id)
                .contextMenu {
                    if let onReveal {
                        Button("Show in Media") { onReveal(asset) }
                    }
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
                .help("Reference \u{201C}\(asset.mentionDisplayName)\u{201D}")
            }
        }
        if let scrollHeight {
            ScrollView { list.scrollTargetLayout() }
                .scrollPosition(id: Binding(
                    get: { pickerState.scrollAssetID },
                    set: { pickerState.scrollAssetID = $0 }
                ))
                .frame(maxHeight: scrollHeight)
        } else {
            list
        }
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField("Search your library\u{2026}", text: Binding(get: { query }, set: { query = $0 }))
                .textFieldStyle(.plain)
                .interfaceFont(size: AppTheme.Typography.ui)
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
        NativeChoicePicker(
            label: "Media Type",
            options: MentionTab.allCases.map {
                .init(id: $0.clipType?.rawValue ?? "all", title: $0.label)
            },
            selection: Binding(
                get: { pickerState.type?.rawValue ?? "all" },
                set: { pickerState.type = ClipType(rawValue: $0) }
            )
        )
    }
}
