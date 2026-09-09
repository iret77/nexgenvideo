import Foundation
import NexGenEngine

struct GenerationPackageV1: Codable, Sendable, Equatable {
    struct Destination: Codable, Sendable, Equatable {
        let kind: String
        let folderID: String?
        let clipID: String?
        let startFrame: Int?
        let durationSeconds: Double?
        let resetTrim: Bool?
        let timelineFPS: Int?
        let clipSHA256: String?

        @MainActor
        init(_ placement: GenerationRequest.Placement, editor: EditorViewModel) throws {
            switch placement {
            case .mediaLibrary(let folder):
                kind = "media_library"; folderID = folder; clipID = nil; startFrame = nil; durationSeconds = nil; resetTrim = nil
                timelineFPS = nil; clipSHA256 = nil
            case .timelineAt(let start, let span, _):
                kind = "timeline"; folderID = nil; clipID = nil; startFrame = start; durationSeconds = span; resetTrim = nil
                timelineFPS = editor.timeline.fps; clipSHA256 = nil
            case .replaceClip(let id, let reset):
                kind = "replace_clip"; folderID = nil; clipID = id; startFrame = nil; durationSeconds = nil; resetTrim = reset
                timelineFPS = editor.timeline.fps
                guard let clip = editor.clipFor(id: id) else { throw GenerationRequestError.optionsInvalid("The replacement clip is no longer available.") }
                clipSHA256 = FileDigest.sha256(of: try GenerationPackageV1.canonicalData(clip))
            }
            try requireCurrent(editor: editor)
        }

        @MainActor
        func requireCurrent(editor: EditorViewModel) throws {
            if let folderID, editor.folder(id: folderID) == nil { throw GenerationRequestError.gate("The destination folder changed. Prepare the request again.") }
            if let timelineFPS, timelineFPS != editor.timeline.fps { throw GenerationRequestError.gate("The timeline frame rate changed. Prepare the request again.") }
            if let clipID {
                guard let clip = editor.clipFor(id: clipID), try FileDigest.sha256(of: GenerationPackageV1.canonicalData(clip)) == clipSHA256 else {
                    throw GenerationRequestError.gate("The destination clip changed. Prepare the replacement again.")
                }
            }
        }
    }
    struct Payload: Codable, Sendable, Equatable {
        let target: ResolvedGenerationTarget
        let modality: String
        let operation: String
        let intent: String
        let prompt: String
        let promptRevisionID: String
        let generationInput: GenerationInput
        let binding: PromptBinding
        let compilerInputsSHA256: String
        let recipe: GenerationCompileRecipe?
        let repairPlanID: String?
        let destination: Destination
        let outputCount: Int
        let references: [GenerationReferenceReceipt]
        let referenceRoles: [String]
        let requestParametersJSON: String
        let routing: ProductionGenerationRoutingProofV1?
        let routeReceipt: GenerationRouteReceipt
        let estimate: GenerationMoney?
    }
    let schema: String
    let id: String
    let renderID: String
    let payload: Payload

