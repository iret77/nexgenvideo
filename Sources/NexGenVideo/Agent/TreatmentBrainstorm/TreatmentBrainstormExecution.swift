import Foundation
import NexGenEngine

@MainActor
final class TreatmentBrainstormSessionState {
    struct PendingApproval: Sendable {
        let plan: TreatmentBrainstormPlan
        let projectID: String
    }

    struct Authorization: Sendable {
        let id: String
        let plan: TreatmentBrainstormPlan
        let projectID: String
        let approvedAt: Date
        let expiresAt: Date
    }

    var pendingApprovals: [String: PendingApproval] = [:]
    var authorizations: [String: Authorization] = [:]
    var tasks: [String: (dataRootPath: String, task: Task<ToolResult, Never>)] = [:]
}

private struct TreatmentBrainstormAttempt: Sendable {
    let model: TreatmentBrainstormModel
    let response: TreatmentBrainstormProviderResponse?
    let error: String?
}

extension AgentService {

    func presentTreatmentBrainstormApproval(
        plan: TreatmentBrainstormPlan,
        editor: EditorViewModel,
        origin: ToolCallOrigin
    ) throws -> ToolResult {
        if case .externalMCP = origin {
            throw ToolError("External MCP sessions cannot own Treatment Brainstorm cost approval. Start it from the in-app chat.")
        }
        var routeLines = plan.models.map {
            "Idea · \($0.provider.displayName) · \($0.displayName)"
        }
        if let synthesis = plan.synthesisModel {
            routeLines.append("Synthesis · \(synthesis.provider.displayName) · \(synthesis.displayName)")
        }
        let routes = routeLines.joined(separator: "\n")
        let dialog = AgentDialog(
            id: "treatment-brainstorm.\(plan.id)",
            title: "Generate Treatment ideas?",
            symbol: "lightbulb.max",
            intro: "NexGenVideo will make \(plan.callCount) additional provider-billed model calls:\n\(routes)",
            costHint: "\(plan.callCount) additional calls · billed by each provider using input and output tokens",
            confirmLabel: "Continue",
            textField: nil,
            sections: [
                .init(
                    id: "approval",
                    label: "Additional model calls",
                    kind: .choices(options: [
                        .init(id: "approve", label: "Approve \(plan.callCount) calls", shortLabel: "Approved"),
                        .init(id: "decline", label: "Do not call models", shortLabel: "Declined"),
                    ], multiSelect: false)
                ),
            ],
            workflowDecision: .treatmentBrainstormApproval
        )
        try editor.pipelineAgentHarness.guardAgentDecision(dialog, editor: editor)
        treatmentBrainstormState.pendingApprovals[dialog.id] = .init(
            plan: plan,
            projectID: editor.projectId ?? ""
        )
        do {
            try presentDialog(dialog, origin: origin)
        } catch {
            treatmentBrainstormState.pendingApprovals.removeValue(forKey: dialog.id)
            throw error
        }
        return .suspended("Treatment Brainstorm approval is presented. STOP and wait for the host follow-up.")
    }

    func discardTreatmentBrainstormApproval(dialogID: String) {
        treatmentBrainstormState.pendingApprovals.removeValue(forKey: dialogID)
    }

    func resolveTreatmentBrainstormApproval(
        _ dialog: AgentDialog,
        selected: Set<String>
    ) throws -> String {
        guard let pending = treatmentBrainstormState.pendingApprovals.removeValue(forKey: dialog.id) else {
            throw ToolError("This Treatment Brainstorm approval is no longer valid.")
        }
        guard selected == ["approve"] || selected == ["decline"] else {
            treatmentBrainstormState.pendingApprovals[dialog.id] = pending
            throw ToolError("Approve or decline the additional model calls.")
        }
        if selected == ["approve"] {
            let authorizationID = UUID().uuidString.lowercased()
            treatmentBrainstormState.authorizations[authorizationID] = .init(
                id: authorizationID,
                plan: pending.plan,
                projectID: pending.projectID,
                approvedAt: Date(),
                expiresAt: Date().addingTimeInterval(600)
            )
            return "Treatment Brainstorm is authorized once. Call brainstorm_treatment with authorization_id=\(authorizationID). Do not alter the call plan."
        } else {
            return "Treatment Brainstorm was declined. Continue with the existing single-model Treatment route."
        }
    }

    func claimTreatmentBrainstormAuthorization(
        _ id: String,
        editor: EditorViewModel,
        package: TreatmentBrainstormPromptPackage,
        dataRoot: URL,
        includeSynthesis: Bool
    ) throws -> TreatmentBrainstormSessionState.Authorization {
        guard let value = treatmentBrainstormState.authorizations.removeValue(forKey: id),
              value.expiresAt > Date(),
              value.projectID == (editor.projectId ?? ""),
              value.plan.dataRootPath == dataRoot.standardizedFileURL.path,
              (value.plan.synthesisModel != nil) == includeSynthesis,
              value.plan.package.inputFingerprint == package.inputFingerprint else {
            throw ToolError("Treatment Brainstorm authorization is missing, expired, or no longer matches the canonical inputs. Request approval again.")
        }
        return value
    }

