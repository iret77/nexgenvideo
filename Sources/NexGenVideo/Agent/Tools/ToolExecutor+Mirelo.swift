import AVFoundation
import Foundation

typealias MireloResultDownload = @Sendable (
    _ url: URL,
    _ maxBytes: Int64,
    _ timeout: TimeInterval
) async throws -> RemoteMediaDownloader.Download

private actor MireloToolExecutionCoalescer {
    static let shared = MireloToolExecutionCoalescer()

    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<ToolResult, Error>]
    }

    private struct RetiringFlight {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var flights: [String: Flight] = [:]
    private var retiring: [String: RetiringFlight] = [:]

    func run(
        authorityID: String,
        operation: @escaping @MainActor @Sendable () async throws -> ToolResult
    ) async throws -> ToolResult {
        try Task.checkCancellation()
        if let retiring = retiring[authorityID] {
            await retiring.task.value
            try Task.checkCancellation()
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if var flight = flights[authorityID] {
                    flight.waiters[waiterID] = continuation
                    flights[authorityID] = flight
                    return
                }
                let flightID = UUID()
                let task = Task {
                    let result: Result<ToolResult, Error>
                    do {
                        result = .success(try await operation())
                    } catch {
                        result = .failure(error)
                    }
                    self.finish(authorityID: authorityID, flightID: flightID, result: result)
                }
                flights[authorityID] = Flight(
                    id: flightID,
                    task: task,
                    waiters: [waiterID: continuation]
                )
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID, authorityID: authorityID) }
        }
    }

    private func cancel(waiterID: UUID, authorityID: String) {
        guard var flight = flights[authorityID],
              let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: authorityID)
            retiring[authorityID] = RetiringFlight(
                id: flight.id,
                task: flight.task
            )
            flight.task.cancel()
        } else {
            flights[authorityID] = flight
        }
    }

    private func finish(
        authorityID: String,
        flightID: UUID,
        result: Result<ToolResult, Error>
    ) {
        if retiring[authorityID]?.id == flightID {
            retiring.removeValue(forKey: authorityID)
        }
        guard let flight = flights[authorityID], flight.id == flightID else { return }
        flights.removeValue(forKey: authorityID)
        for waiter in flight.waiters.values {
            waiter.resume(with: result)
        }
    }
}

