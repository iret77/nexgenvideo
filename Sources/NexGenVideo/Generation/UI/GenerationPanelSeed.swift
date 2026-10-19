import Foundation

@MainActor
enum GenerationPanelSeed {
    @MainActor
    struct Context {
        let home: URL?
        let key: String?
        let generation: UUID?
        let declaration: ProjectPackGate.MutationDeclaration

        init(editor: EditorViewModel) {
            home = editor.workingRoot
            key = editor.openWorkingCopyKey
            generation = editor.openWorkingCopyGeneration
            declaration = .init(packName: editor.declaredPluginName, binding: editor.declaredPluginBinding,
                productionContract: editor.declaredProductionContract)
        }

        func matches(editor: EditorViewModel) -> Bool {
            home == editor.workingRoot && key == editor.openWorkingCopyKey
                && generation == editor.openWorkingCopyGeneration
                && declaration == .init(packName: editor.declaredPluginName, binding: editor.declaredPluginBinding,
                    productionContract: editor.declaredProductionContract)
        }
    }

    struct Restored {
        let intent: String
        let sourceTrim: TrimmedSource?
    }

    static func commitEditContext(_ seed: PendingPanelSeed, restored: Restored, editor: EditorViewModel) -> Bool {
        guard editor.pendingPanelSeed?.id == seed.id, seed.context.matches(editor: editor) else { return false }
        editor.pendingEditReplacementClipId = seed.replacementClipID
        editor.pendingEditTrimmedSource = seed.trimmedSource ?? restored.sourceTrim
        editor.pendingEditAudioPlacement = seed.audioPlacement
        editor.pendingPanelSeed = nil
        return true
    }

    static func restore(_ input: GenerationInput, assets: [MediaAsset]) throws -> Restored {
        let byID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = [input.imageURLAssetIds, input.referenceImageAssetIds, input.referenceVideoAssetIds,
                      input.referenceAudioAssetIds].map { $0 ?? [] }
        let ids = groups.flatMap { $0 } + [input.sourceVideoAssetId, input.startFrameAssetId,
            input.endFrameAssetId, input.imageMaskAssetId].compactMap { $0 }
        guard ids.allSatisfy({ byID[$0] != nil }) else {
            throw ToolError("A recorded generation source or reference is missing from this project. Restore it before rerunning; references cannot be silently omitted.")
        }
        let primaryIDs = Array(Set((input.imageURLAssetIds ?? []) + [input.sourceVideoAssetId,
            input.startFrameAssetId, input.endFrameAssetId].compactMap { $0 } + (input.referenceVideoAssetIds ?? [])))
        for (remote, durable) in [(input.imageURLs, Optional(primaryIDs)),
            (input.referenceImageURLs, input.referenceImageAssetIds), (input.referenceVideoURLs, input.referenceVideoAssetIds),
            (input.referenceAudioURLs, input.referenceAudioAssetIds)] {
            guard (remote?.count ?? 0) <= (durable?.count ?? 0) else {
                throw ToolError("The original generation has references without project identities. Assign the original sources explicitly before preparing another request.")
            }
        }
        let sourceID = input.sourceVideoAssetId
            ?? (input.imageURLAssetIds ?? []).first(where: { byID[$0]?.type == .video })
            ?? input.referenceVideoAssetIds?.first
        let trim: TrimmedSource?
        if let range = input.sourceRange?.trim {
            guard let sourceID, let source = byID[sourceID], source.type == .video,
                  range.fps > 0, range.trimStartFrame >= 0, range.trimEndFrame >= 0, range.sourceFramesConsumed > 0 else {
                throw ToolError("The recorded source range is unavailable. Restore the original video and its reviewed range before rerunning.")
            }
            trim = TrimmedSource(sourceURL: source.url, record: range)
        } else {
            if let sourceID, input.sourceRange == nil,
               input.referenceReceipts?.contains(where: { $0.assetID == sourceID && $0.sourceSHA256 != $0.submittedSHA256 }) == true {
                throw ToolError("The original video was transformed before submission, but its source range was not recorded. Choose the source and range explicitly for a new request.")
            }
            trim = nil
        }
        let intent = input.intent?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Restored(intent: intent.flatMap { $0.isEmpty ? nil : $0 } ?? input.prompt, sourceTrim: trim)
    }

    static func requireAudioOptions(_ input: GenerationInput, model: AudioModelConfig) throws {
        var unavailable: [String] = []
        if let voice = input.voice, !voice.isEmpty, model.voices?.contains(voice) != true { unavailable.append("voice") }
        if input.lyrics?.isEmpty == false, !model.supportsLyrics { unavailable.append("lyrics") }
        if input.styleInstructions?.isEmpty == false, !model.supportsStyleInstructions { unavailable.append("style instructions") }
        if input.instrumental == true, !model.supportsInstrumental { unavailable.append("instrumental") }
        if input.referenceImageAssetIds?.isEmpty == false { unavailable.append("image references") }
        if input.referenceAudioAssetIds?.isEmpty == false { unavailable.append("audio references") }
        if input.startFrameAssetId != nil || input.endFrameAssetId != nil || input.imageMaskAssetId != nil { unavailable.append("frame or mask inputs") }
        if input.referenceVideoAssetIds?.isEmpty == false || input.sourceVideoAssetId != nil, !model.inputs.contains(.video) { unavailable.append("source video") }
        guard unavailable.isEmpty else {
            throw GenerationRequestError.optionsInvalid("The original request uses \(unavailable.joined(separator: ", ")), which this model no longer offers. Start a new request to choose current inputs explicitly.")
        }
    }
}