    func treatmentBrainstormTask(_ id: String, dataRoot: URL) throws -> Task<ToolResult, Never>? {
        guard let value = treatmentBrainstormState.tasks[id] else { return nil }
        guard value.dataRootPath == dataRoot.standardizedFileURL.path else {
            throw ToolError("Treatment Brainstorm retry does not match the authorized project.")
        }
        return value.task
    }

    func registerTreatmentBrainstormTask(_ task: Task<ToolResult, Never>, id: String, dataRoot: URL) {
        treatmentBrainstormState.tasks[id] = (dataRoot.standardizedFileURL.path, task)
    }
}

extension ToolExecutor {
    func brainstormTreatment(
        _ editor: EditorViewModel,
        _ args: [String: Any],
        origin: ToolCallOrigin
    ) async throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        try editor.pipelineAgentHarness.guardTreatmentBrainstormPath()
        let package = try TreatmentBrainstormPromptPackage.compile(dataRoot: root)
        if let authorizationID = args.string("authorization_id") {
            if let task = try editor.agentService.treatmentBrainstormTask(authorizationID, dataRoot: root) {
                return await task.value
            }
            try requirePhaseIdle(editor, dataRoot: root)
            let authorization = try editor.agentService.claimTreatmentBrainstormAuthorization(
                authorizationID,
                editor: editor,
                package: package,
                dataRoot: root,
                includeSynthesis: args.bool("include_synthesis") ?? false
            )
            let lease = try reservePipelineMutation(label: "Treatment Brainstorm", dataRoot: root, editor: editor)
            let task = Task<ToolResult, Never> { @MainActor [weak editor] in
                defer {
                    editor?.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease)
                }
                do {
                    let result = try await executeTreatmentBrainstorm(authorization, dataRoot: root)
                    editor?.onPipelineChanged?()
                    return result
                } catch {
                    return .error(error.localizedDescription)
                }
            }
            editor.agentService.registerTreatmentBrainstormTask(task, id: authorizationID, dataRoot: root)
            return await task.value
        }

        let enabled = TreatmentBrainstormModelCatalog.all.filter {
            TreatmentBrainstormPreferences.isEnabled($0) && $0.supportsStructuredOutput
        }
        guard enabled.count >= 2 else {
            throw ToolError("Enable at least two Treatment Brainstorm models in Settings before requesting multi-model ideas.")
        }
        let offered = try await offeredModels(enabled)
        guard offered.count >= 2 else {
            throw ToolError("At least two activated structured-output models must be available from connected providers.")
        }
        let includeSynthesis = args.bool("include_synthesis") ?? false
        let plan = TreatmentBrainstormPlan(
            id: UUID().uuidString.lowercased(),
            dataRootPath: root.standardizedFileURL.path,
            models: offered,
            synthesisModel: includeSynthesis ? offered.first : nil,
            package: package
        )
        return try editor.agentService.presentTreatmentBrainstormApproval(
            plan: plan,
            editor: editor,
            origin: origin
        )
    }

    private func offeredModels(_ models: [TreatmentBrainstormModel]) async throws -> [TreatmentBrainstormModel] {
        let client = TreatmentBrainstormHTTPClient()
        var available: [TreatmentBrainstormProvider: Set<String>] = [:]
        for provider in Set(models.map(\.provider)) {
            guard let key = provider.apiKey else {
                available[provider] = []
                continue
            }
            available[provider] = (try? await client.offeredModelIDs(provider: provider, apiKey: key)) ?? []
        }
        return models.filter { available[$0.provider]?.contains($0.id) == true }
    }

    private func executeTreatmentBrainstorm(
        _ authorization: TreatmentBrainstormSessionState.Authorization,
        dataRoot: URL
    ) async throws -> ToolResult {
        let plan = authorization.plan
        guard TreatmentBrainstormPromptPackage.compile(dataRoot: dataRoot).inputFingerprint
                == plan.package.inputFingerprint else {
            throw ToolError("Canonical Treatment inputs changed after approval. Request approval again.")
        }
        let prompt = plan.package.idea
        let client = TreatmentBrainstormHTTPClient()
        let attempts = await withTaskGroup(of: TreatmentBrainstormAttempt.self) { group in
            for model in plan.models {
                group.addTask {
                    do {
                        guard let key = model.provider.apiKey else {
                            throw TreatmentBrainstormClientError.missingCredential(model.provider.displayName)
                        }
                        let response = try await client.generate(
                            .init(model: model, system: prompt.system, input: prompt.input),
                            apiKey: key
                        )
                        return .init(model: model, response: response, error: nil)
                    } catch {
                        return .init(model: model, response: nil, error: error.localizedDescription)
                    }
                }
            }
            var values: [TreatmentBrainstormAttempt] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.model.id < $1.model.id }
        }
        var executions: [TreatmentBrainstormCallExecutionV1] = []
        let ideas = attempts.compactMap { attempt -> TreatmentBrainstormVariantV1? in
            guard let response = attempt.response else {
                executions.append(.init(
                    role: .idea,
                    providerID: attempt.model.provider.rawValue,
                    modelID: attempt.model.id,
                    status: .failed,
                    error: attempt.error ?? "Provider call failed."
                ))
                return nil
            }
            let variant = Self.brainstormVariant(
                response,
                model: attempt.model,
                role: .idea,
                prompt: prompt
            )
            executions.append(.init(
                role: .idea,
                providerID: attempt.model.provider.rawValue,
                modelID: attempt.model.id,
                status: .succeeded,
                variantID: variant.id
            ))
            return variant
        }
        var variants = ideas
        if let model = plan.synthesisModel {
            if ideas.count >= 2 {
                let synthesisPrompt = plan.package.synthesis(variants: ideas)
                do {
                    guard let key = model.provider.apiKey else {
                        throw TreatmentBrainstormClientError.missingCredential(model.provider.displayName)
                    }
                    let response = try await client.generate(
                        .init(model: model, system: synthesisPrompt.system, input: synthesisPrompt.input),
                        apiKey: key
                    )
                    let variant = Self.brainstormVariant(
                        response,
                        model: model,
                        role: .synthesis,
                        prompt: synthesisPrompt,
                        sourceIDs: ideas.map(\.id)
                    )
                    variants.append(variant)
                    executions.append(.init(
                        role: .synthesis,
                        providerID: model.provider.rawValue,
                        modelID: model.id,
                        status: .succeeded,
                        variantID: variant.id
                    ))
                } catch {
                    executions.append(.init(
                        role: .synthesis,
                        providerID: model.provider.rawValue,
                        modelID: model.id,
                        status: .failed,
                        error: error.localizedDescription
                    ))
                }
            } else {
                executions.append(.init(
                    role: .synthesis,
                    providerID: model.provider.rawValue,
                    modelID: model.id,
                    status: .notAttempted,
                    error: "Synthesis was not attempted because fewer than two idea calls succeeded."
                ))
            }
        }
        let synthesisCalls = plan.synthesisModel.map {
            [TreatmentBrainstormApprovedCallV1(
                role: .synthesis,
                providerID: $0.provider.rawValue,
                modelID: $0.id
            )]
        } ?? []
        let approvedCalls = plan.models.map {
            TreatmentBrainstormApprovedCallV1(
                role: .idea,
                providerID: $0.provider.rawValue,
                modelID: $0.id
            )
        } + synthesisCalls
        let run = TreatmentBrainstormRunV1(
            id: plan.id,
            createdAt: Self.brainstormTimestamp(),
            inputFingerprint: plan.package.inputFingerprint,
            inputs: plan.package.inputs,
            approval: .init(
                authorizationSHA256: FileDigest.sha256(of: Data(authorization.id.utf8)),
                approvedAt: Self.brainstormTimestamp(authorization.approvedAt),
                calls: approvedCalls
            ),
            executions: executions,
            variants: variants
        )
        let url = try TreatmentBrainstormStoreV1.writeRun(run, dataRoot: dataRoot)
        let payload: [String: Any] = [
            "written": true,
            "complete": executions.allSatisfy { $0.status == .succeeded },
            "run_id": run.id,
            "path": FrameInventory.relativePath(of: url, to: dataRoot),
            "variants": variants.map { variant -> [String: Any] in [
                "id": variant.id,
                "role": variant.role.rawValue,
                "provider": variant.providerID,
                "model": variant.modelID,
                "title": variant.title,
                "summary": variant.summary,
                "body_markdown": variant.bodyMarkdown,
                "source_variant_ids": variant.sourceVariantIDs,
            ] },
            "call_results": executions.map { execution -> [String: Any] in [
                "role": execution.role.rawValue,
                "provider": execution.providerID,
                "model": execution.modelID,
                "status": execution.status.rawValue,
                "error": execution.error ?? NSNull(),
            ] },
        ]
        if ideas.count < 2 {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return .error(String(decoding: data, as: UTF8.self))
        }
        return try jsonResult(payload)
    }

    nonisolated private static func brainstormVariant(
        _ response: TreatmentBrainstormProviderResponse,
        model: TreatmentBrainstormModel,
        role: TreatmentBrainstormRoleV1,
        prompt: TreatmentBrainstormPrompt,
        sourceIDs: [String] = []
    ) -> TreatmentBrainstormVariantV1 {
        TreatmentBrainstormVariantV1(
            id: UUID().uuidString.lowercased(),
            role: role,
            providerID: model.provider.rawValue,
            modelID: model.id,
            title: response.output.title,
            summary: response.output.summary,
            bodyMarkdown: response.output.bodyMarkdown,
            sourceVariantIDs: sourceIDs,
            requestSHA256: prompt.sha256,
            providerResponseID: response.responseID,
            responseJSON: response.outputJSON,
            responseSHA256: FileDigest.sha256(of: Data(response.outputJSON.utf8)),
            usage: .init(inputTokens: response.inputTokens, outputTokens: response.outputTokens)
        )
    }

    nonisolated private static func brainstormTimestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
