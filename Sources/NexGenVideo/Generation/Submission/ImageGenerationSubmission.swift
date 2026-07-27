import Foundation

struct ImageGenerationSubmission {
    let genInput: GenerationInput
    let references: [MediaAsset]
    let name: String?
    let numImages: Int
    let folderId: String?
    // Marble reads its reference image as base64 from a local file rather than a
    // fal-hosted URL, so it pre-fills the reference path(s) to skip fal upload.
    let preUploadedURLs: [String]?
    let buildParams: ([String]) -> BackendGenerationParams

    init(
        genInput: GenerationInput,
        references: [MediaAsset],
        name: String?,
        numImages: Int,
        folderId: String?,
        preUploadedURLs: [String]? = nil,
        buildParams: @escaping ([String]) -> BackendGenerationParams
    ) {
        self.genInput = genInput
        self.references = references
        self.name = name
        self.numImages = numImages
        self.folderId = folderId
        self.preUploadedURLs = preUploadedURLs
        self.buildParams = buildParams
    }

    @MainActor
    @discardableResult
    func submit(
        service: GenerationService,
        projectURL: URL?,
        editor: EditorViewModel,
        authorization: GenerationAuthorization,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        service.generate(
            genInput: genInput,
            assetType: .image,
            placeholderDuration: Defaults.imageDurationSeconds,
            references: references,
            preUploadedURLs: preUploadedURLs,
            name: name,
            numImages: numImages,
            folderId: folderId,
            buildParams: buildParams,
            fileExtension: "jpg",
            projectURL: projectURL,
            editor: editor,
            authorization: authorization,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    @MainActor
    static func make(
        genInput baseInput: GenerationInput,
        model: ImageModelConfig,
        references: [MediaAsset],
        name: String? = nil,
        numImages: Int = 1,
        folderId: String? = nil
    ) -> ImageGenerationSubmission {
        var genInput = baseInput
        genInput.imageURLAssetIds = references.isEmpty ? nil : references.map(\.id)
        return ImageGenerationSubmission(
            genInput: genInput,
            references: references,
            name: name,
            numImages: numImages,
            folderId: folderId,
            buildParams: { uploaded in
                .image(ImageGenerationParams(
                    prompt: genInput.prompt,
                    aspectRatio: genInput.aspectRatio,
                    resolution: genInput.resolution,
                    quality: genInput.quality,
                    imageURLs: uploaded,
                    numImages: numImages
                ))
            }
        )
    }

    /// Marble submission: the reference image stays a local file (Marble reads
    /// it as base64), so the local path is passed as a pre-uploaded URL to skip
    /// fal upload, and that same path rides through `imageURLs`.
    @MainActor
    static func makeMarble(
        genInput baseInput: GenerationInput,
        model: ImageModelConfig,
        reference: MediaAsset,
        name: String? = nil,
        folderId: String? = nil
    ) -> ImageGenerationSubmission {
        var genInput = baseInput
        genInput.imageURLAssetIds = [reference.id]
        let localPath = reference.url.path
        return ImageGenerationSubmission(
            genInput: genInput,
            references: [reference],
            name: name,
            numImages: 1,
            folderId: folderId,
            preUploadedURLs: [localPath],
            buildParams: { uploaded in
                .image(ImageGenerationParams(
                    prompt: genInput.prompt,
                    aspectRatio: genInput.aspectRatio,
                    resolution: genInput.resolution,
                    quality: genInput.quality,
                    imageURLs: uploaded,
                    numImages: 1
                ))
            }
        )
    }
}
