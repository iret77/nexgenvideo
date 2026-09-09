import Foundation
import NexGenEngine

extension ToolExecutor {
    func getGenerationBatches(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let home = editor.workingRoot else { throw ToolError("Open a project to read its generation batches.") }
        if let id = args["batchID"] as? String {
            if let pending = editor.generationBatchCoordinator.pending, pending.id == id {
                return .ok(String(decoding: try GenerationPackageV1.encode(pending), as: UTF8.self))
            }
            return .ok(String(decoding: try GenerationPackageV1.encode(GenerationBatchStore.load(id: id, home: home)), as: UTF8.self))
        }
        struct Summary: Encodable {
            struct Item: Encodable {
                let id: String
                let purpose: String
                let packageID: String
                let state: String
                let outputAssetIDs: [String]
                let detail: String?
            }
            let id: String
            let approved: Bool
            let items: [Item]
        }
        var values = try GenerationBatchStore.all(home: home).map { snapshot in
            Summary(id: snapshot.batch.id, approved: true, items: snapshot.batch.payload.items.map { item in
                let execution = snapshot.journal.executions.first(where: { $0.itemID == item.id })!
                return .init(id: item.id, purpose: item.purpose, packageID: item.package.id,
                    state: execution.state.rawValue, outputAssetIDs: execution.outputAssetIDs, detail: execution.detail)
            })
        }
        if let pending = editor.generationBatchCoordinator.pending {
            values.append(Summary(id: pending.id, approved: false, items: pending.payload.items.map {
                .init(id: $0.id, purpose: $0.purpose, packageID: $0.package.id, state: "awaiting_approval", outputAssetIDs: [], detail: nil)
            }))
        }
        return .ok(String(decoding: try GenerationPackageV1.encode(values), as: UTF8.self))
    }

    func prepareGenerationBatch(_ editor: EditorViewModel, _ args: [String: Any], origin: ToolCallOrigin) async throws -> ToolResult {
        guard let rawID = args["requestID"] as? String, let nonce = UUID(uuidString: rawID),
              let entries = args["items"] as? [[String: Any]], !entries.isEmpty, entries.count <= 50,
              let home = editor.workingRoot, let projectKey = editor.projectId else {
            throw ToolError("A batch needs a saved project, a stable UUID requestID and 1–50 described generation requests.")
        }
        let requestBytes = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys, .withoutEscapingSlashes])
        let requestHash = FileDigest.sha256(of: requestBytes)
        if let recorded = try GenerationBatchStore.all(home: home).first(where: { $0.batch.payload.nonce == nonce }) {
            guard recorded.batch.payload.requestSHA256 == requestHash else { throw ToolError("This requestID already describes another batch. Prepare changed work with a new requestID.") }
            return .ok("This batch was already approved: \(recorded.batch.id). Read get_generation_batches; do not submit it again.")
        }
        if let pending = editor.generationBatchCoordinator.pending {
            guard pending.payload.nonce == nonce, pending.payload.requestSHA256 == requestHash else {
                throw ToolError("A generation batch is already waiting for review. Wait for that decision before preparing another manifest.")
            }
            return .ok("Batch \(pending.id) is still waiting for the native review decision. No generation was submitted.")
        }
        guard editor.agentService.pendingSpendApproval == nil, editor.agentService.pendingDialog == nil,
              !editor.agentService.spendApprovalIsRunning else {
            throw ToolError("Finish the current native decision or generation before preparing a batch.")
        }
        let scope = try GenerationProjectMutationScope(projectHome: home, editor: editor)
        await CatalogDiscovery.ensureCurrent()
        let collector = GenerationBatchPreparation()
        var items: [GenerationBatch.Item] = []
        var phase: String?
        try await GenerationBatchPreparation.$current.withValue(collector) {
            for entry in entries {
                guard let toolName = entry["tool"] as? String, let tool = ToolName(rawValue: toolName),
                      [.generateImage, .generateVideo].contains(tool), let purpose = entry["purpose"] as? String,
                      !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let rawRequest = entry["request"] as? [String: Any] else { throw ToolError("A batch item is incomplete.") }
                if let root = DataRootResolver.dataRoot(of: home) {
                    let actualPhase = try currentPhaseIfEnforced(tool: tool, editor: editor, dataRoot: root)
                    if !items.isEmpty, actualPhase != phase { throw ToolError("One generation batch cannot cross pipeline phases.") }
                    phase = actualPhase
                }
                let request = try expandingIdPrefixes(in: rawRequest, editor: editor)
                let count = collector.packages.count
                _ = try await generate(editor, request, type: tool == .generateImage ? .image : .video, origin: origin)
                guard collector.packages.count == count + 1, let package = collector.packages.last else {
                    throw ToolError("The batch item did not produce exactly one prepared request.")
                }
                try scope.requireCurrent(editor: editor)
                items.append(.init(id: UUID().uuidString, purpose: purpose, package: package))
            }
        }
        let batch = try GenerationBatch(payload: .init(nonce: nonce, projectKey: projectKey, phase: phase,
            items: items, requestSHA256: requestHash))
        editor.agentPanelVisible = true
        return try editor.agentService.presentGenerationBatch(batch, origin: origin, editor: editor)
    }
}
