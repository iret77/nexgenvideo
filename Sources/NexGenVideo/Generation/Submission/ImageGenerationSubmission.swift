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
        preparedParameters: PreparedProviderParameters? = nil,
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
            preparedParameters: preparedParameters,
            snapshotRefs: { input, uploaded in
                let referenceCount = input.imageURLAssetIds?.count ?? uploaded.count
                let primary = Array(uploaded.prefix(referenceCount))
                input.imageURLs = primary.isEmpty ? nil : primary
                input.imageMaskURL = uploaded.count > referenceCount
                    ? uploaded[referenceCount]
                    : nil
            },
            fileExtension: Self.fileExtension(for: genInput.imageOutputFormat),
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
        referenceAssetIDs: [String]? = nil,
        mask: MediaAsset? = nil,
        name: String? = nil,
        numImages: Int = 1,
        folderId: String? = nil
    ) -> ImageGenerationSubmission {
        var genInput = baseInput
        let assetIDs = referenceAssetIDs ?? references.map(\.id)
        genInput.imageURLAssetIds = assetIDs.isEmpty ? nil : assetIDs
        genInput.imageMaskAssetId = mask?.id
        let referenceCount = references.count
        return ImageGenerationSubmission(
            genInput: genInput,
            references: references + [mask].compactMap { $0 },
            name: name,
            numImages: numImages,
            folderId: folderId,
            buildParams: { uploaded in
                .image(ImageGenerationParams(
                    prompt: genInput.prompt,
                    aspectRatio: genInput.aspectRatio,
                    resolution: genInput.resolution,
                    quality: genInput.quality,
                    imageURLs: Array(uploaded.prefix(referenceCount)),
                    numImages: numImages,
                    maskURL: uploaded.count > referenceCount ? uploaded[referenceCount] : nil,
                    background: genInput.imageBackground,
                    outputFormat: genInput.imageOutputFormat,
                    outputCompression: genInput.imageOutputCompression
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
                    numImages: 1,
                    background: genInput.imageBackground,
                    outputFormat: genInput.imageOutputFormat,
                    outputCompression: genInput.imageOutputCompression
                ))
            }
        )
    }

    private static func fileExtension(for outputFormat: String?) -> String {
        switch outputFormat {
        case "png": "png"
        case "webp": "webp"
        default: "jpg"
        }
    }
}
