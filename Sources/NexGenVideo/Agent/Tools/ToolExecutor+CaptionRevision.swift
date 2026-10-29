import Foundation

extension ToolExecutor {
    func proposeCaptionRevision(_ editor: EditorViewModel, _ args: [String: Any], origin: ToolCallOrigin) async throws -> ToolResult {
        let turn = editor.agentService.captureHostTurnReference(origin: origin)
        func requireCurrentTurn() throws {
            if let session = origin.chatSessionID {
                guard editor.agentService.currentSessionId == session,
                      editor.agentService.captureHostTurnReference(origin: origin) == turn else {
                    throw ToolError("The caption revision conversation changed. Request the proposal again in the current chat.")
                }
            }
        }
        try requireCurrentTurn()
        try validateUnknownKeys(args, allowed: ["kind", "changes", "words", "cutAggressiveness", "captionChanges"], path: "propose_caption_revision")
        guard let rawKind = args.string("kind"), let kind = CaptionRevisionScope.Kind(rawValue: rawKind) else {
            throw ToolError("kind must be captions or speech_cuts.")
        }
        let scope: CaptionRevisionScope
        if let assigned = editor.agentService.captionRevisionScope(from: origin) { scope = assigned }
        else { scope = try await CaptionRevisionScope.capture(editor, kind: kind) }
        guard scope.kind == kind else { throw ToolError("The proposal kind must match the caption revision task.") }
        try scope.validateIdentity(editor)
        let plan: CaptionRevisionPlan
        switch args.string("kind") {
        case "captions":
            guard args["words"] == nil, args["cutAggressiveness"] == nil, args["captionChanges"] == nil,
                  let values = args["changes"] as? [[String: Any]] else {
                throw ToolError("Caption proposals need changes and cannot contain speech cuts.")
            }
            let changes = try values.map { value -> CaptionRevisionPlan.Change in
                try validateUnknownKeys(value, allowed: ["clipId", "text"], path: "propose_caption_revision.changes")
                guard let id = value.string("clipId"), let text = value.string("text") else { throw ToolError("Each change needs clipId and text.") }
                return .init(clipID: id, text: text)
            }
            plan = try await .captions(changes, scope: scope, editor: editor)
        case "speech_cuts":
            guard args["changes"] == nil, args["words"] != nil else { throw ToolError("Speech cut proposals need words; use captionChanges only for captions affected by these cuts.") }
            var cutArgs: [String: Any] = ["words": args["words"]!]
            if let value = args["cutAggressiveness"] { cutArgs["cutAggressiveness"] = value }
            var replacements: [String: String] = [:]
            if let raw = args["captionChanges"] {
                guard let values = raw as? [[String: Any]], values.count <= 500 else { throw ToolError("captionChanges must contain at most 500 caption replacements.") }
                for value in values {
                    try validateUnknownKeys(value, allowed: ["clipId", "text"], path: "propose_caption_revision.captionChanges")
                    guard let id = value.string("clipId"), let text = value.string("text"), !id.isEmpty,
                          text.count <= 4000, replacements[id] == nil else { throw ToolError("Each affected caption needs a unique clipId and replacement text of at most 4,000 characters.") }
                    replacements[id] = text
                }
            }
            let removal = try await prepareWordRemoval(editor, cutArgs, scope: scope, captionChanges: replacements)
            plan = try await .speech(removal, editor: editor)
        default: throw ToolError("kind must be captions or speech_cuts.")
        }
        try scope.validateIdentity(editor)
        try requireCurrentTurn()
        try editor.agentService.presentDialog(plan.makeDialog(), origin: origin)
        return .ok("Prepared a native before/after proposal with exact affected time ranges. Nothing was changed. Stop and wait for the user to apply or dismiss it.")
    }
}