    private enum CodingKeys: String, CodingKey { case schema, id, renderID, payload }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try values.decode(String.self, forKey: .schema)
        let id = try values.decode(String.self, forKey: .id)
        let renderID = try values.decode(String.self, forKey: .renderID)
        try self.init(payload: values.decode(Payload.self, forKey: .payload))
        guard self.schema == schema, self.id == id, self.renderID == renderID else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "The generation package hash does not match its payload."))
        }
    }

    init(payload: Payload) throws {
        guard payload.outputCount > 0, payload.outputCount <= 4,
              !payload.target.modelId.isEmpty, !payload.target.endpoint.isEmpty,
              payload.generationInput.model == payload.target.modelId, payload.generationInput.prompt == payload.prompt,
              payload.generationInput.referenceReceipts == payload.references,
              payload.referenceRoles.count == payload.references.count,
              (payload.binding.compilerInputsSHA256 ?? "none") == payload.compilerInputsSHA256,
              payload.routeReceipt == GenerationRouteReceipt(target: payload.target, checks: payload.routeReceipt.checks,
                capabilitySnapshot: payload.routing?.route.capabilitySnapshot),
              JSONSerialization.isValidJSONObject(try JSONSerialization.jsonObject(with: Data(payload.requestParametersJSON.utf8))) else {
            throw GenerationRequestError.optionsInvalid("The generation package has no executable request.")
        }
        if let estimate = payload.estimate {
            guard estimate.eurAmount.isFinite, estimate.eurAmount >= 0, estimate.nativeAmount.isFinite,
                  estimate.nativeAmount >= 0, estimate.eurPerNativeUnit.isFinite, estimate.eurPerNativeUnit > 0,
                  estimate.nativeCurrency.count == 3, !estimate.pricingSource.isEmpty,
                  !estimate.exchangeRateSource.isEmpty, !estimate.exchangeRateDate.isEmpty else {
                throw GenerationRequestError.optionsInvalid("The package has no valid monetary estimate.")
            }
        }
        schema = "generation-package/v1"
        id = FileDigest.sha256(of: try Self.canonicalData(payload))
        let subject = payload.binding.shotId == "none" ? "asset" : payload.binding.shotId
        renderID = [subject, payload.target.modelId, payload.operation, String(id.prefix(12))].joined(separator: " / ")
        self.payload = payload
    }

    func validate() throws {
        let rebuilt = try Self(payload: payload)
        guard self == rebuilt else { throw GenerationRequestError.gate("The generation package changed after review.") }
    }

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func requestJSON(parameters: PreparedProviderParameters, references: [GenerationReferenceReceipt]) throws -> String {
        let locations = references.enumerated().map { "ngv-input://\($0.offset)/\($0.element.submittedSHA256)" }
        let data = try canonicalData(parameters.bind(locations))
        guard let text = String(data: data, encoding: .utf8) else { throw GenerationRequestError.optionsInvalid("The generation request cannot be encoded.") }
        return text
    }

    static func referenceRoles(parameters: PreparedProviderParameters) -> [String] {
        parameters.referenceSlots.map { slot in
            switch parameters.parameters {
            case .image: return "image_reference"
            case .video(let video):
                if video.sourceVideoURL == slot { return "source_video" }
                if video.startFrameURL == slot { return "start_frame" }
                if video.endFrameURL == slot { return "end_frame" }
                if video.referenceImageURLs.contains(slot) { return "image_reference" }
                if video.referenceVideoURLs.contains(slot) { return "video_reference" }
                return "audio_reference"
            default: return "reference"
            }
        }
    }

    static func normalized(_ input: GenerationInput) -> GenerationInput {
        var value = input
        value.createdAt = nil; value.spendTransactionId = nil; value.generationPackageID = nil
        value.imageURLs = nil; value.referenceImageURLs = nil; value.referenceVideoURLs = nil; value.referenceAudioURLs = nil
        return value
    }

    func requireRequest(input: GenerationInput, target: ResolvedGenerationTarget,
                        parameters: PreparedProviderParameters, references: [GenerationReferenceReceipt]) throws {
        try validate()
        guard target == payload.target, Self.normalized(input) == payload.generationInput,
              references == payload.references,
              try Self.requestJSON(parameters: parameters, references: references) == payload.requestParametersJSON else {
            throw GenerationRequestError.gate("The provider request differs from its reviewed generation package.")
        }
    }

    @MainActor
    func requireCurrentContext(editor: EditorViewModel) async throws {
        let modality: PromptComposer.Modality = payload.modality == "image" ? .image : .video
        let home = editor.workingRoot
        guard try await PromptCompiler.currentBinding(
            editor: editor,
            shotId: payload.binding.shotId,
            modality: modality,
            modelId: payload.target.modelId
        ).matchesCurrentState(of: payload.binding),
              try await PromptComposer.inputFingerprint(projectDir: home) == payload.compilerInputsSHA256,
              editor.workingRoot == home else {
            throw GenerationRequestError.gate("The project direction changed after generation review. Prepare and review the request again.")
        }
        try payload.destination.requireCurrent(editor: editor)
        try Task.checkCancellation()
    }

    static func load(id: String, home: URL) throws -> Self {
        guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GenerationRequestError.gate("Invalid generation package identity.")
        }
        let file = try ProjectLocalFile.resolve("generation-packages/\(id).json", dataRoot: home)
        let bytes = try Data(contentsOf: file)
        let package = try JSONDecoder().decode(Self.self, from: bytes)
        guard package.id == id, try Self.canonicalData(package) == bytes else {
            throw GenerationRequestError.gate("The immutable generation package changed. Restore its recorded bytes.")
        }
        return package
    }

    @MainActor
    func persist(editor: EditorViewModel) throws {
        try validate()
        guard let home = editor.workingRoot else { return }
        let scope = try GenerationProjectMutationScope(projectHome: home, editor: editor)
        let directory = home.appendingPathComponent("generation-packages", isDirectory: true)
        guard directory.resolvingSymlinksInPath() == home.resolvingSymlinksInPath().appendingPathComponent("generation-packages") else {
            throw GenerationRequestError.storage("Generation package storage cannot traverse a symbolic link.")
        }
        try scope.requireCurrent(editor: editor)
        if let key = editor.openWorkingCopyKey { try ProjectWorkingCopy.markDirty(key: key) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(id + ".json")
        let bytes = try Self.canonicalData(self)
        if FileManager.default.fileExists(atPath: file.path) {
            guard try Data(contentsOf: ProjectLocalFile.resolve("generation-packages/\(id).json", dataRoot: home)) == bytes else {
                throw GenerationRequestError.storage("An immutable generation package has different bytes.")
            }
        } else { try bytes.write(to: file, options: .atomic) }
    }
}
