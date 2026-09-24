import AVFoundation
import SwiftUI

extension MediaTab {
    var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var searchResults: some View {
        let nameMatches = searchScope == .filename ? sortAndFilter(editor.mediaAssets) : []
        let visibleVisualHits = visualHits.filter(hitPassesFilters)
        let visibleSpokenHits = spokenHits.filter(hitPassesFilters)
        let visibleDocumentHits = documentHits.filter(hitPassesFilters)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
                if !visibleVisualHits.isEmpty {
                    momentHeader("Moments", icon: "sparkle.magnifyingglass", count: visibleVisualHits.count, collapsible: true)
                    if !collapsedSearchSections.contains("Moments") {
                        resultsGrid { ForEach(visibleVisualHits.indices, id: \.self) { momentCard(visibleVisualHits[$0]) } }
                    }
                }
                if !visibleSpokenHits.isEmpty {
                    momentHeader("Transcript", icon: "waveform", count: visibleSpokenHits.count, collapsible: true)
                    if !collapsedSearchSections.contains("Transcript") {
                        VStack(spacing: AppTheme.Spacing.sm) {
                            ForEach(visibleSpokenHits.indices, id: \.self) { spokenRow(visibleSpokenHits[$0]) }
                        }
                        .padding(.bottom, AppTheme.Spacing.sm)
                    }
                }
                if !visibleDocumentHits.isEmpty {
                    momentHeader("Text Content", icon: "doc.text.magnifyingglass", count: visibleDocumentHits.count)
                    VStack(spacing: AppTheme.Spacing.sm) {
                        ForEach(visibleDocumentHits) { documentRow($0) }
                    }
                    .padding(.bottom, AppTheme.Spacing.sm)
                }
                if !nameMatches.isEmpty {
                    momentHeader("Files", icon: "doc", count: nameMatches.count)
                    resultsGrid { ForEach(nameMatches) { fileCard($0) } }
                }
                if visibleVisualHits.isEmpty,
                   visibleSpokenHits.isEmpty,
                   visibleDocumentHits.isEmpty,
                   nameMatches.isEmpty {
                    Text("No matches for “\(trimmedSearchQuery)”")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(maxWidth: .infinity)
                        .padding(.top, AppTheme.Spacing.xl)
                }
            }
            .padding(.top, AppTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hitPassesFilters(_ hit: VisualSearch.Hit) -> Bool {
        editor.mediaAssets.first(where: { $0.id == hit.assetID }).map(passesFilters) ?? false
    }

    private func hitPassesFilters(_ hit: TranscriptSearch.Hit) -> Bool {
        editor.mediaAssets.first(where: { $0.id == hit.assetID }).map(passesFilters) ?? false
    }

    private func hitPassesFilters(_ hit: DocumentSearch.Hit) -> Bool {
        editor.mediaAssets.first(where: { $0.id == hit.assetID }).map(passesFilters) ?? false
    }

    private func resultsGrid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: CGFloat(thumbnailSize) * 1.4), spacing: AppTheme.Spacing.sm)],
            alignment: .leading,
            spacing: AppTheme.Spacing.md,
            content: content
        )
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.bottom, AppTheme.Spacing.md)
    }

    private func momentHeader(_ title: String, icon: String, count: Int, collapsible: Bool = false) -> some View {
        let isCollapsed = collapsedSearchSections.contains(title)
        return Button {
            guard collapsible else { return }
            withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                if isCollapsed { collapsedSearchSections.remove(title) }
                else { collapsedSearchSections.insert(title) }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                if collapsible {
                    Image(systemName: "chevron.down")
                        .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }
                Image(systemName: icon)
                    .interfaceFont(size: AppTheme.Typography.ui)
                Text(title)
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                Text("\(count)")
                    .interfaceFont(size: AppTheme.Typography.ui).monospacedDigit()
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Spacer()
            }
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!collapsible)
    }

    // MARK: - Rows

    private func momentCard(_ hit: VisualSearch.Hit) -> some View {
        let asset = editor.mediaAssets.first { $0.id == hit.assetID }
        let isImage = asset?.type == .image
        let range = hit.shotStart...max(hit.shotEnd, hit.shotStart + 0.1)
        // Stills drag as plain assets; a source segment is meaningless for them.
        let payload = isImage
            ? MediaTab.assetDragString(forAssetId: hit.assetID)
            : MediaTab.assetDragString(forAssetId: hit.assetID, segment: range)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            momentThumb(asset, time: hit.time)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            Text(asset?.libraryDisplayName ?? "")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
            if !isImage {
                Text("\(timecode(range.lowerBound))–\(timecode(range.upperBound))")
                    .interfaceFont(size: AppTheme.Typography.metadata).monospacedDigit()
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .draggable(payload) {
            momentThumb(asset, time: hit.time)
                .frame(width: AppTheme.ComponentSize.searchThumbnailWidth, height: AppTheme.ComponentSize.searchThumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        }
        .onTapGesture { previewMoment(assetID: hit.assetID, atSeconds: range.lowerBound) }
    }

    @ViewBuilder
    private func momentThumb(_ asset: MediaAsset?, time: Double) -> some View {
        if asset?.type == .image {
            ZStack {
                Rectangle().fill(AppTheme.Background.overlayColor)
                if let thumb = asset?.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
        } else {
            MomentThumbnail(url: asset?.url, time: time)
        }
    }

    private func spokenRow(_ hit: TranscriptSearch.Hit) -> some View {
        let asset = editor.mediaAssets.first { $0.id == hit.assetID }
        let range = hit.start...max(hit.end, hit.start + 0.1)
        let thumbW = CGFloat(thumbnailSize) * 1.4
        return HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            MomentThumbnail(url: asset?.url, time: hit.start)
                .frame(width: thumbW, height: thumbW * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(hit.text)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(3)
                Text("\(asset?.libraryDisplayName ?? "") · \(timecode(hit.start))")
                    .interfaceFont(size: AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .contentShape(Rectangle())
        .draggable(MediaTab.assetDragString(forAssetId: hit.assetID, segment: range)) {
            MomentThumbnail(url: asset?.url, time: hit.start)
                .frame(width: AppTheme.ComponentSize.searchThumbnailWidth, height: AppTheme.ComponentSize.searchThumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        }
        .onTapGesture { previewMoment(assetID: hit.assetID, atSeconds: range.lowerBound) }
    }

    private func fileCard(_ asset: MediaAsset) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            ZStack {
                Rectangle().fill(AppTheme.Background.overlayColor)
                if let thumb = asset.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: asset.type.sfSymbolName)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            Text(asset.libraryDisplayName)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
        }
        .draggable(dragPayload(for: asset)) { dragPreview(for: asset) }
        .onTapGesture { editor.selectMediaAsset(asset, for: mediaPurpose) }
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(identifier: "media.search.asset.\(asset.id)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func documentRow(_ hit: DocumentSearch.Hit) -> some View {
        let asset = editor.mediaAssets.first { $0.id == hit.assetID }
        return Button {
            guard let asset else { return }
            editor.selectMediaAsset(asset, for: mediaPurpose)
        } label: {
            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                Image(systemName: "doc.text")
                    .interfaceFont(size: AppTheme.Typography.title)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.ComponentSize.searchThumbnailWidth)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(hit.snippet)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(3)
                    Text(asset?.libraryDisplayName ?? "")
                        .interfaceFont(size: AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                }
                Spacer(minLength: AppTheme.Spacing.none)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
    }

    private func previewMoment(assetID: String, atSeconds seconds: Double) {
        guard let asset = editor.mediaAssets.first(where: { $0.id == assetID }) else { return }
        editor.selectMediaAsset(asset, for: mediaPurpose)
        editor.seekSourceToFrame(secondsToFrame(seconds: seconds, fps: editor.timeline.fps))
    }

    private func timecode(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Query execution

    func scheduleMomentSearch() {
        momentSearchTask?.cancel()
        let query = trimmedSearchQuery
        guard !query.isEmpty else {
            visualHits = []
            spokenHits = []
            documentHits = []
            return
        }
        switch searchScope {
        case .filename:
            visualHits = []
            spokenHits = []
            documentHits = []
            return
        case .content:
            spokenHits = []
        case .transcript:
            visualHits = []
            documentHits = []
        }
        let scope = searchScope
        let matchingAssets = editor.mediaAssets.filter(passesFilters)
        let timedAssets = matchingAssets
            .filter { $0.type == .video || $0.type == .audio }
            .map { (id: $0.id, url: $0.url) }
        let documents = matchingAssets
            .filter { $0.type == .document }
            .map { (id: $0.id, url: $0.url) }
        let allowedIDs = Set(matchingAssets.map(\.id))
        let coordinator = editor.searchIndex
        momentSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let spoken: [TranscriptSearch.Hit]
            let visual: [VisualSearch.Hit]
            let text: [DocumentSearch.Hit]
            switch scope {
            case .filename:
                spoken = []
                visual = []
                text = []
            case .content:
                spoken = []
                visual = await coordinator.search(query: query).filter { allowedIDs.contains($0.assetID) }
                text = await DocumentSearch.search(query: query, assets: documents)
            case .transcript:
                spoken = TranscriptSearch.search(query: query, assets: timedAssets)
                visual = []
                text = []
            }
            guard !Task.isCancelled else { return }
            visualHits = visual
            spokenHits = spoken
            documentHits = text
        }
    }
}

enum DocumentSearch {
    struct Hit: Identifiable, Sendable {
        let assetID: String
        let snippet: String
        var id: String { assetID }
    }

    private static let maximumBytes = 2_000_000
    private static let snippetRadius = 96

    nonisolated static func search(
        query: String,
        assets: [(id: String, url: URL)]
    ) async -> [Hit] {
        let worker = Task.detached(priority: .userInitiated) {
            var hits: [Hit] = []
            for asset in assets {
                guard !Task.isCancelled else { return hits }
                guard let read = try? BoundedTextFileReader.readUTF8Prefix(
                    from: asset.url,
                    maximumBytes: maximumBytes
                ), let match = read.text.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) else { continue }
                let text = read.text
                let lower = text.index(match.lowerBound, offsetBy: -snippetRadius, limitedBy: text.startIndex)
                    ?? text.startIndex
                let upper = text.index(match.upperBound, offsetBy: snippetRadius, limitedBy: text.endIndex)
                    ?? text.endIndex
                let snippet = text[lower..<upper]
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                hits.append(Hit(assetID: asset.id, snippet: snippet))
            }
            return hits
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

/// Async frame thumbnail for a search hit.
private struct MomentThumbnail: View {
    let url: URL?
    let time: Double
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(AppTheme.Background.overlayColor)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .task(id: "\(url?.path ?? "")@\(time)") {
            guard let url else { return }
            image = await Self.thumbnail(url: url, time: time)
        }
    }

    private static func thumbnail(url: URL, time: Double) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        return try? await generator.image(at: cmTime).image
    }
}
