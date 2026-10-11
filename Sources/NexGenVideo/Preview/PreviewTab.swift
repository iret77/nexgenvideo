import Foundation
import SwiftUI

enum PreviewTab: Identifiable, Equatable {
    case timeline
    case referenceImage(ProjectReferenceImage)
    case mediaAsset(id: String, name: String, type: ClipType)

    var id: String {
        switch self {
        case .timeline: "__timeline__"
        case .referenceImage(let image): image.id
        case .mediaAsset(let id, _, _): Self.mediaAssetTabId(for: id)
        }
    }

    static func mediaAssetTabId(for assetId: String) -> String {
        "media_\(assetId)"
    }

    var displayName: String {
        switch self {
        case .timeline: "Timeline"
        case .referenceImage(let image): image.name
        case .mediaAsset(_, let name, _): name
        }
    }

    var isCloseable: Bool { self != .timeline }

    var clipType: ClipType? {
        switch self {
        case .timeline: nil
        case .referenceImage: .image
        case .mediaAsset(_, _, let type): type
        }
    }

    var tintColor: Color {
        switch self {
        case .timeline, .referenceImage: AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted)
        case .mediaAsset(_, _, let type): Color(type.themeColor).opacity(AppTheme.Opacity.moderate)
        }
    }

    var underlineColor: Color {
        switch self {
        case .timeline, .referenceImage: AppTheme.Accent.primary
        case .mediaAsset(_, _, let type): Color(type.themeColor)
        }
    }
}
