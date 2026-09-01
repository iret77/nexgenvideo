import Foundation

/// Shared video generation submission assembly for UI and agent entry points.
struct VideoGenerationSubmission {
    let genInput: GenerationInput
    let placeholderDuration: Double
    let references: [MediaAsset]
    let trimmedSourceOverride: TrimmedSource?
    let name: String?
    let folderId: String?
    let buildParams: ([String]) -> BackendGenerationParams
    let snapshotRefs: (@Sendable (inout GenerationInput, [String]) -> Void)?
    let preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)?
    let resolvedVideoCapabilities: ResolvedVideoOfferingCapabilitiesV1

    var inputPolicy: ProviderProductionInputPolicyV1 {
        resolvedVideoCapabilities.inputPolicy
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
            assetType: .video,
            placeholderDuration: placeholderDuration,
            references: references,
            trimmedSourceOverride: trimmedSourceOverride,
            name: name,
            folderId: folderId,
            buildParams: buildParams,
            snapshotRefs: snapshotRefs,
            preprocessRef: preprocessRef,
            resolvedVideoCapabilities: resolvedVideoCapabilities,
            fileExtension: "mp4",
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
        model: VideoModelConfig,
        offeringCapabilities: ResolvedVideoOfferingCapabilitiesV1,
        inputAssets: InputAssets = InputAssets(),
        placeholderDuration: Double,
        trimmedSourceOverride: TrimmedSource? = nil,
        name: String? = nil,
        folderId: String? = nil,
        generateAudio: Bool
    ) -> VideoGenerationSubmission {
        var genInput = baseInput
        let inputPolicy = offeringCapabilities.inputPolicy
        genInput.generateAudio = generateAudio
        if inputPolicy.requiresSourceVideo {
            let references = inputAssets.editReferences
            genInput.imageURLAssetIds = assetIds(references)
            genInput.sourceVideoAssetId = inputAssets.sourceVideo?.id
            genInput.referenceImageAssetIds = assetIds(inputAssets.imageRefs)

            return VideoGenerationSubmission(
                genInput: genInput,
                placeholderDuration: placeholderDuration,
                references: references,
                trimmedSourceOverride: trimmedSourceOverride,
                name: name,
                folderId: folderId,
                buildParams: { uploaded in
                    .video(VideoGenerationParams(
                        prompt: genInput.prompt,
                        duration: genInput.videoDuration ?? .seconds(genInput.duration),
                        aspectRatio: genInput.aspectRatio,
                        resolution: genInput.resolution,
                        sourceVideoURL: uploaded.first,
                        startFrameURL: nil,
                        endFrameURL: nil,
                        referenceImageURLs: Array(uploaded.dropFirst()),
                        generateAudio: generateAudio
                    ))
                },
                snapshotRefs: nil,
                preprocessRef: nil,
                resolvedVideoCapabilities: offeringCapabilities
            )
        }

        let frameCount = inputAssets.frames.count
        let imageRefCount = inputAssets.imageRefs.count
        let videoRefCount = inputAssets.videoRefs.count
        let audioRefCount = inputAssets.audioRefs.count
        let references = inputAssets.textToVideoReferences
        genInput.imageURLAssetIds = assetIds(inputAssets.frames)
        genInput.startFrameAssetId = inputAssets.frames.first?.id
        genInput.endFrameAssetId = inputAssets.frames.dropFirst().first?.id
        genInput.referenceImageAssetIds = assetIds(inputAssets.imageRefs)
        genInput.referenceVideoAssetIds = assetIds(inputAssets.videoRefs)
        genInput.referenceAudioAssetIds = assetIds(inputAssets.audioRefs)

        let snapshotRefs = videoInputSnapshotter(
            frameCount: frameCount,
            imageRefCount: imageRefCount,
            videoRefCount: videoRefCount,
            audioRefCount: audioRefCount
        )
        let preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)?
        if inputAssets.videoRefs.isEmpty || genInput.productionRouting != nil {
            preprocessRef = nil
        } else {
            preprocessRef = { _, asset in
                guard asset.type == .video else { return nil }
                return try await VideoCompressor.compressIfNeeded(url: asset.url)
            }
        }

        return VideoGenerationSubmission(
            genInput: genInput,
            placeholderDuration: placeholderDuration,
            references: references,
            trimmedSourceOverride: trimmedSourceOverride,
            name: name,
            folderId: folderId,
            buildParams: { uploaded in
                let params = videoInputURLs(
                    uploaded: uploaded,
                    frameCount: frameCount,
                    imageRefCount: imageRefCount,
                    videoRefCount: videoRefCount,
                    audioRefCount: audioRefCount
                ).params(
                    prompt: genInput.prompt,
                    duration: genInput.videoDuration ?? .seconds(genInput.duration),
                    aspectRatio: genInput.aspectRatio,
                    resolution: genInput.resolution,
                    generateAudio: generateAudio
                )
                return .video(params)
            },
            snapshotRefs: snapshotRefs,
            preprocessRef: preprocessRef,
            resolvedVideoCapabilities: offeringCapabilities
        )
    }

    struct InputAssets {
        var sourceVideo: MediaAsset?
        var frames: [MediaAsset] = []
        var imageRefs: [MediaAsset] = []
        var videoRefs: [MediaAsset] = []
        var audioRefs: [MediaAsset] = []

        @MainActor
        var allRefs: [MediaAsset] {
            imageRefs + videoRefs + audioRefs
        }

        @MainActor
        var textToVideoReferences: [MediaAsset] {
            frames + allRefs
        }

        @MainActor
        var editReferences: [MediaAsset] {
            (sourceVideo.map { [$0] } ?? []) + imageRefs
        }

        @MainActor
        var totalRefCount: Int {
            allRefs.count
        }

        @MainActor
        func validate(
            for model: VideoModelConfig,
            offeringCapabilities: ResolvedVideoOfferingCapabilitiesV1
        ) -> String? {
            let inputPolicy = offeringCapabilities.inputPolicy
            if inputPolicy.requiresSourceVideo {
                return validateEditReferences(
                    for: model,
                    offeringCapabilities: offeringCapabilities
                )
            }
            return validateTextToVideoReferences(
                for: model,
                offeringCapabilities: offeringCapabilities
            )
        }

        @MainActor
        private func validateEditReferences(
            for model: VideoModelConfig,
            offeringCapabilities: ResolvedVideoOfferingCapabilitiesV1
        ) -> String? {
            guard let sourceVideo else {
                return "Model '\(model.id)' requires a source video."
            }
            guard sourceVideo.type == .video else {
                return "sourceVideoMediaRef must reference a video asset"
            }
            if !frames.isEmpty || !videoRefs.isEmpty || !audioRefs.isEmpty {
                return "\(model.displayName) only accepts a source video and image references"
            }
            if !offeringCapabilities.supportsReferences, !imageRefs.isEmpty {
                return "\(model.displayName) does not accept image references"
            }
            if offeringCapabilities.requiresReferenceImage, imageRefs.isEmpty {
                return "\(model.displayName) requires an image reference"
            }
            if imageRefs.count > offeringCapabilities.maxReferenceImages {
                return "\(model.displayName) accepts at most \(offeringCapabilities.maxReferenceImages) image reference(s)"
            }
            if let totalCap = offeringCapabilities.maxTotalReferences,
               imageRefs.count > totalCap {
                return "\(model.displayName) accepts at most \(totalCap) references total"
            }
            return validateTypes([
                (imageRefs, .image, "referenceImageMediaRefs")
            ])
        }

        @MainActor
        private func validateTextToVideoReferences(
            for model: VideoModelConfig,
            offeringCapabilities: ResolvedVideoOfferingCapabilitiesV1
        ) -> String? {
            let inputPolicy = offeringCapabilities.inputPolicy
            let framesInImageLimit = inputPolicy.framesCountTowardImageReferenceLimit
                ? frames.count : 0
            let framesInTotalLimit = inputPolicy.framesCountTowardTotalReferenceLimit
                ? frames.count : 0
            let imageLimit = offeringCapabilities.maxReferenceImages(
                hasVideoReference: !videoRefs.isEmpty
            )
            if sourceVideo != nil {
                return "\(model.displayName) does not accept a source video"
            }
            if frames.count > 2 {
                return "\(model.displayName) accepts at most 2 frame references"
            }
            if !frames.isEmpty, !offeringCapabilities.supportsFirstFrame {
                return "\(model.displayName) does not accept frame references"
            }
            if frames.count > 1, !offeringCapabilities.supportsLastFrame {
                return "\(model.displayName) does not accept a last frame"
            }
            if offeringCapabilities.requiresReferenceImage,
               frames.isEmpty,
               imageRefs.isEmpty {
                return "\(model.displayName) requires a start frame"
            }
            if offeringCapabilities.framesAndReferencesExclusive,
               !frames.isEmpty,
               !allRefs.isEmpty {
                return "\(model.displayName) uses frames OR references, not both. Clear one side."
            }
            if imageRefs.count + framesInImageLimit > imageLimit {
                let inputName = framesInImageLimit > 0
                    ? "image inputs including frame references"
                    : "image references"
                return "\(model.displayName) accepts at most \(imageLimit) \(inputName)"
            }
            if videoRefs.count > offeringCapabilities.maxReferenceVideos {
                return "\(model.displayName) accepts at most \(offeringCapabilities.maxReferenceVideos) video references"
            }
            if audioRefs.count > offeringCapabilities.maxReferenceAudios {
                return "\(model.displayName) accepts at most \(offeringCapabilities.maxReferenceAudios) audio references"
            }
            if let totalCap = offeringCapabilities.maxTotalReferences,
               totalRefCount + framesInTotalLimit > totalCap {
                return "\(model.displayName) accepts at most \(totalCap) references total"
            }
            if let cap = offeringCapabilities.maxCombinedVideoReferenceSeconds,
               videoRefs.reduce(0, { $0 + $1.duration }) > cap {
                return "Combined video reference duration exceeds \(Int(cap))s"
            }
            if let cap = offeringCapabilities.maxCombinedAudioReferenceSeconds,
               audioRefs.reduce(0, { $0 + $1.duration }) > cap {
                return "Combined audio reference duration exceeds \(Int(cap))s"
            }
            return validateTypes([
                (frames, .image, "frame references"),
                (imageRefs, .image, "referenceImageMediaRefs"),
                (videoRefs, .video, "referenceVideoMediaRefs"),
                (audioRefs, .audio, "referenceAudioMediaRefs")
            ])
        }

        @MainActor
        private func validateTypes(_ groups: [([MediaAsset], ClipType, String)]) -> String? {
            for (assets, expected, label) in groups {
                for asset in assets where asset.type != expected {
                    return "\(label) entry '\(asset.id)' must be a \(expected.rawValue) asset"
                }
            }
            return nil
        }
    }

    private struct UploadedInputURLs: Sendable {
        let frames: [String]
        let imageRefs: [String]
        let videoRefs: [String]
        let audioRefs: [String]

        func apply(to input: inout GenerationInput) {
            input.imageURLs = frames.isEmpty ? nil : frames
            input.referenceImageURLs = imageRefs.isEmpty ? nil : imageRefs
            input.referenceVideoURLs = videoRefs.isEmpty ? nil : videoRefs
            input.referenceAudioURLs = audioRefs.isEmpty ? nil : audioRefs
        }

        func params(
            prompt: String,
            duration: VideoDuration,
            aspectRatio: String,
            resolution: String?,
            generateAudio: Bool
        ) -> VideoGenerationParams {
            VideoGenerationParams(
                prompt: prompt,
                duration: duration,
                aspectRatio: aspectRatio,
                resolution: resolution,
                sourceVideoURL: nil,
                startFrameURL: frames.first,
                endFrameURL: frames.count > 1 ? frames[1] : nil,
                referenceImageURLs: imageRefs,
                referenceVideoURLs: videoRefs,
                referenceAudioURLs: audioRefs,
                generateAudio: generateAudio
            )
        }
    }

    private static func videoInputURLs(
        uploaded: [String],
        frameCount: Int,
        imageRefCount: Int,
        videoRefCount: Int,
        audioRefCount: Int
    ) -> UploadedInputURLs {
        let frames = Array(uploaded.prefix(frameCount))
        let rest = Array(uploaded.dropFirst(frameCount))
        return UploadedInputURLs(
            frames: frames,
            imageRefs: imageRefCount > 0 ? Array(rest.prefix(imageRefCount)) : [],
            videoRefs: videoRefCount > 0 ? Array(rest.dropFirst(imageRefCount).prefix(videoRefCount)) : [],
            audioRefs: audioRefCount > 0
                ? Array(rest.dropFirst(imageRefCount + videoRefCount).prefix(audioRefCount))
                : []
        )
    }

    private static func videoInputSnapshotter(
        frameCount: Int,
        imageRefCount: Int,
        videoRefCount: Int,
        audioRefCount: Int
    ) -> @Sendable (inout GenerationInput, [String]) -> Void {
        { input, uploaded in
            videoInputURLs(
                uploaded: uploaded,
                frameCount: frameCount,
                imageRefCount: imageRefCount,
                videoRefCount: videoRefCount,
                audioRefCount: audioRefCount
            ).apply(to: &input)
        }
    }

    @MainActor
    private static func assetIds(_ assets: [MediaAsset]) -> [String]? {
        assets.isEmpty ? nil : assets.map(\.id)
    }
}
