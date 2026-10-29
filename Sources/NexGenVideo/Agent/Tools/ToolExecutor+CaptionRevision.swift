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
        try validateUnknownKeys(args, allowed: ["kind", "changes", "words", "cutAggressiveness"], path: "propose_caption_revision")
        guard let rawKind = args.string("kind"), let kind = CaptionRevisionScope.Kind(rawValue: rawKind) else {
            throw ToolError("kind must be captions or speech_cuts.")
        }
        let scope = try editor.agentService.captionRevisionScope(from: origin) ?? CaptionRevisionScope.capture(editor, kind: kind)
        guard scope.kind == kind else { throw ToolError("The proposal kind must match the caption revision task.") }
        try scope.validate(editor)
        let plan: CaptionRevisionPlan
        switch args.string("kind") {
        case "captions":
            guard args["words"] == nil, args["cutAggressiveness"] == nil,
                  let values = args["changes"] as? [[String: Any]] else {
                throw ToolError("Caption proposals need changes and cannot contain speech cuts.")
            }
            let changes = try values.map { value -> CaptionRevisionPlan.Change in
                try validateUnknownKeys(value, allowed: ["clipId", "text"], path: "propose_caption_revision.changes")
                guard let id = value.string("clipId"), let text = value.string("text") else { throw ToolError("Each change needs clipId and text.") }
                return .init(clipID: id, text: text)
            }
            plan = try .captions(changes, scope: scope, editor: editor)
        case "speech_cuts":
            guard args["changes"] == nil, args["words"] != nil else { throw ToolError("Speech cut proposals need words and cannot contain caption replacements.") }
            var cutArgs: [String: Any] = ["words": args["words"]!]
            if let value = args["cutAggressiveness"] { cutArgs["cutAggressiveness"] = value }
            let removal = try await prepareWordRemoval(editor, cutArgs, scope: scope)
            plan = try .speech(removal, editor: editor)
        default: throw ToolError("kind must be captions or speech_cuts.")
        }
        try scope.validate(editor)
        try requireCurrentTurn()
        try editor.agentService.presentDialog(plan.dialog, origin: origin)
        return .ok("Prepared a native before/after proposal with exact affected time ranges. Nothing was changed. Stop and wait for the user to apply or dismiss it.")
    }
}
