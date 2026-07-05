import Foundation

// Higgsfield catalog. Ids are namespaced under `higgsfield/` so GenerationService routes them
// through HiggsfieldClient on the user's Higgsfield key. DoP is image-to-video (camera-motion):
// the input image is a required reference; the API takes no duration/aspect parameters (input
// schema verified against the official SDK types — DoPImage2VideoInput). Soul (text-to-image)
// is deferred until its width_and_height format is verified.

struct HiggsfieldModel: Sendable {
    let entry: CatalogEntry
    let apiModel: String   // DoP `model` field: dop-lite | dop-turbo | dop-standard
}

enum HiggsfieldModelRegistry {
    static let idPrefix = "higgsfield/"

    static func isHiggsfieldModel(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    static let models: [HiggsfieldModel] = [
        dop("higgsfield/dop-turbo", "Higgsfield DoP Turbo (image)", apiModel: "dop-turbo"),
        dop("higgsfield/dop-standard", "Higgsfield DoP (image)", apiModel: "dop-standard"),
    ]

    static let entries: [CatalogEntry] = models.map(\.entry)

    private static let byId: [String: HiggsfieldModel] =
        Dictionary(models.map { ($0.entry.id, $0) }, uniquingKeysWith: { a, _ in a })

    static func model(for id: String) -> HiggsfieldModel? { byId[id] }

    private static func dop(_ id: String, _ name: String, apiModel: String) -> HiggsfieldModel {
        HiggsfieldModel(
            entry: CatalogEntry(
                id: id, kind: .video, displayName: name,
                allowedEndpoints: [id], responseShape: .video,
                uiCapabilities: .video(VideoCaps(
                    // DoP takes no duration/aspect params — output follows the input image;
                    // ~5s clips. The single duration keeps the UI honest about that.
                    durations: [5], resolutions: nil,
                    aspectRatios: ["16:9", "9:16"],
                    supportsFirstFrame: false, supportsLastFrame: false,
                    maxReferenceImages: 1, maxReferenceVideos: 0, maxReferenceAudios: 0,
                    maxTotalReferences: 1,
                    maxCombinedVideoRefSeconds: nil, maxCombinedAudioRefSeconds: nil,
                    framesAndReferencesExclusive: false, referenceTagNoun: "image",
                    requiresSourceVideo: false, requiresReferenceImage: true
                ))
            ),
            apiModel: apiModel
        )
    }
}
