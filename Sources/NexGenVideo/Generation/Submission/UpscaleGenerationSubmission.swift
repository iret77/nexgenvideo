import Foundation

struct UpscaleGenerationSubmission {
    let genInput: GenerationInput
    let source: MediaAsset
    let trimmedSource: TrimmedSource?
    let placeholderDuration: Double
    let name: String
    let folderID: String?
    let targetResolution: String?
    let scaleFactor: Int?

    @MainActor
    func parameters(_ sourceURL: String) -> BackendGenerationParams {
        .upscale(.init(sourceURL: sourceURL, durationSeconds: source.type == .image ? 1 : genInput.duration,
            targetResolution: targetResolution, scaleFactor: scaleFactor))
    }

    @MainActor
    func submit(service: GenerationService, projectURL: URL?, editor: EditorViewModel,
                authorization: GenerationAuthorization, preparedParameters: PreparedProviderParameters,
                onComplete: (@MainActor (MediaAsset) -> Void)?, onFailure: (@MainActor () -> Void)?) -> String {
        let sourceID = source.id, sourceType = source.type
        return service.generate(genInput: genInput, assetType: source.type, placeholderDuration: placeholderDuration,
            references: [source], trimmedSourceOverride: trimmedSource, name: name, folderId: folderID,
            buildParams: { parameters($0.first ?? "") }, preparedParameters: preparedParameters,
            snapshotRefs: { input, urls in
                EditSubmitter.recordUpscaleProvenance(in: &input, uploadedURLs: urls,
                    sourceAssetID: sourceID, sourceType: sourceType)
            }, fileExtension: source.type == .image ? "jpg" : "mp4", projectURL: projectURL,
            editor: editor, authorization: authorization, onComplete: onComplete, onFailure: onFailure)
    }
}
