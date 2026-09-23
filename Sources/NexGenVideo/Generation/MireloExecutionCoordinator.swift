import Foundation

struct MireloExecutionOutcome: Sendable, Equatable {
    let record: MireloExecutionRecord
    let terminalResponse: Data
}

actor MireloExecutionCoordinator {
    static let shared = MireloExecutionCoordinator()

    func prepare(
        store: MireloExecutionStore,
        projectKey: String,
        logicalJobID: String,
        operation: MireloOperation,
        requestBody: Data,
        sources: [MireloSourceReceipt],
        preflight: MireloPreflight,
        now: Date = Date()
    ) throws -> MireloExecutionRecord {
        guard UUID(uuidString: logicalJobID) != nil else {
            throw GenerationRequestError.optionsInvalid(
                "A Mirelo logical job id must be a UUID. Reuse it only for the same exact request."
            )
        }
        let canonicalBody = try Self.canonicalJSON(requestBody)
        let authorityID = try store.authorityID(
            projectKey: projectKey,
            logicalJobID: logicalJobID
        )
        let record = MireloExecutionRecord(
            schema: "mirelo-execution-authority/v1",
            authorityID: authorityID,
            projectKey: projectKey,
            logicalJobID: logicalJobID,
            operation: operation,
            requestSHA256: FileDigest.sha256(of: canonicalBody),
            requestBody: canonicalBody,
            idempotencyKey: operation.usesIdempotencyKey ? authorityID : nil,
            sources: sources,
            preflight: preflight,
            createdAt: now,
            updatedAt: now,
            approvedAt: nil,
            spendTransactionID: nil,
            state: .prepared,
            providerJobID: nil,
            providerStatusURL: nil,
            lastProviderStatus: nil,
            lastError: nil,
            terminalResponse: nil,
            artifacts: []
        )
        return try store.create(record)
    }

    func approve(
        store: MireloExecutionStore,
        record: MireloExecutionRecord,
        spendTransactionID: String
    ) throws -> MireloExecutionRecord {
        guard !spendTransactionID.isEmpty else {
            throw GenerationRequestError.storage(
                "The Mirelo spend approval has no transaction id."
            )
        }
        if let existing = record.spendTransactionID {
            guard existing == spendTransactionID, record.approvedAt != nil else {
                throw GenerationRequestError.gate(
                    "This Mirelo job already belongs to another spend approval."
                )
            }
            return record
        }
        return try store.update(record) {
            $0.approvedAt = Date()
            $0.spendTransactionID = spendTransactionID
        }
    }

    func execute(
        store: MireloExecutionStore,
        projectKey: String,
        logicalJobID: String,
        client: MireloClient
    ) async throws -> MireloExecutionOutcome {
        guard var record = try store.load(
            projectKey: projectKey,
            logicalJobID: logicalJobID
        ) else {
            throw GenerationRequestError.storage(
                "The Mirelo execution record is missing. Prepare and approve the request again."
            )
        }
        guard record.approvedAt != nil, record.spendTransactionID != nil else {
            throw GenerationRequestError.gate(
                "Approve the exact Mirelo preflight before submitting this job."
            )
        }

        switch record.state {
        case .completed, .providerSucceeded:
            guard let terminal = record.terminalResponse else {
                throw GenerationRequestError.storage(
                    "The completed Mirelo job has no terminal response."
                )
            }
            return MireloExecutionOutcome(record: record, terminalResponse: terminal)
        case .failed:
            throw GenerationRequestError.gate(
                record.lastError ?? "The Mirelo job failed. Use a new logical job id to submit a changed request."
            )
        case .accepted, .pollingInterrupted:
            break
        case .submitting, .acceptanceUnknown:
            guard record.operation.usesIdempotencyKey else {
                if record.state != .acceptanceUnknown {
                    record = try store.update(record) {
                        $0.state = .acceptanceUnknown
                        $0.lastError = Self.unknownAcceptanceMessage
                    }
                }
                throw GenerationRequestError.gate(Self.unknownAcceptanceMessage)
            }
            record = try await submit(record, store: store, client: client)
        case .prepared:
            record = try await submit(record, store: store, client: client)
        }

        guard record.providerJobID != nil else {
            throw GenerationRequestError.storage(
                "Mirelo accepted the request without a durable job identifier."
            )
        }
        return try await poll(record, store: store, client: client)
    }

    func complete(
        store: MireloExecutionStore,
        record: MireloExecutionRecord,
        artifacts: [MireloArtifact]
    ) throws -> MireloExecutionRecord {
        if record.state == .completed {
            guard record.artifacts == artifacts else {
                throw GenerationRequestError.storage(
                    "The local Mirelo result no longer matches its execution record."
                )
            }
            return record
        }
        guard record.state == .providerSucceeded, !artifacts.isEmpty else {
            throw GenerationRequestError.storage(
                "A Mirelo job can complete only after its provider result is stored in the project."
            )
        }
        return try store.update(record) {
            $0.artifacts = artifacts
            $0.state = .completed
            $0.lastError = nil
        }
    }

    func refreshResult(
        store: MireloExecutionStore,
        record: MireloExecutionRecord,
        client: MireloClient
    ) async throws -> MireloExecutionOutcome {
        guard record.state == .providerSucceeded,
              let jobID = record.providerJobID else {
            throw GenerationRequestError.storage(
                "Only a succeeded Mirelo job can refresh temporary result URLs."
            )
        }
        let response = try await client.job(operation: record.operation, id: jobID)
        let snapshot = try Self.status(from: response.data, operation: record.operation)
        guard snapshot.isSuccess else {
            throw GenerationRequestError.gate(
                "Mirelo job \(jobID) no longer exposes a succeeded result (status: \(snapshot.status)). It was not resubmitted."
            )
        }
        let terminal = try Self.canonicalJSON(response.data)
        let refreshed = try store.update(record) {
            $0.lastProviderStatus = snapshot.status
            $0.lastError = nil
            $0.terminalResponse = terminal
        }
        return MireloExecutionOutcome(record: refreshed, terminalResponse: terminal)
    }

    private func submit(
        _ expected: MireloExecutionRecord,
        store: MireloExecutionStore,
        client: MireloClient
    ) async throws -> MireloExecutionRecord {
        var submitting = expected
        if submitting.state != .submitting {
            submitting = try store.update(submitting) {
                $0.state = .submitting
                $0.lastError = nil
            }
        }
        do {
            let receipt = try await client.create(
                operation: submitting.operation,
                body: submitting.requestBody,
                idempotencyKey: submitting.idempotencyKey
            )
            return try store.update(submitting) {
                $0.state = .accepted
                $0.providerJobID = receipt.id
                $0.providerStatusURL = receipt.statusURL
                $0.lastProviderStatus = "accepted"
                $0.lastError = nil
            }
        } catch is CancellationError {
            let message = submitting.operation.usesIdempotencyKey
                ? "Submission was interrupted. NexGenVideo will recover the same Mirelo v3 job with its persisted idempotency key; cancellation does not claim the server stopped."
                : Self.unknownAcceptanceMessage
            _ = try? store.update(submitting) {
                $0.state = .acceptanceUnknown
                $0.lastError = message
            }
            throw GenerationRequestError.gate(message)
        } catch let error as MireloHTTPError {
            if Self.definitivelyRejected(error) {
                let failed = try store.update(submitting) {
                    $0.state = .failed
                    $0.lastError = error.localizedDescription
                }
                throw GenerationRequestError.gate(
                    failed.lastError ?? error.localizedDescription
                )
            }
            let message: String
            if submitting.operation.usesIdempotencyKey {
                message = "Mirelo submission was not acknowledged. Retry the same logical job to recover it with the persisted idempotency key. \(error.localizedDescription)"
            } else {
                message = Self.unknownAcceptanceMessage + " " + error.localizedDescription
            }
            _ = try? store.update(submitting) {
                $0.state = .acceptanceUnknown
                $0.lastError = message
            }
            throw GenerationRequestError.gate(message)
        } catch {
            let message = submitting.operation.usesIdempotencyKey
                ? "Mirelo submission was not acknowledged. Retry the same logical job to recover it with the persisted idempotency key."
                : Self.unknownAcceptanceMessage
            _ = try? store.update(submitting) {
                $0.state = .acceptanceUnknown
                $0.lastError = message + " " + error.localizedDescription
            }
            throw GenerationRequestError.gate(message + " " + error.localizedDescription)
        }
    }

    private func poll(
        _ accepted: MireloExecutionRecord,
        store: MireloExecutionStore,
        client: MireloClient
    ) async throws -> MireloExecutionOutcome {
        var record = accepted
        var transientFailures = 0
        while true {
            guard let jobID = record.providerJobID else {
                throw GenerationRequestError.storage(
                    "The accepted Mirelo request has no provider job id."
                )
            }
            do {
                try Task.checkCancellation()
                let response = try await client.job(operation: record.operation, id: jobID)
                let snapshot = try Self.status(
                    from: response.data,
                    operation: record.operation
                )
                transientFailures = 0
                if snapshot.isSuccess {
                    let terminal = try Self.canonicalJSON(response.data)
                    let finished = try store.update(record) {
                        $0.state = .providerSucceeded
                        $0.lastProviderStatus = snapshot.status
                        $0.lastError = nil
                        $0.terminalResponse = terminal
                    }
                    return MireloExecutionOutcome(
                        record: finished,
                        terminalResponse: terminal
                    )
                }
                if snapshot.isFailure {
                    let message = snapshot.errorMessage
                        ?? "Mirelo job \(jobID) ended with status \(snapshot.status)."
                    _ = try store.update(record) {
                        $0.state = .failed
                        $0.lastProviderStatus = snapshot.status
                        $0.lastError = message
                        $0.terminalResponse = try? Self.canonicalJSON(response.data)
                    }
                    throw GenerationRequestError.gate(message)
                }
                guard snapshot.isPending else {
                    let message = "Mirelo returned unknown job status '\(snapshot.status)'. The job was not resubmitted."
                    _ = try store.update(record) {
                        $0.state = .pollingInterrupted
                        $0.lastProviderStatus = snapshot.status
                        $0.lastError = message
                    }
                    throw GenerationRequestError.gate(message)
                }
                if record.lastProviderStatus != snapshot.status || record.state != .accepted {
                    record = try store.update(record) {
                        $0.state = .accepted
                        $0.lastProviderStatus = snapshot.status
                        $0.lastError = nil
                    }
                }
                let delay = max(1, min(response.retryAfterSeconds ?? 2, 30))
                try await Task.sleep(for: .seconds(delay))
            } catch is CancellationError {
                let message = "Polling stopped locally. Mirelo job \(jobID) may still be running or billable; resume the same logical job to continue polling."
                _ = try? store.update(record) {
                    $0.state = .pollingInterrupted
                    $0.lastError = message
                }
                throw GenerationRequestError.gate(message)
            } catch let error as MireloHTTPError {
                transientFailures += 1
                if error.retryable == true, transientFailures < 4 {
                    let delay = max(1, min(error.retryAfterSeconds ?? transientFailures, 30))
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                let message = "Mirelo job \(jobID) remains accepted, but polling stopped: \(error.localizedDescription) Resume the same logical job; do not submit another."
                _ = try? store.update(record) {
                    $0.state = .pollingInterrupted
                    $0.lastError = message
                }
                throw GenerationRequestError.gate(message)
            }
        }
    }

    private struct StatusSnapshot {
        let status: String
        let isPending: Bool
        let isSuccess: Bool
        let isFailure: Bool
        let errorMessage: String?
    }

    private static func status(
        from data: Data,
        operation: MireloOperation
    ) throws -> StatusSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["status"] as? String else {
            throw GenerationRequestError.storage(
                "Mirelo returned a job body without a status."
            )
        }
        let normalized = status.lowercased()
        let pending: Set<String> = operation == .audioToMIDI
            ? ["processing"]
            : ["queued", "running"]
        let successes: Set<String> = operation == .audioToMIDI
            ? ["succeeded"]
            : ["succeeded", "partially_succeeded"]
        let failures: Set<String> = operation == .audioToMIDI
            ? ["errored"]
            : ["failed", "canceled", "expired"]
        let errorObject = root["error"] as? [String: Any]
        let errors = root["errors"] as? [[String: Any]]
        let message = errorObject?["message"] as? String
            ?? errors?.compactMap { $0["message"] as? String }.joined(separator: "; ")
        return StatusSnapshot(
            status: normalized,
            isPending: pending.contains(normalized),
            isSuccess: successes.contains(normalized),
            isFailure: failures.contains(normalized),
            errorMessage: message
        )
    }

    private static func definitivelyRejected(_ error: MireloHTTPError) -> Bool {
        guard let status = error.status else { return false }
        if error.retryable == true { return false }
        if status >= 500 { return false }
        return (400...499).contains(status)
    }

    private static func canonicalJSON(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        guard JSONSerialization.isValidJSONObject(object) else {
            throw GenerationRequestError.storage("Mirelo request JSON is invalid.")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static let unknownAcceptanceMessage =
        "Mirelo may have accepted this Audio-to-MIDI job, but its job id was not received. The API has no idempotency key or job lookup for this request. Do not resubmit automatically; reconcile usage with Mirelo before choosing a new logical job id."
}
