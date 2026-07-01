import Foundation

// Marble (World Labs) world-model catalog. Marble turns a reference image +
// geometric text prompt into a 3D world and returns several assets: an
// equirectangular panorama (PNG), a collider mesh (GLB), a thumbnail (WebP) and
// Gaussian splats (SPZ). Of these only the panorama maps onto an existing
// nexgen asset type, so the model registers as an *image* model whose result is
// the panorama URL. Mesh / splats / POV extraction (the numpy/py360convert path
// in the old scene3d module) are intentionally out of scope here — see
// MarbleOutput for where the other URLs surface.
//
// The model id is namespaced under `marble/` so GenerationService can detect a
// Marble model and route it through MarbleClient instead of the fal queue.

struct MarbleModel: Sendable {
    let entry: CatalogEntry
    let model: String   // Marble `model` field, e.g. "marble-1.1"
}

enum MarbleModelRegistry {
    static let idPrefix = "marble/"

    static func isMarbleModel(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    static let models: [MarbleModel] = [
        world("marble/marble-1.1", "Marble 1.1 (3D World)", model: "marble-1.1"),
    ]

    static let entries: [CatalogEntry] = models.map(\.entry)

    private static let byId: [String: MarbleModel] =
        Dictionary(models.map { ($0.entry.id, $0) }, uniquingKeysWith: { a, _ in a })

    static func model(for id: String) -> MarbleModel? { byId[id] }

    private static func world(_ id: String, _ name: String, model: String) -> MarbleModel {
        MarbleModel(
            entry: CatalogEntry(
                id: id, kind: .image, displayName: name,
                allowedEndpoints: [id], responseShape: .images,
                uiCapabilities: .image(ImageCaps(
                    // Marble derives geometry/aspect from the reference image; it
                    // takes no size/aspect param and returns a single panorama.
                    resolutions: nil, aspectRatios: [], qualities: nil,
                    supportsImageReference: true, maxImages: 1
                ))
            ),
            model: model
        )
    }
}