extension ToolExecutor {
    func runMireloAudio(
        _ editor: EditorViewModel,
        _ args: [String: Any],
        origin: ToolCallOrigin
    ) async throws -> ToolResult {
        guard let operation = MireloOperation(
            rawValue: try args.requireString("operation")
        ) else {
            throw ToolError("Unknown Mirelo operation.")
        }
        let logicalJobID = try args.requireString("logicalJobId")
        guard UUID(uuidString: logicalJobID) != nil else {
            throw ToolError("logicalJobId must be a UUID.")
        }
        guard let projectKey = editor.projectId,
              let workingRoot = editor.workingRoot,
              let workingCopyKey = editor.openWorkingCopyKey else {
            throw ToolError(MediaImportError.projectMustBeSaved.localizedDescription)
        }
        let mutationScope = try GenerationProjectMutationScope(
            projectHome: workingRoot,
            editor: editor
        )
        let invocationIntent = try mireloInvocationIntent(
            operation: operation,
            args: args
        )
        let store = try mireloStoreProvider()
        var existingRecord = try store.load(
            projectKey: projectKey,
            logicalJobID: logicalJobID
        )
        if let existing = existingRecord {
            guard existing.operation == operation,
                  existing.intentBody == invocationIntent else {
                throw ToolError(
                    "logicalJobId already identifies a different Mirelo request. Reuse it only with the same operation, model, prompt, options, and source ids."
                )
            }
            if existing.state == .completed {
                try mutationScope.requireCurrent(editor: editor)
                return try mireloCompletedResult(existing, editor: editor)
            }
            if existing.state == .failed {
                throw ToolError(
                    existing.lastError
                        ?? "This Mirelo logical job failed. Use a new UUID only for a changed request."
                )
            }
            if !existing.operation.usesIdempotencyKey,
               existing.state == .submitting || existing.state == .acceptanceUnknown {
                throw ToolError(
                    existing.lastError
                        ?? "Mirelo may have accepted this Audio-to-MIDI job, but NexGenVideo did not receive its job id. Reconcile Mirelo usage before choosing a new logical job id."
                )
            }
        }
        guard let apiKey = mireloAPIKeyProvider(), !apiKey.isEmpty else {
            throw ToolError(
                "Add a Mirelo API key in Settings → Providers and wait for connection verification."
            )
        }
        let client = mireloClientProvider(apiKey)
        if let existing = existingRecord,
           existing.approvedAt != nil,
           let transactionID = existing.spendTransactionID {
            try mutationScope.requireCurrent(editor: editor)
            let target = mireloTarget(
                modelID: try mireloModelID(existing),
                endpoint: existing.operation.createPath
            )
            if existing.state == .prepared, existing.providerJobID == nil {
                return try await resumePreparedMireloRecord(
                    existing,
                    store: store,
                    client: client,
                    transactionID: transactionID,
                    target: target,
                    origin: origin,
                    editor: editor,
                    folderID: try resolveFolderId(args, editor: editor),
                    workingRoot: workingRoot,
                    workingCopyKey: workingCopyKey,
                    mutationScope: mutationScope
                )
            }
            let authorization = try mireloExistingAuthorization(
                transactionID: transactionID,
                target: target,
                record: existing,
                editor: editor,
                mutationScope: mutationScope
            )
            return try await executeMireloRecord(
                existing,
                store: store,
                client: client,
                authorization: authorization,
                editor: editor,
                folderID: try resolveFolderId(args, editor: editor),
                workingRoot: workingRoot,
                workingCopyKey: workingCopyKey
            )
        }

        let prompt = (args.string("prompt") ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if operation == .audioToMIDI, !prompt.isEmpty {
            throw ToolError(
                "Audio-to-MIDI takes audio as its source and does not accept a content prompt."
            )
        }

        let internalModelID: String?
        let providerModel: MireloModel?
        if operation == .audioToMIDI {
            guard args.string("model") == nil else {
                throw ToolError(
                    "Audio-to-MIDI uses its versioned transcription contract, not a v3 generation model."
                )
            }
            internalModelID = nil
            providerModel = nil
        } else {
            let requested = try args.requireString("model")
            guard let model = MireloCapabilityCatalog.shared.model(id: requested) else {
                throw ToolError(
                    "Mirelo model '\(requested)' is not in the connected account's current catalog. Refresh Providers and choose from list_models."
                )
            }
            internalModelID = "mirelo/\(model.id)"
            providerModel = model
        }

        let compiledPrompt: String?
        if prompt.isEmpty {
            if operation == .textToSFX {
                throw ToolError("text-to-sfx requires a compiled prompt.")
            }
            compiledPrompt = nil
        } else {
            guard let modelID = internalModelID else {
                throw ToolError("This Mirelo operation does not accept a prompt.")
            }
            let value = try await validatedMireloPrompt(
                args: args,
                prompt: prompt,
                modelID: modelID,
                editor: editor
            )
            try mutationScope.requireCurrent(editor: editor)
            compiledPrompt = value
        }

        let sources = try mireloSources(
            operation: operation,
            args: args,
            editor: editor
        )
        let snapshot = try await GenerationReferenceSnapshot.prepare(
            references: sources.map(\.asset)
        )
        try mutationScope.requireCurrent(editor: editor)
        let sourceReceipts = try uploadedReceipts(
            sources,
            snapshot: snapshot,
            workingRoot: workingRoot
        )
        let durationMS: Int?
        if operation == .audioToMIDI {
            guard !sources.isEmpty else {
                throw ToolError("Audio-to-MIDI requires an audio source.")
            }
            durationMS = try await mireloDurationMS(
                frozenURL: snapshot.urls[0]
            )
            guard let durationMS, (1...1_800_000).contains(durationMS) else {
                throw ToolError(
                    "Audio-to-MIDI accepts source audio from 1 ms through 30 minutes."
                )
            }
            _ = try MireloRequestBuilder.audioToMIDI(
                assetID: "local-validation",
                timing: args.string("timing") ?? "performance",
                subdivision: args.string("subdivision"),
                timeSignatureNumerator: args.int("timeSignatureNumerator"),
                timeSignatureDenominator: args.int("timeSignatureDenominator"),
                fixedTempo: args.bool("fixedTempo") ?? false,
                fixedTempoBPM: args.double("fixedTempoBpm"),
                optimizeMusicXML: args.bool("optimizeMusicXML") ?? false,
                scorePDFs: args.bool("scorePDFs") ?? false,
                pageSize: args.string("pageSize") ?? "a4",
                instruments: args.stringArray("instruments").nilIfEmpty
            )
        } else {
            durationMS = args.int("durationMs")
            guard let model = providerModel else {
                throw ToolError("The selected Mirelo model is unavailable.")
            }
            let numVariants = args.int("numVariants") ?? 1
            try MireloRequestBuilder.validate(
                operation: operation,
                model: model,
                durationMS: durationMS,
                appendDurationMS: args.int("appendDurationMs"),
                regionStartMS: args.int("regionStartMs"),
                regionEndMS: args.int("regionEndMs"),
                numVariants: numVariants,
                prompt: compiledPrompt,
                loop: args.bool("loop") ?? false,
                preserveSpeech: args.bool("preserveSpeech") ?? false
            )
            guard model.formats.contains(args.string("outputFormat") ?? "wav") else {
                throw ToolError(
                    "Mirelo model '\(model.id)' does not offer output format '\(args.string("outputFormat") ?? "wav")'."
                )
            }
            try mireloValidateV3SourceOptions(
                operation: operation,
                sourceCount: sources.count,
                args: args
            )
        }

        let uploaded: [String]
        if let existing = existingRecord {
            guard existing.sources == sourceReceipts else {
                throw ToolError(
                    "logicalJobId already identifies a different Mirelo source. Use a new UUID for changed inputs."
                )
            }
            uploaded = try mireloUploadedIDs(
                requestBody: existing.requestBody,
                operation: operation
            )
        } else {
            try mutationScope.requireCurrent(editor: editor)
            uploaded = try await mireloUploadSources(
                sources,
                snapshot: snapshot,
                client: client,
                editor: editor,
                mutationScope: mutationScope
            )
        }
        try await snapshot.requireUnchanged()
        try mutationScope.requireCurrent(editor: editor)

        let body: Data
        if operation == .audioToMIDI {
            body = try MireloRequestBuilder.audioToMIDI(
                assetID: uploaded[0],
                timing: args.string("timing") ?? "performance",
                subdivision: args.string("subdivision"),
                timeSignatureNumerator: args.int("timeSignatureNumerator"),
                timeSignatureDenominator: args.int("timeSignatureDenominator"),
                fixedTempo: args.bool("fixedTempo") ?? false,
                fixedTempoBPM: args.double("fixedTempoBpm"),
                optimizeMusicXML: args.bool("optimizeMusicXML") ?? false,
                scorePDFs: args.bool("scorePDFs") ?? false,
                pageSize: args.string("pageSize") ?? "a4",
                instruments: args.stringArray("instruments").nilIfEmpty
            )
        } else {
            guard let model = providerModel else {
                throw ToolError("The selected Mirelo model is unavailable.")
            }
            body = try mireloV3Body(
                operation: operation,
                model: model,
                prompt: compiledPrompt,
                uploaded: uploaded,
                args: args
            )
        }

        let preflight: MireloPreflight
        if let existing = existingRecord {
            guard existing.requestBody == body else {
                throw ToolError(
                    "logicalJobId already identifies different Mirelo options. Use a new UUID for changed inputs."
                )
            }
        }
        do {
            preflight = try await client.preflight(
                operation: operation,
                body: body,
                durationMS: durationMS
            )
        } catch let error as MireloHTTPError {
            throw ToolError(mireloActionableError(error))
        }
        try mutationScope.requireCurrent(editor: editor)
        try requireMireloFunding(
            preflight,
            account: MireloCapabilityCatalog.shared.account
        )
        if let existing = existingRecord {
            existingRecord = try store.refreshPreflight(existing, with: preflight)
        }

        let record = try await MireloExecutionCoordinator.shared.prepare(
            store: store,
            projectKey: projectKey,
            logicalJobID: logicalJobID,
            operation: operation,
            intentBody: invocationIntent,
            requestBody: body,
            sources: sourceReceipts,
            preflight: preflight
        )
        if record.state == .completed {
            return try mireloCompletedResult(record, editor: editor)
        }

        let modelID = internalModelID ?? "mirelo/audio-to-midi/v1.0"
        let target = mireloTarget(
            modelID: modelID,
            endpoint: operation.createPath
        )
        let option = SpendOption(
            modelId: modelID,
            modelName: operation == .audioToMIDI
                ? "Mirelo Audio-to-MIDI Pro"
                : "Mirelo \(providerModel?.id ?? operation.rawValue)",
            target: target,
            credits: preflight.credits,
            requiresCatalogAvailability: false
        )

        if record.approvedAt != nil, let transactionID = record.spendTransactionID {
            let authorization = try mireloExistingAuthorization(
                transactionID: transactionID,
                target: target,
                record: record,
                editor: editor,
                mutationScope: mutationScope
            )
            return try await executeMireloRecord(
                record,
                store: store,
                client: client,
                authorization: authorization,
                editor: editor,
                folderID: try resolveFolderId(args, editor: editor),
                workingRoot: workingRoot,
                workingCopyKey: workingCopyKey
            )
        }

        return try await withSpendApproval(
            editor,
            currentModelId: modelID,
            currentModelName: option.modelName,
            credits: preflight.credits,
            actionLabel: operation == .audioToMIDI
                ? "Transcribe audio to MIDI"
                : "Run Mirelo \(operation.rawValue)",
            selectionScope: .audio,
            pipelineTool: .runMireloAudio,
            origin: origin,
            alternatives: { [] },
            exactOptions: { [option] },
            recommendedTarget: target,
            execute: { editor, _ in
                try mutationScope.requireCurrent(editor: editor)
                let currentPreflight: MireloPreflight
                let currentAccount: MireloAccount
                do {
                    async let quoted = client.preflight(
                        operation: operation,
                        body: body,
                        durationMS: durationMS
                    )
                    async let account = client.account()
                    (currentPreflight, currentAccount) = try await (quoted, account)
                } catch let error as MireloHTTPError {
                    throw ToolError(self.mireloActionableError(error))
                }
                try mutationScope.requireCurrent(editor: editor)
                try self.requireMireloFunding(
                    currentPreflight,
                    account: currentAccount
                )
                guard currentPreflight.credits == preflight.credits else {
                    throw ToolError(
                        "Mirelo's current preflight is \(currentPreflight.credits) credits, not the reviewed \(preflight.credits). Review this logical job again; no provider request was submitted."
                    )
                }
                let refreshedRecord = try store.refreshPreflight(
                    record,
                    with: currentPreflight
                )
                try mutationScope.requireCurrent(editor: editor)
                let authorization = try GenerationBudgetGuard.authorizeUnknownPaidOperation(
                    modelId: modelID,
                    provider: .mirelo,
                    transport: .api,
                    endpoint: operation.createPath,
                    editor: editor
                )
                guard let transactionID = authorization.transactionId else {
                    throw ToolError("The saved project could not create a spend transaction.")
                }
                let approvedRecord: MireloExecutionRecord
                do {
                    approvedRecord = try await MireloExecutionCoordinator.shared.approve(
                        store: store,
                        record: refreshedRecord,
                        spendTransactionID: transactionID
                    )
                } catch {
                    let approvalError = error
                    let current: MireloExecutionRecord?
                    do {
                        current = try store.load(
                            projectKey: projectKey,
                            logicalJobID: logicalJobID
                        )
                    } catch {
                        throw ToolError(
                            "\(approvalError.localizedDescription) Mirelo approval could not be verified, so the spend reservation remains active: \(error.localizedDescription)"
                        )
                    }
                    if let current,
                       current.spendTransactionID == transactionID,
                       current.approvedAt != nil {
                        approvedRecord = current
                    } else {
                        do {
                            try editor.releaseUnsubmittedSpendReservation(
                                authorization: authorization,
                                placeholders: [],
                                note: "Mirelo execution approval could not be persisted."
                            )
                        } catch {
                            throw ToolError(
                                "\(approvalError.localizedDescription) The unused spend reservation could not be released: \(error.localizedDescription)"
                            )
                        }
                        throw approvalError
                    }
                }
                return try await self.executeMireloRecord(
                    approvedRecord,
                    store: store,
                    client: client,
                    authorization: authorization,
                    editor: editor,
                    folderID: try self.resolveFolderId(args, editor: editor),
                    workingRoot: workingRoot,
                    workingCopyKey: workingCopyKey
                )
            }
        )
    }

    private func resumePreparedMireloRecord(
        _ record: MireloExecutionRecord,
        store: MireloExecutionStore,
        client: MireloClient,
        transactionID: String,
        target: ResolvedGenerationTarget,
        origin: ToolCallOrigin,
        editor: EditorViewModel,
        folderID: String?,
        workingRoot: URL,
        workingCopyKey: String,
        mutationScope: GenerationProjectMutationScope
    ) async throws -> ToolResult {
        let durationMS = try await mireloStoredPreflightDuration(
            record,
            workingRoot: workingRoot
        )
        try mutationScope.requireCurrent(editor: editor)
        let currentPreflight: MireloPreflight
        let currentAccount: MireloAccount
        do {
            async let quoted = client.preflight(
                operation: record.operation,
                body: record.requestBody,
                durationMS: durationMS
            )
            async let account = client.account()
            (currentPreflight, currentAccount) = try await (quoted, account)
        } catch let error as MireloHTTPError {
            throw ToolError(mireloActionableError(error))
        }
        try mutationScope.requireCurrent(editor: editor)
        try requireMireloFunding(currentPreflight, account: currentAccount)

        if currentPreflight.credits == record.preflight.credits {
            let refreshed = try store.refreshApprovedPreflight(
                record,
                with: currentPreflight,
                creditChangeApproved: false
            )
            let authorization = try mireloExistingAuthorization(
                transactionID: transactionID,
                target: target,
                record: refreshed,
                editor: editor,
                mutationScope: mutationScope
            )
            return try await executeMireloRecord(
                refreshed,
                store: store,
                client: client,
                authorization: authorization,
                editor: editor,
                folderID: folderID,
                workingRoot: workingRoot,
                workingCopyKey: workingCopyKey
            )
        }

        let modelID = try mireloModelID(record)
        let option = SpendOption(
            modelId: modelID,
            modelName: record.operation == .audioToMIDI
                ? "Mirelo Audio-to-MIDI Pro"
                : "Mirelo \(modelID.replacingOccurrences(of: "mirelo/", with: ""))",
            target: target,
            credits: currentPreflight.credits,
            requiresCatalogAvailability: false
        )
        return try await withSpendApproval(
            editor,
            currentModelId: modelID,
            currentModelName: option.modelName,
            credits: currentPreflight.credits,
            actionLabel: "Approve changed Mirelo cost",
            selectionScope: .audio,
            pipelineTool: .runMireloAudio,
            origin: origin,
            forceApproval: true,
            alternatives: { [] },
            exactOptions: { [option] },
            recommendedTarget: target,
            execute: { editor, reviewed in
                try mutationScope.requireCurrent(editor: editor)
                let verifiedPreflight: MireloPreflight
                let verifiedAccount: MireloAccount
                do {
                    async let quoted = client.preflight(
                        operation: record.operation,
                        body: record.requestBody,
                        durationMS: durationMS
                    )
                    async let account = client.account()
                    (verifiedPreflight, verifiedAccount) = try await (quoted, account)
                } catch let error as MireloHTTPError {
                    throw ToolError(self.mireloActionableError(error))
                }
                try mutationScope.requireCurrent(editor: editor)
                try self.requireMireloFunding(
                    verifiedPreflight,
                    account: verifiedAccount
                )
                guard verifiedPreflight.credits == reviewed.credits else {
                    throw ToolError(
                        "Mirelo's current preflight changed again to \(verifiedPreflight.credits) credits. Review the updated cost; no provider request was submitted."
                    )
                }
                let refreshed = try store.refreshApprovedPreflight(
                    record,
                    with: verifiedPreflight,
                    creditChangeApproved: true
                )
                let authorization = try self.mireloExistingAuthorization(
                    transactionID: transactionID,
                    target: target,
                    record: refreshed,
                    editor: editor,
                    mutationScope: mutationScope
                )
                return try await self.executeMireloRecord(
                    refreshed,
                    store: store,
                    client: client,
                    authorization: authorization,
                    editor: editor,
                    folderID: folderID,
                    workingRoot: workingRoot,
                    workingCopyKey: workingCopyKey
                )
            }
        )
    }

    private func mireloStoredPreflightDuration(
        _ record: MireloExecutionRecord,
        workingRoot: URL
    ) async throws -> Int? {
        guard record.operation == .audioToMIDI else { return nil }
        guard let source = record.sources.first else {
            throw ToolError("The saved Mirelo Audio-to-MIDI request has no source receipt.")
        }
        let url = workingRoot.appendingPathComponent(source.projectPath)
        guard try mireloProjectPath(url, root: workingRoot) == source.projectPath,
              FileManager.default.fileExists(atPath: url.path),
              try FileDigest.sha256(of: url) == source.sha256 else {
            throw ToolError(
                "Restore the exact saved audio source before checking the first Audio-to-MIDI submission."
            )
        }
        return try await mireloDurationMS(frozenURL: url)
    }

    private struct MireloSource {
        let role: String
        let asset: MediaAsset
    }

    func validatedMireloPrompt(
        args: [String: Any],
        prompt: String,
        modelID: String,
        editor: EditorViewModel
    ) async throws -> String {
        let value = try await Self.agentPrompt(
            args,
            prompt: prompt,
            modality: .audio,
            modelId: modelID,
            editor: editor
        )
        try await PromptCompiler.enforceGate(
            args: args,
            prompt: prompt,
            modelId: modelID,
            editor: editor
        )
        return value.precompiled?.text ?? prompt
    }

    private func mireloSources(
        operation: MireloOperation,
        args: [String: Any],
        editor: EditorViewModel
    ) throws -> [MireloSource] {
        switch operation {
        case .textToSFX:
            guard args.string("sourceMediaRef") == nil,
                  args.string("videoSourceMediaRef") == nil else {
                throw ToolError("text-to-sfx does not take source media.")
            }
            return []
        case .videoToSFX:
            let asset = try asset(
                try args.requireString("sourceMediaRef"),
                editor: editor,
                label: "Video source"
            )
            guard asset.type == .video else {
                throw ToolError("video-to-sfx requires a video source.")
            }
            return [.init(role: "video", asset: asset)]
        case .extend, .inpaint:
            let audio = try asset(
                try args.requireString("sourceMediaRef"),
                editor: editor,
                label: "Audio source"
            )
            guard audio.type == .audio else {
                throw ToolError("\(operation.rawValue) requires an audio source.")
            }
            var sources = [MireloSource(role: "audio", asset: audio)]
            if let videoRef = args.string("videoSourceMediaRef") {
                let video = try asset(videoRef, editor: editor, label: "Video source")
                guard video.type == .video else {
                    throw ToolError("videoSourceMediaRef must identify a video asset.")
                }
                sources.append(.init(role: "video", asset: video))
            }
            return sources
        case .audioToMIDI:
            let audio = try asset(
                try args.requireString("sourceMediaRef"),
                editor: editor,
                label: "Audio source"
            )
            guard audio.type == .audio else {
                throw ToolError("Audio-to-MIDI requires an audio source.")
            }
            guard args.string("videoSourceMediaRef") == nil else {
                throw ToolError("Audio-to-MIDI does not take a video source.")
            }
            return [.init(role: "audio", asset: audio)]
        }
    }

    private func mireloUploadSources(
        _ sources: [MireloSource],
        snapshot: GenerationReferenceSnapshot,
        client: MireloClient,
        editor: EditorViewModel,
        mutationScope: GenerationProjectMutationScope
    ) async throws -> [String] {
        guard sources.count == snapshot.urls.count else {
            throw ToolError("Mirelo source snapshot is incomplete.")
        }
        var uploaded: [String] = []
        for url in snapshot.urls {
            try mutationScope.requireCurrent(editor: editor)
            let ticket = try await client.createAsset(for: url)
            try mutationScope.requireCurrent(editor: editor)
            try await client.upload(url, ticket: ticket)
            try mutationScope.requireCurrent(editor: editor)
            uploaded.append(ticket.id)
        }
        return uploaded
    }

    private func mireloValidateV3SourceOptions(
        operation: MireloOperation,
        sourceCount: Int,
        args: [String: Any]
    ) throws {
        switch operation {
        case .extend:
            if sourceCount > 1, args.bool("loop") == true {
                throw ToolError("Mirelo extend cannot combine loop with a conditioning video.")
            }
            if sourceCount == 1, (args.int("startOffsetMs") ?? 0) != 0 {
                throw ToolError("Mirelo extend startOffsetMs requires a conditioning video.")
            }
        case .textToSFX, .videoToSFX, .inpaint, .audioToMIDI:
            break
        }
    }

    private func mireloInvocationIntent(
        operation: MireloOperation,
        args: [String: Any]
    ) throws -> Data {
        var value: [String: Any] = [
            "operation": operation.rawValue,
            "prompt": (args.string("prompt") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            "shotId": args.string("shotId") ?? "none",
            "rawPrompt": args.bool("rawPrompt") ?? false,
        ]
        func assign(_ key: String, _ item: Any?) {
            if let item { value[key] = item }
        }
        assign("folderId", args.string("folderId"))
        switch operation {
        case .textToSFX:
            assign("model", args.string("model").map(ModelCatalog.deriveLogicalId))
            assign("durationMs", args.int("durationMs"))
            value["numVariants"] = args.int("numVariants") ?? 1
            value["loop"] = args.bool("loop") ?? false
            value["outputFormat"] = args.string("outputFormat") ?? "wav"
        case .videoToSFX:
            assign("model", args.string("model").map(ModelCatalog.deriveLogicalId))
            assign("sourceMediaRef", args.string("sourceMediaRef"))
            assign("durationMs", args.int("durationMs"))
            value["startOffsetMs"] = args.int("startOffsetMs") ?? 0
            value["numVariants"] = args.int("numVariants") ?? 1
            value["preserveSpeech"] = args.bool("preserveSpeech") ?? false
            value["outputFormat"] = args.string("outputFormat") ?? "wav"
        case .extend:
            assign("model", args.string("model").map(ModelCatalog.deriveLogicalId))
            assign("sourceMediaRef", args.string("sourceMediaRef"))
            assign("videoSourceMediaRef", args.string("videoSourceMediaRef"))
            assign("appendDurationMs", args.int("appendDurationMs"))
            value["startOffsetMs"] = args.int("startOffsetMs") ?? 0
            value["numVariants"] = args.int("numVariants") ?? 1
            value["loop"] = args.bool("loop") ?? false
            value["outputFormat"] = args.string("outputFormat") ?? "wav"
        case .inpaint:
            assign("model", args.string("model").map(ModelCatalog.deriveLogicalId))
            assign("sourceMediaRef", args.string("sourceMediaRef"))
            assign("videoSourceMediaRef", args.string("videoSourceMediaRef"))
            assign("regionStartMs", args.int("regionStartMs"))
            assign("regionEndMs", args.int("regionEndMs"))
            value["numVariants"] = args.int("numVariants") ?? 1
            value["outputFormat"] = args.string("outputFormat") ?? "wav"
        case .audioToMIDI:
            assign("sourceMediaRef", args.string("sourceMediaRef"))
            value["timing"] = args.string("timing") ?? "performance"
            assign("subdivision", args.string("subdivision"))
            assign("timeSignatureNumerator", args.int("timeSignatureNumerator"))
            assign("timeSignatureDenominator", args.int("timeSignatureDenominator"))
            value["fixedTempo"] = args.bool("fixedTempo") ?? false
            assign("fixedTempoBpm", args.double("fixedTempoBpm"))
            value["optimizeMusicXML"] = args.bool("optimizeMusicXML") ?? false
            value["scorePDFs"] = args.bool("scorePDFs") ?? false
            value["pageSize"] = args.string("pageSize") ?? "a4"
            assign("instruments", args.stringArray("instruments").nilIfEmpty)
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func mireloUploadedIDs(
        requestBody: Data,
        operation: MireloOperation
    ) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(
            with: requestBody
        ) as? [String: Any] else {
            throw ToolError("The saved Mirelo request body is unreadable.")
        }
        if operation == .textToSFX { return [] }
        guard let input = root[operation == .audioToMIDI ? "audio" : "input"] as? [String: Any] else {
            throw ToolError("The saved Mirelo request has no source reference.")
        }
        if operation == .audioToMIDI {
            guard let id = input["asset_id"] as? String else {
                throw ToolError("The saved Mirelo Audio-to-MIDI asset is unreadable.")
            }
            return [id]
        }
        if operation == .videoToSFX {
            guard let video = input["video"] as? [String: Any],
                  let id = video["id"] as? String else {
                throw ToolError("The saved Mirelo video asset is unreadable.")
            }
            return [id]
        }
        guard let audio = input["audio"] as? [String: Any],
              let audioID = audio["id"] as? String else {
            throw ToolError("The saved Mirelo audio asset is unreadable.")
        }
        if let video = input["video"] as? [String: Any],
           let videoID = video["id"] as? String {
            return [audioID, videoID]
        }
        return [audioID]
    }

    private func uploadedReceipts(
        _ sources: [MireloSource],
        snapshot: GenerationReferenceSnapshot,
        workingRoot: URL
    ) throws -> [MireloSourceReceipt] {
        try zip(sources, snapshot.receipts).map { source, receipt in
            let path = try mireloProjectPath(source.asset.url, root: workingRoot)
            return MireloSourceReceipt(
                mediaAssetID: source.asset.id,
                projectPath: path,
                sha256: receipt.sourceSHA256,
                type: source.asset.type
            )
        }
    }

    private func mireloV3Body(
        operation: MireloOperation,
        model: MireloModel,
        prompt: String?,
        uploaded: [String],
        args: [String: Any]
    ) throws -> Data {
        let format = args.string("outputFormat") ?? "wav"
        let variants = args.int("numVariants") ?? 1
        switch operation {
        case .textToSFX:
            return try MireloRequestBuilder.textToSFX(
                model: model.id,
                prompt: prompt ?? "",
                durationMS: try args.requireInt("durationMs"),
                numVariants: variants,
                loop: args.bool("loop") ?? false,
                outputFormat: format
            )
        case .videoToSFX:
            guard let source = uploaded.first else {
                throw ToolError("The Mirelo video upload is missing.")
            }
            return try MireloRequestBuilder.videoToSFX(
                model: model.id,
                assetID: source,
                prompt: prompt,
                durationMS: try args.requireInt("durationMs"),
                startOffsetMS: args.int("startOffsetMs") ?? 0,
                numVariants: variants,
                preserveSpeech: args.bool("preserveSpeech") ?? false,
                outputFormat: format
            )
        case .extend:
            guard let source = uploaded.first else {
                throw ToolError("The Mirelo audio upload is missing.")
            }
            if uploaded.indices.contains(1), args.bool("loop") == true {
                throw ToolError("Mirelo extend cannot combine loop with a conditioning video.")
            }
            if !uploaded.indices.contains(1), (args.int("startOffsetMs") ?? 0) != 0 {
                throw ToolError("Mirelo extend startOffsetMs requires a conditioning video.")
            }
            return try MireloRequestBuilder.extend(
                model: model.id,
                audioAssetID: source,
                videoAssetID: uploaded.indices.contains(1) ? uploaded[1] : nil,
                prompt: prompt,
                appendDurationMS: try args.requireInt("appendDurationMs"),
                startOffsetMS: args.int("startOffsetMs") ?? 0,
                numVariants: variants,
                loop: args.bool("loop") ?? false,
                outputFormat: format
            )
        case .inpaint:
            guard let source = uploaded.first else {
                throw ToolError("The Mirelo audio upload is missing.")
            }
            return try MireloRequestBuilder.inpaint(
                model: model.id,
                audioAssetID: source,
                videoAssetID: uploaded.indices.contains(1) ? uploaded[1] : nil,
                prompt: prompt,
                regionStartMS: try args.requireInt("regionStartMs"),
                regionEndMS: try args.requireInt("regionEndMs"),
                numVariants: variants,
                outputFormat: format
            )
        case .audioToMIDI:
            throw ToolError("Audio-to-MIDI does not use a v3 request body.")
        }
    }

    private func executeMireloRecord(
        _ record: MireloExecutionRecord,
        store: MireloExecutionStore,
        client: MireloClient,
        authorization: GenerationAuthorization,
        editor: EditorViewModel,
        folderID: String?,
        workingRoot: URL,
        workingCopyKey: String
    ) async throws -> ToolResult {
        try await MireloToolExecutionCoalescer.shared.run(
            authorityID: record.authorityID
        ) { @MainActor in
            try await self.executeMireloRecordOwned(
                record,
                store: store,
                client: client,
                authorization: authorization,
                editor: editor,
                folderID: folderID,
                workingRoot: workingRoot,
                workingCopyKey: workingCopyKey
            )
        }
    }

    private func executeMireloRecordOwned(
        _ record: MireloExecutionRecord,
        store: MireloExecutionStore,
        client: MireloClient,
        authorization: GenerationAuthorization,
        editor: EditorViewModel,
        folderID: String?,
        workingRoot: URL,
        workingCopyKey: String
    ) async throws -> ToolResult {
        do {
            try authorization.projectMutationScope?.requireCurrent(editor: editor)
            var outcome = try await MireloExecutionCoordinator.shared.execute(
                store: store,
                projectKey: record.projectKey,
                logicalJobID: record.logicalJobID,
                client: client,
                onAccepted: { accepted in
                    try authorization.projectMutationScope?.requireCurrent(editor: editor)
                    try self.mireloRecordSubmittedIfNeeded(
                        accepted,
                        authorization: authorization,
                        editor: editor
                    )
                }
            )
            try mireloRecordSubmittedIfNeeded(
                outcome.record,
                authorization: authorization,
                editor: editor
            )
            try authorization.projectMutationScope?.requireCurrent(editor: editor)
            let artifacts: [MireloArtifact]
            do {
                artifacts = try await installMireloArtifacts(
                    operation: record.operation,
                    logicalJobID: record.logicalJobID,
                    terminalResponse: outcome.terminalResponse,
                    editor: editor,
                    folderID: folderID,
                    workingRoot: workingRoot,
                    workingCopyKey: workingCopyKey,
                    mutationScope: authorization.projectMutationScope
                )
            } catch is MireloResultURLExpired {
                outcome = try await MireloExecutionCoordinator.shared.refreshResult(
                    store: store,
                    record: outcome.record,
                    client: client
                )
                do {
                    artifacts = try await installMireloArtifacts(
                        operation: record.operation,
                        logicalJobID: record.logicalJobID,
                        terminalResponse: outcome.terminalResponse,
                        editor: editor,
                        folderID: folderID,
                        workingRoot: workingRoot,
                        workingCopyKey: workingCopyKey,
                        mutationScope: authorization.projectMutationScope
                    )
                } catch is MireloResultURLExpired {
                    throw ToolError(
                        "Mirelo refreshed the result links, but a refreshed link is already unavailable. Resume this logical job later; it was not resubmitted."
                    )
                }
            }
            try authorization.projectMutationScope?.requireCurrent(editor: editor)
            let completed = try await MireloExecutionCoordinator.shared.complete(
                store: store,
                record: outcome.record,
                artifacts: artifacts
            )
            try authorization.projectMutationScope?.requireCurrent(editor: editor)
            return try mireloCompletedResult(completed, editor: editor)
        } catch {
            let executionError = error
            do {
                guard let current = try store.load(
                    projectKey: record.projectKey,
                    logicalJobID: record.logicalJobID
                ) else {
                    throw GenerationRequestError.storage(
                        "The Mirelo execution authority disappeared before spend could be reconciled."
                    )
                }
                try mireloRecordSubmittedIfNeeded(
                    current,
                    authorization: authorization,
                    editor: editor
                )
                if current.providerJobID == nil,
                   current.state == .failed {
                    try editor.releaseUnsubmittedSpendReservation(
                        authorization: authorization,
                        preserveMireloExecutionIdentity: true,
                        note: current.lastError
                    )
                }
            } catch {
                throw ToolError(
                    "\(executionError.localizedDescription) Mirelo spend reconciliation remains unresolved: \(error.localizedDescription)"
                )
            }
            throw ToolError(executionError.localizedDescription)
        }
    }

    func installMireloArtifacts(
        operation: MireloOperation,
        logicalJobID: String,
        terminalResponse: Data,
        editor: EditorViewModel,
        folderID: String?,
        workingRoot: URL,
        workingCopyKey: String,
        mutationScope: GenerationProjectMutationScope?,
        download: MireloResultDownload? = nil
    ) async throws -> [MireloArtifact] {
        let descriptors = try MireloResultParser.descriptors(
            operation: operation,
            terminalResponse: terminalResponse
        )
        guard Set(descriptors.map(\.filename)).count == descriptors.count else {
            throw ToolError("Mirelo returned colliding result filenames.")
        }
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MireloResults-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        var artifacts: [MireloArtifact] = []
        var stagedResults: [(MireloResultDescriptor, URL, String)] = []
        do {
            for descriptor in descriptors {
                try Task.checkCancellation()
                let staged: URL
                if let embedded = descriptor.embeddedData {
                    staged = stagingRoot.appendingPathComponent(descriptor.filename)
                    try embedded.write(to: staged, options: .atomic)
                } else if let remote = descriptor.remoteURL {
                    do {
                        let result: RemoteMediaDownloader.Download
                        if let download {
                            result = try await download(
                                remote,
                                mireloDownloadLimit(descriptor.kind),
                                Self.importDownloadTimeout
                            )
                        } else {
                            result = try await RemoteMediaDownloader.download(
                                remote,
                                maxBytes: mireloDownloadLimit(descriptor.kind),
                                timeout: Self.importDownloadTimeout
                            )
                        }
                        try Task.checkCancellation()
                        staged = stagingRoot.appendingPathComponent(descriptor.filename)
                        try FileManager.default.moveItem(
                            at: result.temporaryURL,
                            to: staged
                        )
                        if descriptor.kind == .scoreManifest {
                            let stable = try MireloResultParser.stableJSONArtifact(
                                try Data(contentsOf: staged)
                            )
                            try stable.write(to: staged, options: .atomic)
                        }
                    } catch RemoteMediaPolicy.PolicyError.httpStatus(let status)
                        where [403, 404, 410].contains(status) {
                        throw MireloResultURLExpired()
                    }
                } else {
                    throw ToolError("Mirelo result descriptor has no payload.")
                }
                try await validateMireloArtifact(staged, kind: descriptor.kind)
                try Task.checkCancellation()
                let digest: String
                do {
                    digest = try FileDigest.sha256(of: staged)
                } catch {
                    try? FileManager.default.removeItem(at: staged)
                    throw error
                }
                if let expected = descriptor.expectedSHA256,
                   expected.lowercased() != digest.lowercased() {
                    try? FileManager.default.removeItem(at: staged)
                    throw ToolError(
                        "Mirelo result '\(descriptor.filename)' failed its SHA-256 check."
                    )
                }
                stagedResults.append((descriptor, staged, digest))
            }
        } catch {
            throw error
        }

        try Task.checkCancellation()
        try mutationScope?.requireCurrent(editor: editor)
        let artifactFolderPath = "\(Project.mediaDirectoryName)/Mirelo/\(logicalJobID)"
        let artifactFolder = workingRoot.appendingPathComponent(
            artifactFolderPath,
            isDirectory: true
        )
        for (descriptor, _, digest) in stagedResults {
            let destination = artifactFolder.appendingPathComponent(
                descriptor.filename,
                isDirectory: false
            )
            if FileManager.default.fileExists(atPath: destination.path),
               try FileDigest.sha256(of: destination) != digest {
                throw ToolError(
                    "Project artifact '\(descriptor.filename)' already exists with different bytes. Restore or reconcile this logical job before retrying."
                )
            }
        }

        try mutationScope?.requireCurrent(editor: editor)
        try ProjectWorkingCopy.markDirty(key: workingCopyKey)
        _ = try ProjectLocalFile.ensureDirectory(
            artifactFolderPath,
            dataRoot: workingRoot
        )

        for (descriptor, staged, digest) in stagedResults {
            try Task.checkCancellation()
            try mutationScope?.requireCurrent(editor: editor)
            let destination = artifactFolder.appendingPathComponent(
                descriptor.filename,
                isDirectory: false
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try FileDigest.sha256(of: destination) == digest else {
                    throw ToolError(
                        "Project artifact '\(descriptor.filename)' changed during result installation."
                    )
                }
            } else {
                let partial = artifactFolder.appendingPathComponent(
                    ".install-\(UUID().uuidString).partial",
                    isDirectory: false
                )
                defer { try? FileManager.default.removeItem(at: partial) }
                try FileManager.default.copyItem(at: staged, to: partial)
                try FileManager.default.moveItem(at: partial, to: destination)
            }
            try Task.checkCancellation()
            if descriptor.kind == .audio {
                try mutationScope?.requireCurrent(editor: editor)
                let asset: MediaAsset
                if let registered = editor.mediaAssets.first(where: {
                    $0.url.standardizedFileURL == destination.standardizedFileURL
                }) {
                    asset = registered
                } else {
                    asset = try await editor.addMediaAssetThrowing(
                        from: destination,
                        folderId: folderID
                    )
                }
                try mutationScope?.requireCurrent(editor: editor)
                guard asset.url.standardizedFileURL == destination.standardizedFileURL else {
                    throw ToolError(
                        "Mirelo audio was not registered at its deterministic project path."
                    )
                }
                artifacts.append(MireloArtifact(
                    kind: .audio,
                    projectPath: try mireloProjectPath(destination, root: workingRoot),
                    sha256: digest,
                    mediaAssetID: asset.id,
                    sourceURLExpiresAt: descriptor.sourceURLExpiresAt
                ))
                continue
            }
            artifacts.append(MireloArtifact(
                kind: descriptor.kind,
                projectPath: try mireloProjectPath(destination, root: workingRoot),
                sha256: digest,
                mediaAssetID: nil,
                sourceURLExpiresAt: descriptor.sourceURLExpiresAt
            ))
        }
        var uniqueArtifacts: [MireloArtifact] = []
        for artifact in artifacts {
            if let existing = uniqueArtifacts.first(where: {
                $0.projectPath == artifact.projectPath
            }) {
                guard existing.kind == artifact.kind,
                      existing.sha256 == artifact.sha256,
                      existing.mediaAssetID == artifact.mediaAssetID else {
                    throw ToolError(
                        "Mirelo results claim conflicting data at '\(artifact.projectPath)'."
                    )
                }
            } else {
                uniqueArtifacts.append(artifact)
            }
        }
        try mutationScope?.requireCurrent(editor: editor)
        editor.onPipelineChanged?()
        return uniqueArtifacts
    }

    private func mireloDownloadLimit(_ kind: MireloArtifact.Kind) -> Int64 {
        switch kind {
        case .audio, .scoreBundle:
            Self.importDownloadMaxBytes
        case .midi, .musicXML, .noteJSON, .scorePDF, .scoreManifest:
            min(Self.importDownloadMaxBytes, 100 * 1_024 * 1_024)
        }
    }

    private func validateMireloArtifact(
        _ url: URL,
        kind: MireloArtifact.Kind
    ) async throws {
        if kind == .audio {
            try await RemoteMediaPayloadValidator.validate(url, expectedType: .audio)
            return
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw ToolError("Mirelo returned an empty \(kind.rawValue) artifact.")
        }
        let valid: Bool
        switch kind {
        case .audio:
            valid = true
        case .midi:
            valid = data.starts(with: Data("MThd".utf8))
        case .musicXML:
            let xml = String(data: data, encoding: .utf8)
            valid = xml?.contains("<score-partwise") == true
                || xml?.contains("<score-timewise") == true
        case .noteJSON, .scoreManifest:
            valid = (try? JSONSerialization.jsonObject(with: data)) != nil
        case .scorePDF:
            valid = data.starts(with: Data("%PDF-".utf8))
        case .scoreBundle:
            valid = data.starts(with: Data([0x50, 0x4b, 0x03, 0x04]))
                || data.starts(with: Data([0x50, 0x4b, 0x05, 0x06]))
        }
        guard valid else {
            throw ToolError("Mirelo returned an invalid \(kind.rawValue) artifact.")
        }
    }

    private func mireloCompletedResult(
        _ record: MireloExecutionRecord,
        editor: EditorViewModel
    ) throws -> ToolResult {
        guard record.state == .completed, !record.artifacts.isEmpty,
              let root = editor.workingRoot else {
            throw ToolError("The Mirelo result is not fully installed in this project.")
        }
        var values: [[String: Any]] = []
        for artifact in record.artifacts {
            let url = root.appendingPathComponent(artifact.projectPath)
            guard FileManager.default.fileExists(atPath: url.path),
                  try FileDigest.sha256(of: url) == artifact.sha256 else {
                throw ToolError(
                    "Mirelo artifact '\(artifact.projectPath)' is missing or changed. Restore the project copy before continuing."
                )
            }
            if let mediaAssetID = artifact.mediaAssetID {
                guard editor.mediaAssets.contains(where: {
                    $0.id == mediaAssetID
                        && $0.url.standardizedFileURL == url.standardizedFileURL
                }) else {
                    throw ToolError(
                        "Mirelo audio '\(artifact.projectPath)' is not registered in the media library. Restore the project copy before continuing."
                    )
                }
            }
            values.append([
                "kind": artifact.kind.rawValue,
                "projectPath": artifact.projectPath,
                "sha256": artifact.sha256,
                "mediaAssetId": artifact.mediaAssetID ?? NSNull(),
            ])
        }
        guard let json = Self.jsonString([
            "logicalJobId": record.logicalJobID,
            "providerJobId": record.providerJobID ?? NSNull(),
            "operation": record.operation.rawValue,
            "preflightCredits": record.preflight.credits,
            "settledCredits": mireloSettledCredits(record) ?? NSNull(),
            "artifacts": values,
        ]) else {
            throw ToolError("Failed to encode the Mirelo result receipt.")
        }
        return .ok(json)
    }

    private func mireloSettledCredits(_ record: MireloExecutionRecord) -> Int? {
        if let terminal = record.terminalResponse,
           let root = try? JSONSerialization.jsonObject(with: terminal) as? [String: Any],
           let credits = root["credits"] as? Int {
            return credits
        }
        return record.operation == .audioToMIDI ? record.preflight.credits : nil
    }

    private func mireloRecordSubmittedIfNeeded(
        _ record: MireloExecutionRecord,
        authorization: GenerationAuthorization,
        editor: EditorViewModel
    ) throws {
        guard let requestID = record.providerJobID,
              let transactionID = authorization.transactionId else { return }
        if let submitted = editor.generationLog.spendEvents.first(where: {
            $0.transactionId == transactionID && $0.kind == .submitted
        }) {
            guard submitted.providerRequestId == requestID else {
                throw ToolError(
                    "The Mirelo provider job does not match the project spend record."
                )
            }
            return
        }
        try authorization.projectMutationScope?.requireCurrent(editor: editor)
        try editor.recordSpendEvent(
            authorization: authorization,
            kind: .submitted,
            providerRequestId: requestID,
            providerRequestResumable: true,
            note: "Mirelo preflight: \(record.preflight.credits) credits. Monetary conversion is not published."
        )
    }

    private func mireloExistingAuthorization(
        transactionID: String,
        target: ResolvedGenerationTarget,
        record: MireloExecutionRecord,
        editor: EditorViewModel,
        mutationScope: GenerationProjectMutationScope
    ) throws -> GenerationAuthorization {
        _ = try GenerationBudgetGuard.verifiedSpend(
            log: editor.generationLog,
            generatedAssets: editor.mediaAssets,
            requireCompleteMoney: false
        )
        let events = editor.generationLog.spendEvents.filter {
            $0.transactionId == transactionID
        }
        guard let first = events.first,
              let last = events.last,
              first.kind == .reserved,
              last.kind == .reserved || last.kind == .submitted,
              events.allSatisfy({
                  $0.model == target.modelId
                      && $0.provider == target.provider
                      && $0.transport == target.transport
                      && $0.endpoint == target.endpoint
              }),
              last.kind != .submitted
                || (record.providerJobID != nil
                    && last.providerRequestId == record.providerJobID) else {
            throw ToolError(
                "The persisted Mirelo job has no matching active project spend approval. Reconcile the project copy before resuming it."
            )
        }
        try mutationScope.requireCurrent(editor: editor)
        return GenerationAuthorization(
            transactionId: transactionID,
            target: target,
            estimate: nil,
            projectMutationScope: mutationScope
        )
    }

    private func mireloTarget(
        modelID: String,
        endpoint: String
    ) -> ResolvedGenerationTarget {
        ResolvedGenerationTarget(
            modelId: modelID,
            provider: .mirelo,
            endpoint: endpoint,
            binding: ProviderBinding(
                provider: .mirelo,
                transport: .api,
                kind: .tool,
                providerRef: endpoint,
                billing: .perCall
            )
        )
    }

    private func mireloModelID(_ record: MireloExecutionRecord) throws -> String {
        if record.operation == .audioToMIDI {
            return "mirelo/audio-to-midi/v1.0"
        }
        guard let root = try JSONSerialization.jsonObject(
            with: record.requestBody
        ) as? [String: Any],
        let model = root["model"] as? String,
        !model.isEmpty else {
            throw ToolError("The saved Mirelo request has no model identity.")
        }
        return model.hasPrefix("mirelo/") ? model : "mirelo/\(model)"
    }

    private func mireloProjectPath(_ url: URL, root: URL) throws -> String {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path
            : canonicalRoot.path + "/"
        guard canonicalURL.path.hasPrefix(prefix) else {
            throw ToolError(
                "Mirelo source and result files must live inside the self-contained project."
            )
        }
        return String(canonicalURL.path.dropFirst(prefix.count))
    }

    private func mireloDurationMS(
        frozenURL: URL
    ) async throws -> Int {
        let duration = try await AVURLAsset(url: frozenURL).load(.duration)
        guard let milliseconds = mireloMilliseconds(duration.seconds) else {
            throw ToolError("Could not measure the source audio duration.")
        }
        return milliseconds
    }

    private func mireloMilliseconds(_ seconds: Double) -> Int? {
        let value = (seconds * 1_000).rounded()
        guard value.isFinite, value >= 1, value <= Double(Int.max) else {
            return nil
        }
        return Int(value)
    }

    private func mireloFundingMessage(_ recovery: MireloCreditRecovery) -> String {
        var message = "Mirelo preflight requires \(recovery.creditsRequired) credits"
        message += "; \(recovery.creditsAvailable) are currently spendable"
        if let action = recovery.recoveryAction {
            message += ". Required action: \(action.replacingOccurrences(of: "_", with: " "))"
        } else if recovery.provisioningState == "pending" {
            message += ". Account credits are still provisioning"
        }
        return message + ". No provider job was submitted."
    }

    private func requireMireloFunding(
        _ preflight: MireloPreflight,
        account: MireloAccount?
    ) throws {
        guard preflight.credits >= 0 else {
            throw ToolError(
                "Mirelo preflight returned an invalid credit amount. No provider job was submitted."
            )
        }
        if let recovery = preflight.creditRecovery,
           recovery.creditsRequired != preflight.credits {
            throw ToolError(
                "Mirelo preflight returned inconsistent funding evidence. No provider job was submitted."
            )
        }
        if let recovery = preflight.creditRecovery, !recovery.canFundRequest {
            throw ToolError(mireloFundingMessage(recovery))
        }
        let billingMode = preflight.billingMode ?? account?.billingMode
        guard billingMode == "metered" || billingMode == "unmetered" else {
            throw ToolError(
                "Mirelo preflight did not identify the account's billing mode. No provider job was submitted."
            )
        }
        if billingMode == "metered", preflight.creditRecovery == nil {
            throw ToolError(
                "Mirelo preflight omitted the metered account's funding decision. No provider job was submitted."
            )
        }
        guard account == nil || account?.provisioningState == "ready" else {
            throw ToolError(
                "Mirelo account provisioning is not ready. No provider job was submitted."
            )
        }
    }

    private func mireloActionableError(_ error: MireloHTTPError) -> String {
        if error.status == 401 {
            return "Mirelo rejected the saved API key. Replace it in Settings → Providers."
        }
        if error.status == 402, let recovery = error.creditRecovery {
            return mireloFundingMessage(recovery)
        }
        if error.status == 429 {
            return "Mirelo rate-limited the request. No job was submitted. \(error.localizedDescription)"
        }
        return error.localizedDescription
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

private struct MireloResultURLExpired: Error {}
