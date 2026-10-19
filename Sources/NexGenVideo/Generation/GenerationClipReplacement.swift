import Foundation

@MainActor
enum GenerationClipReplacement {
    struct Snapshot {
        struct Target: Codable, Sendable, Equatable {
            let trackID: String
            let clip: Clip
        }
        let clipID: String
        let resetTrim: Bool
        let home: URL?
        let workingCopyKey: String?
        let workingCopyGeneration: UUID?
        let declaration: ProjectPackGate.MutationDeclaration
        let fps: Int
        let targets: [Target]

        @MainActor init(clipID: String, resetTrim: Bool, editor: EditorViewModel) {
            self.clipID = clipID
            self.resetTrim = resetTrim
            home = editor.workingRoot?.standardizedFileURL
            workingCopyKey = editor.openWorkingCopyKey
            workingCopyGeneration = editor.openWorkingCopyGeneration
            declaration = .init(packName: editor.declaredPluginName, binding: editor.declaredPluginBinding,
                productionContract: editor.declaredProductionContract)
            fps = editor.timeline.fps
            targets = Self.targets(clipID: clipID, timeline: editor.timeline)
        }

        @MainActor func matchesProject(editor: EditorViewModel) -> Bool {
            home == editor.workingRoot?.standardizedFileURL && workingCopyKey == editor.openWorkingCopyKey
                && workingCopyGeneration == editor.openWorkingCopyGeneration
                && declaration == .init(packName: editor.declaredPluginName, binding: editor.declaredPluginBinding,
                    productionContract: editor.declaredProductionContract)
        }

        @MainActor func clearPending(editor: EditorViewModel) {
            guard matchesProject(editor: editor) else { return }
            editor.pendingReplacements.subtract(targets.map(\.clip.id))
            editor.pendingReplacements.remove(clipID)
        }

        @MainActor func requireCurrent(editor: EditorViewModel, modality: GenerationRequest.Modality? = nil, resultType: ClipType? = nil) throws {
            guard matchesProject(editor: editor), fps == editor.timeline.fps, !targets.isEmpty,
                  targets == Self.targets(clipID: clipID, timeline: editor.timeline) else {
                throw GenerationRequestError.gate("The generated media is saved in Media. The destination clip or linked sources changed during generation and were not replaced.")
            }
            guard let anchor = targets.first(where: { $0.clip.id == clipID })?.clip else {
                throw GenerationRequestError.gate("The destination clip is no longer available. Select it again before generating.")
            }
            if let modality {
                let audioRequest = modality == .audio || modality == .music
                guard audioRequest == (anchor.mediaType == .audio) else {
                    throw GenerationRequestError.gate("Audio generation replaces audio clips; image and video generation replace picture clips. Choose a matching destination or save the result in Media.")
                }
                if let resultType {
                    let matches: Bool
                    switch modality {
                    case .audio, .music: matches = resultType == .audio
                    case .video: matches = resultType == .video
                    case .image: matches = resultType == .image
                    case .upscale: matches = resultType == .video || resultType == .image
                    }
                    guard matches else {
                        throw GenerationRequestError.gate("The generated media is saved in Media. Its type does not match the approved generation, so the clip was not replaced.")
                    }
                }
            }
            if let resultType {
                guard (resultType == .audio) == (anchor.mediaType == .audio) else {
                    throw GenerationRequestError.gate("The generated media is saved in Media. Audio sources replace audio clips only; the clip was not changed.")
                }
            }
            if resetTrim {
                let audioOnly = modality == .audio || modality == .music || resultType == .audio
                let changedTargets = audioOnly ? targets.filter { $0.clip.mediaType == .audio } : targets
                guard changedTargets.allSatisfy({ target in
                          target.clip.trimStartFrame == anchor.trimStartFrame
                              && target.clip.trimEndFrame == anchor.trimEndFrame
                              && target.clip.sourceFramesConsumed == anchor.sourceFramesConsumed
                      }) else {
                    throw GenerationRequestError.gate("Linked clips use different source ranges. Unlink them or turn off Use trimmed portion only before replacing their source.")
                }
            }
        }

        static func targets(clipID: String, timeline: Timeline) -> [Target] {
            guard let anchor = timeline.tracks.flatMap(\.clips).first(where: { $0.id == clipID }) else { return [] }
            return timeline.tracks.flatMap { track in
                track.clips.filter { clip in
                    clip.id == clipID || (anchor.linkGroupId != nil && clip.linkGroupId == anchor.linkGroupId
                        && clip.mediaRef == anchor.mediaRef)
                }.map { Target(trackID: track.id, clip: $0) }
            }.sorted { $0.clip.id < $1.clip.id }
        }
    }

}
