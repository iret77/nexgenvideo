import SwiftUI

struct GenerationReferencesStrip: View {
    let generationInput: GenerationInput
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        let slots = Self.slots(for: generationInput, in: editor.mediaAssets)
        if !slots.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    ForEach(slots.indices, id: \.self) { i in
                        thumbnail(label: slots[i].0, asset: slots[i].1)
                    }
                }
            }
        }
    }

    static func hasResolvableReferences(_ gen: GenerationInput, in assets: [MediaAsset]) -> Bool {
        !slots(for: gen, in: assets).isEmpty
    }

    static func slots(for gen: GenerationInput, in assets: [MediaAsset]) -> [(String, MediaAsset)] {
        let byId = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var recorded: [(String, String)] = []
        if let source = gen.sourceVideoAssetId { recorded.append(("Source", source)) }
        if let first = gen.startFrameAssetId { recorded.append(("First Frame", first)) }
        if let last = gen.endFrameAssetId { recorded.append(("Last Frame", last)) }
        let explicitIDs = Set(recorded.map(\.1))
        let groupedImageIDs = Set(gen.referenceImageAssetIds ?? [])
        let primaryIDs = (gen.imageURLAssetIds ?? []).filter {
            !explicitIDs.contains($0) && !groupedImageIDs.contains($0)
        }
        let groups: [(ids: [String], label: String)] = [
            (primaryIDs, "Reference"),
            (gen.referenceImageAssetIds ?? [], "Image Ref"),
            (gen.referenceVideoAssetIds ?? [], "Video Ref"),
            (gen.referenceAudioAssetIds ?? [], "Audio Ref"),
        ]
        for group in groups {
            recorded += group.ids.enumerated().map { index, id in
                (group.ids.count > 1 ? "\(group.label) \(index + 1)" : group.label, id)
            }
        }
        return recorded.compactMap { label, id in byId[id].map { (label, $0) } }
    }

    private func thumbnail(label: String, asset: MediaAsset) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ZStack {
                Rectangle().fill(AppTheme.Background.overlayColor)
                if let thumb = asset.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: asset.type.sfSymbolName)
                        .interfaceFont(size: AppTheme.Typography.reading)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .frame(width: AppTheme.ComponentSize.generationReferenceWidth, height: AppTheme.ComponentSize.generationReferenceHeight)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.faint), lineWidth: AppTheme.BorderWidth.hairline))
            Text(label)
                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.mutedColor)
                .lineLimit(1)
        }
        .help("\(label) · \(asset.libraryDisplayName)")
        .onTapGesture {
            editor.selectMediaAsset(asset)
            editor.mediaPanelRevealAssetId = asset.id
        }
    }
}
