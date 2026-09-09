import Foundation

extension GenerationPackageV1 {
    func restoreParameters() throws -> PreparedProviderParameters {
        struct Parameters: Decodable {
            let kind: String
            let prompt: String
            let aspectRatio: String
            let resolution: String?
            let quality: String?
            let imageURLs: [String]?
            let numImages: Int?
            let duration: VideoDuration?
            let sourceVideoURL: String?
            let startFrameURL: String?
            let endFrameURL: String?
            let referenceImageURLs: [String]?
            let referenceVideoURLs: [String]?
            let referenceAudioURLs: [String]?
            let generateAudio: Bool?
        }
        try validate()
        let data = Data(payload.requestParametersJSON.utf8)
        let saved = try JSONDecoder().decode(Parameters.self, from: data)
        let parameters: BackendGenerationParams
        switch saved.kind {
        case "image":
            guard let count = saved.numImages, count == payload.outputCount, payload.modality == "image" else {
                throw GenerationRequestError.gate("The saved image output count is invalid.")
            }
            parameters = .image(.init(prompt: saved.prompt, aspectRatio: saved.aspectRatio, resolution: saved.resolution,
                quality: saved.quality, imageURLs: saved.imageURLs ?? [], numImages: count))
        case "video":
            guard let duration = saved.duration, let audio = saved.generateAudio,
                  payload.modality == "video", payload.outputCount == 1 else {
                throw GenerationRequestError.gate("The saved video request is incomplete.")
            }
            parameters = .video(.init(prompt: saved.prompt, duration: duration, aspectRatio: saved.aspectRatio,
                resolution: saved.resolution, sourceVideoURL: saved.sourceVideoURL,
                startFrameURL: saved.startFrameURL, endFrameURL: saved.endFrameURL,
                referenceImageURLs: saved.referenceImageURLs ?? [], referenceVideoURLs: saved.referenceVideoURLs ?? [],
                referenceAudioURLs: saved.referenceAudioURLs ?? [], generateAudio: audio))
        default: throw GenerationRequestError.gate("This saved request has no supported visual generation operation.")
        }
        guard try Self.encode(parameters) == data, saved.prompt == payload.prompt else {
            throw GenerationRequestError.gate("The saved provider parameters cannot be restored without changing the request.")
        }
        let slots = payload.references.enumerated().map { "ngv-input://\($0.offset)/\($0.element.submittedSHA256)" }
        return try PreparedProviderParameters(parameters: parameters, referenceSlots: slots)
    }

    func restorePlacement() throws -> GenerationRequest.Placement {
        let destination = payload.destination
        switch destination.kind {
        case "media_library": return .mediaLibrary(folderId: destination.folderID)
        case "timeline":
            guard let start = destination.startFrame, start >= 0,
                  let span = destination.durationSeconds, span.isFinite, span > 0 else {
                throw GenerationRequestError.gate("The saved timeline destination is invalid.")
            }
            return .timelineAt(startFrame: start, spanSeconds: span, actionName: nil)
        case "replace_clip":
            guard let id = destination.clipID, let reset = destination.resetTrim else {
                throw GenerationRequestError.gate("The saved replacement destination is invalid.")
            }
            return .replaceClip(id: id, resetTrim: reset)
        default: throw GenerationRequestError.gate("The saved generation destination is unknown.")
        }
    }
}

extension GenerationController {
    static func restoreApprovedBatchItem(_ authorization: GenerationBatchAuthorization,
                                         editor: EditorViewModel) async throws -> PreparedGeneration {
        guard let home = editor.workingRoot else { throw GenerationRequestError.storage("Open the batch project before resuming generation.") }
        let stored = try GenerationBatchStore.load(id: authorization.batchID, home: home)
        guard let item = stored.batch.payload.items.first(where: { $0.id == authorization.itemID }) else {
            throw GenerationRequestError.gate("This item is not part of the approved batch.")
        }
        let package = item.package
        try authorization.requireQueued(package: package, editor: editor)
        try await package.requireCurrentContext(editor: editor)
        let scope = try GenerationProjectMutationScope(projectHome: home, editor: editor)
        let parameters = try package.restoreParameters()
        let snapshot = try await GenerationPackageInputs.restore(package: package, editor: editor)
        let references = try package.payload.references.map { reference in
            guard let asset = editor.mediaAssets.first(where: { $0.id == reference.assetID }) else {
                throw GenerationRequestError.gate("An approved batch reference is missing.")
            }
            return asset
        }
        let input = package.payload.generationInput
        let submission: GenerationRequest.Submission
        let prepared: PreparedSubmission
        let modality: GenerationRequest.Modality
        switch parameters.parameters {
        case .image:
            let value = ImageGenerationSubmission(genInput: input, references: references, name: item.purpose,
                numImages: package.payload.outputCount, folderId: package.payload.destination.folderID,
                buildParams: { _ in parameters.parameters })
            submission = .image { _ in value }
            prepared = .image(value, parameters)
            modality = .image
        case .video:
            guard let capabilities = package.payload.target.binding?.resolvedVideoCapabilities else {
                throw GenerationRequestError.gate("The approved video route has no exact capability contract.")
            }
            let value = VideoGenerationSubmission(genInput: input, placeholderDuration: Double(max(1, input.duration)),
                references: references, trimmedSourceOverride: nil, name: item.purpose, folderId: package.payload.destination.folderID,
                buildParams: { _ in parameters.parameters }, snapshotRefs: nil, preprocessRef: nil,
                resolvedVideoCapabilities: capabilities)
            submission = .video { _ in value }
            prepared = .video(value, parameters)
            modality = .video
        default: throw GenerationRequestError.gate("Only visual generation items can resume from this batch.")
        }
        let request = GenerationRequest(modality: modality, modelId: package.payload.target.modelId,
            intent: package.payload.intent, aspectRatio: input.aspectRatio, durationSeconds: Double(input.duration),
            placement: try package.restorePlacement(), origin: .panel, target: package.payload.target, submission: submission)
        let generation = PreparedGeneration(request: request, submission: prepared, target: package.payload.target,
            compiledPrompt: package.payload.prompt, notes: [], home: home, scope: scope,
            binding: package.payload.binding, compilerInputsSHA256: package.payload.compilerInputsSHA256,
            destination: package.payload.destination, recipe: package.payload.recipe, repairPlanID: package.payload.repairPlanID,
            references: snapshot, preflight: nil)
        try await package.requireCurrentContext(editor: editor)
        try scope.requireCurrent(editor: editor)
        try generation.attachReview(package)
        try generation.attachBatch(authorization, editor: editor)
        return generation
    }
}
