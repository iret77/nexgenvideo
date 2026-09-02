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
        let persistedPrimaryIDs = gen.imageURLAssetIds ?? []
        let primaryIDs: [String]
        if let sourceID = gen.sourceVideoAssetId,
           gen.referenceImageAssetIds != nil {
            primaryIDs = [sourceID]
        } else {
            primaryIDs = persistedPrimaryIDs
        }
        let primary = primaryLabels(
            for: gen,
            primaryIDs: primaryIDs,
            assetsByID: byId
        )
        let videoBase = videoReferenceBaseLabel(for: gen)
        let groups: [(ids: [String]?, base: String, primary: [String])] = [
            (primaryIDs,                 "Reference", primary),
            (gen.referenceImageAssetIds, "Image Ref", []),
            (gen.referenceVideoAssetIds, videoBase, []),
            (gen.referenceAudioAssetIds, "Audio Ref", []),
        ]
        return groups.flatMap { ids, base, primary -> [(String, MediaAsset)] in
            let ids = ids ?? []
            return ids.enumerated().compactMap { i, id in
                guard let asset = byId[id] else { return nil }
                if i < primary.count { return (primary[i], asset) }
                return (ids.count > 1 ? "\(base) \(i + 1)" : base, asset)
            }
        }
    }

    private static func videoReferenceBaseLabel(for gen: GenerationInput) -> String {
        if case .audio(let model) = ModelRegistry.byId[gen.model],
           model.inputs.contains(.video) {
            return "Source Video"
        }
        return "Video Ref"
    }

    private static func primaryLabels(
        for gen: GenerationInput,
        primaryIDs: [String],
        assetsByID: [String: MediaAsset]
    ) -> [String] {
        if gen.sourceVideoAssetId != nil {
            return primaryIDs.indices.map { $0 == 0 ? "Source" : "Reference" }
        }
        if gen.startFrameAssetId != nil || gen.endFrameAssetId != nil {
            return (gen.startFrameAssetId == nil ? [] : ["First Frame"])
                + (gen.endFrameAssetId == nil ? [] : ["Last Frame"])
        }
        switch ModelRegistry.byId[gen.model] {
        case .video:
            let legacySource = primaryIDs.first.flatMap { assetsByID[$0] }?.type == .video
            guard let capabilities = GenerationService.dispatchTarget(
                modelId: gen.model,
                requiringSourceVideo: legacySource
            ).binding?.resolvedVideoCapabilities else { return [] }
            if capabilities.inputPolicy.requiresSourceVideo {
                return primaryIDs.indices.map { $0 == 0 ? "Source" : "Reference" }
            }
            if capabilities.supportsFirstFrame {
                return capabilities.supportsLastFrame
                    ? ["First Frame", "Last Frame"] : ["First Frame"]
            }
            return []
        case .upscale:
            return ["Source"]
        default:
            return []
        }
    }

    private func thumbnail(label: String, asset: MediaAsset) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ZStack {
                Rectangle().fill(AppTheme.Background.overlayColor)
                if let thumb = asset.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: asset.type.sfSymbolName)
                        .font(.system(size: AppTheme.FontSize.mdLg))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .frame(width: AppTheme.ComponentSize.generationReferenceWidth, height: AppTheme.ComponentSize.generationReferenceHeight)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.faint), lineWidth: AppTheme.BorderWidth.hairline))
            Text(label)
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .lineLimit(1)
        }
        .help("\(label) · \(asset.name)")
        .onTapGesture {
            editor.selectMediaAsset(asset)
            editor.mediaPanelRevealAssetId = asset.id
        }
    }
}
