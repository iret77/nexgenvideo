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

        init(clipID: String, resetTrim: Bool, editor: EditorViewModel) {
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

        func matchesProject(editor: EditorViewModel) -> Bool {
            home == editor.workingRoot?.standardizedFileURL && workingCopyKey == editor.openWorkingCopyKey
                && workingCopyGeneration == editor.openWorkingCopyGeneration
                && declaration == .init(packName: editor.declaredPluginName, binding: editor.declaredPluginBinding,
                    productionContract: editor.declaredProductionContract)
        }

        func clearPending(editor: EditorViewModel) {
            guard matchesProject(editor: editor) else { return }
            editor.pendingReplacements.subtract(targets.map(\.clip.id))
            editor.pendingReplacements.remove(clipID)
        }

        func requireCurrent(editor: EditorViewModel) throws {
            guard matchesProject(editor: editor), fps == editor.timeline.fps, !targets.isEmpty,
                  targets == Self.targets(clipID: clipID, timeline: editor.timeline) else {
                throw GenerationRequestError.gate("The generated media is saved in Media. The destination clip or linked sources changed during generation and were not replaced.")
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
