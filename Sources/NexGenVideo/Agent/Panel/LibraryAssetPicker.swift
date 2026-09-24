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
                Text(asset.libraryDisplayName)
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
    @Environment(EditorViewModel.self) private var editor
    let assets: [MediaAsset]
    let purpose: MediaLibraryPurpose
    var showsSearch: Bool = false
    var showsTypeTabs: Bool = false
    /// Scroll the rows within this height (the composer popover, over the whole library); nil lays them
    /// out at natural height (the intake card's short accept-filtered list).
    var scrollHeight: CGFloat? = nil
    var allowsDragging = false
    /// Floated to the top and marked — the composer passes the currently inspected asset so the user's
    /// selection is the obvious first pick (docs/UI_UX_CONCEPT.md §2.2).
    var pinnedId: String? = nil
    var emptyLabel: String = "Nothing in your library yet"
    let onPick: (MediaAsset) -> Void

    private func visible(session: MediaLibrarySession) -> [MediaAsset] {
        var out = MediaLibraryProjection.assets(from: assets, session: session)
        if let pinnedId, let idx = out.firstIndex(where: { $0.id == pinnedId }) {
            out.insert(out.remove(at: idx), at: 0)
        }
        return out
    }

    var body: some View {
        let session = editor.mediaLibrarySession(for: purpose)
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if showsSearch { searchField(session: session) }
            if showsSearch { compactControls(session: session) }
            if showsTypeTabs { tabStrip(session: session) }
            if visible(session: session).isEmpty {
                Text(session.query.isEmpty ? emptyLabel : "No matches for \u{201C}\(session.query)\u{201D}")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppTheme.Spacing.sm)
            } else {
                rows(session: session)
            }
        }
        .accessibilityIdentifier("mediaPicker.\(purpose.accessibilitySuffix)")
        .onChange(of: editor.folders.map(\.id), initial: true) { _, folderIDs in
            if let folderID = session.folderID, !Set(folderIDs).contains(folderID) {
                session.folderID = nil
            }
        }
    }

    @ViewBuilder
    private func rows(session: MediaLibrarySession) -> some View {
        let list = LazyVStack(spacing: AppTheme.Spacing.none) {
            ForEach(visible(session: session)) { asset in
                assetButton(asset, session: session)
            }
        }
        .scrollTargetLayout()
        if let scrollHeight {
            ScrollView { list }
                .scrollPosition(
                    id: Binding(
                        get: { session.scrollAnchorID },
                        set: { session.scrollAnchorID = $0 }
                    ),
                    anchor: .center
                )
                .frame(maxHeight: scrollHeight)
                .background {
                    if WorkspaceUIAcceptance.isRequested {
                        AppRelaunchClickProbe(
                            identifier: "mediaPicker.\(purpose.accessibilitySuffix).scroll"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                    }
                }
        } else {
            list
        }
    }

    @ViewBuilder
    private func assetButton(_ asset: MediaAsset, session: MediaLibrarySession) -> some View {
        let button = Button {
            session.selectedAssetIDs = [asset.id]
            session.activeAssetID = asset.id
            onPick(asset)
        } label: {
            AssetRow(
                asset: asset,
                isHighlighted: asset.id == pinnedId || session.selectedAssetIDs.contains(asset.id),
                trailingSystemImage: "plus.circle"
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        .help("Choose \u{201C}\(asset.libraryDisplayName)\u{201D}")
        .contextMenu {
            Button("Show in Media") { editor.revealMediaAsset(id: asset.id) }
        }
        .accessibilityIdentifier("mediaPicker.asset.\(asset.id)")
        .onAppear {
            WorkspaceUIAcceptance.recordPickerRow(assetID: asset.id, purpose: purpose)
        }
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(
                    identifier: "mediaPicker.\(purpose.accessibilitySuffix).asset.\(asset.id)"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }

        if allowsDragging {
            button.draggable(MediaTab.assetDragString(forAssetId: asset.id))
        } else {
            button
        }
    }

    private func searchField(session: MediaLibrarySession) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField(
                "Search filenames\u{2026}",
                text: Binding(get: { session.query }, set: { session.query = $0 })
            )
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

    private func compactControls(session: MediaLibrarySession) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Menu {
                Button("All Folders") { session.folderID = nil }
                ForEach(editor.folders) { folder in
                    Button(folder.name) { session.folderID = folder.id }
                }
            } label: {
                Label(
                    session.folderID.flatMap { editor.folder(id: $0)?.name } ?? "All Folders",
                    systemImage: "folder"
                )
            }
            .menuStyle(.button)
            .fixedSize()

            Menu {
                ForEach(MediaLibrarySort.allCases, id: \.self) { sort in
                    Button {
                        if session.sort == sort {
                            session.sortAscending.toggle()
                        } else {
                            session.sort = sort
                            session.sortAscending = true
                        }
                    } label: {
                        Label(sort.label, systemImage: session.sort == sort ? "checkmark" : "")
                    }
                }
            } label: {
                Image(systemName: session.sortAscending ? "arrow.up.arrow.down" : "arrow.down.arrow.up")
            }
            .menuStyle(.button)
            .help("Sort library")
            .accessibilityLabel("Sort Library")

            Spacer(minLength: AppTheme.Spacing.xs)

            Button {
                session.aiOnly.toggle()
            } label: {
                Label("AI", systemImage: "sparkles")
            }
            .buttonStyle(.capsule(session.aiOnly ? .prominent : .secondary))
            .help(session.aiOnly ? "Show all sources" : "Show AI-generated sources only")
        }
        .controlSize(.small)
    }

    private func tabStrip(session: MediaLibrarySession) -> some View {
        HStack(spacing: AppTheme.Spacing.none) {
            ForEach(MentionTab.allCases, id: \.self) { t in
                Text(t.label)
                    .interfaceFont(
                        size: AppTheme.Typography.ui,
                        weight: isSelected(t, session: session)
                            ? AppTheme.FontWeight.semibold
                            : AppTheme.FontWeight.regular
                    )
                    .foregroundStyle(isSelected(t, session: session) ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                    .background(
                        isSelected(t, session: session) ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted) : AppTheme.Background.clearColor,
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    )
                    .background {
                        if WorkspaceUIAcceptance.isRequested {
                            AppRelaunchClickProbe(
                                identifier: "mediaPicker.\(purpose.accessibilitySuffix).filter.\(t.label.lowercased())",
                                acceptanceState: isSelected(t, session: session)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        session.filterTypes = t.clipType.map { Set([$0]) } ?? []
                    }
            }
        }
    }

    private func isSelected(_ tab: MentionTab, session: MediaLibrarySession) -> Bool {
        if let clipType = tab.clipType { return session.filterTypes == Set([clipType]) }
        return session.filterTypes.isEmpty
    }
}
