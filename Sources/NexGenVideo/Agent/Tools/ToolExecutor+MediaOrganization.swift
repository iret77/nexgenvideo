import Foundation

extension ToolExecutor {
    private struct MediaOrganizationInput: DecodableToolArgs {
        struct Change: Decodable {
            let assetId: String
            let name: String?
            let folderPath: [String]
        }
        let folderId: String?
        let changes: [Change]
        static let allowedKeys: Set<String> = ["folderId", "changes"]
    }

    func proposeMediaOrganization(_ editor: EditorViewModel, _ args: [String: Any], origin: ToolCallOrigin) throws -> ToolResult {
        let input: MediaOrganizationInput = try decodeToolArgs(args, path: "propose_media_organization")
        let scope = MediaOrganizationScope(folderID: input.folderId)
        if let assigned = editor.agentService.currentTaskActivity?.mediaOrganizationScope, assigned != scope {
            throw ToolError("The proposal must use the folderId of the organization task.")
        }
        let plan = try MediaOrganizationPlan.prepare(input.changes.map {
            .init(assetID: $0.assetId, name: $0.name, folderPath: $0.folderPath)
        }, scope: scope, editor: editor)
        try editor.agentService.presentDialog(plan.dialog, origin: origin)
        return .ok("Prepared \(plan.rows.count) media changes for native selection and approval. Nothing has been renamed or moved. Stop and wait for the user.")
    }
}
