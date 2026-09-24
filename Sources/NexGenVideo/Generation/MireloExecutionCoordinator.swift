import Foundation

private final class MireloFlightActivityIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var authorityIDs: Set<String> = []

    func insert(_ authorityID: String) {
        lock.withLock { _ = authorityIDs.insert(authorityID) }
    }

    func remove(_ authorityID: String) {
        lock.withLock { _ = authorityIDs.remove(authorityID) }
    }

    func contains(_ authorityID: String) -> Bool {
        lock.withLock { authorityIDs.contains(authorityID) }
    }
}

struct MireloExecutionOutcome: Sendable, Equatable {
    let record: MireloExecutionRecord
    let terminalResponse: Data
}

actor MireloExecutionCoordinator {
    static let shared = MireloExecutionCoordinator()
    typealias AcceptanceHandler = @MainActor @Sendable (MireloExecutionRecord) async throws -> Void

    private struct Waiter {
        let continuation: CheckedContinuation<MireloExecutionOutcome, Error>
    }

    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }

    private struct RetiringFlight {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct SettlementWaiter {
        let continuation: CheckedContinuation<Void, Error>
    }

    private var inFlight: [String: Flight] = [:]
    private var retiring: [String: RetiringFlight] = [:]
    private var settlementWaiters: [String: [UUID: SettlementWaiter]] = [:]
    nonisolated private let activityIndex = MireloFlightActivityIndex()

    nonisolated func hasActiveFlight(authorityID: String) -> Bool {
        activityIndex.contains(authorityID)
    }

    func prepare(
        store: MireloExecutionStore,
        projectKey: String,
        logicalJobID: String,
        operation: MireloOperation,
        intentBody: Data? = nil,
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
        let canonicalIntent = try Self.canonicalJSON(intentBody ?? requestBody)
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
            intentSHA256: FileDigest.sha256(of: canonicalIntent),
            intentBody: canonicalIntent,
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
        client: MireloClient,
        onAccepted: AcceptanceHandler? = nil
    ) async throws -> MireloExecutionOutcome {
        try Task.checkCancellation()
        let authorityID = try store.authorityID(
            projectKey: projectKey,
            logicalJobID: logicalJobID
        )
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
                register(
                    waiterID: waiterID,
                    authorityID: authorityID,
                    store: store,
                    projectKey: projectKey,
                    logicalJobID: logicalJobID,
                    client: client,
                    onAccepted: onAccepted,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, authorityID: authorityID) }
        }
    }

    func awaitSettlement(
        store: MireloExecutionStore,
        projectKey: String,
        logicalJobID: String
    ) async throws -> MireloExecutionRecord? {
        let authorityID = try store.authorityID(
            projectKey: projectKey,
            logicalJobID: logicalJobID
        )
        try Task.checkCancellation()
        guard inFlight[authorityID] != nil || retiring[authorityID] != nil else {
            return try store.load(
                projectKey: projectKey,
                logicalJobID: logicalJobID
            )
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                settlementWaiters[authorityID, default: [:]][waiterID] = SettlementWaiter(
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelSettlementWaiter(
                    waiterID,
                    authorityID: authorityID
                )
            }
        }
        try Task.checkCancellation()
        return try store.load(
            projectKey: projectKey,
            logicalJobID: logicalJobID
        )
    }

    private func register(
        waiterID: UUID,
        authorityID: String,
        store: MireloExecutionStore,
        projectKey: String,
        logicalJobID: String,
        client: MireloClient,
        onAccepted: AcceptanceHandler?,
        continuation: CheckedContinuation<MireloExecutionOutcome, Error>
    ) {
        if var flight = inFlight[authorityID] {
            flight.waiters[waiterID] = Waiter(continuation: continuation)
            inFlight[authorityID] = flight
            return
        }
        let flightID = UUID()
        let task = Task {
            let result: Result<MireloExecutionOutcome, Error>
            do {
                result = .success(try await self.executeOwned(
                    store: store,
                    projectKey: projectKey,
                    logicalJobID: logicalJobID,
                    client: client,
                    onAccepted: onAccepted
                ))
            } catch {
                result = .failure(error)
            }
            self.finishFlight(
                authorityID: authorityID,
                flightID: flightID,
                result: result
            )
        }
        activityIndex.insert(authorityID)
        inFlight[authorityID] = Flight(
            id: flightID,
            task: task,
            waiters: [waiterID: Waiter(continuation: continuation)]
        )
    }

    private func cancelWaiter(_ waiterID: UUID, authorityID: String) {
        guard var flight = inFlight[authorityID],
              let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            inFlight.removeValue(forKey: authorityID)
            retiring[authorityID] = RetiringFlight(
                id: flight.id,
                task: flight.task
            )
            flight.task.cancel()
        } else {
            inFlight[authorityID] = flight
        }
    }

    private func cancelSettlementWaiter(_ waiterID: UUID, authorityID: String) {
        guard var waiters = settlementWaiters[authorityID],
              let waiter = waiters.removeValue(forKey: waiterID) else { return }
        if waiters.isEmpty {
            settlementWaiters.removeValue(forKey: authorityID)
        } else {
            settlementWaiters[authorityID] = waiters
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func finishFlight(
        authorityID: String,
        flightID: UUID,
        result: Result<MireloExecutionOutcome, Error>
    ) {
        if retiring[authorityID]?.id == flightID {
            retiring.removeValue(forKey: authorityID)
        }
        if let flight = inFlight[authorityID], flight.id == flightID {
            inFlight.removeValue(forKey: authorityID)
            for waiter in flight.waiters.values {
                waiter.continuation.resume(with: result)
            }
        }
        if inFlight[authorityID] == nil, retiring[authorityID] == nil,
           let waiters = settlementWaiters.removeValue(forKey: authorityID) {
            for waiter in waiters.values {
                waiter.continuation.resume()
            }
        }
        if inFlight[authorityID] == nil, retiring[authorityID] == nil {
            activityIndex.remove(authorityID)
        }
    }

    private func executeOwned(
        store: MireloExecutionStore,
        projectKey: String,
        logicalJobID: String,
        client: MireloClient,
        onAccepted: AcceptanceHandler?
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
            if record.providerJobID != nil, let onAccepted {
                try await onAccepted(record)
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
        if let onAccepted {
            try await onAccepted(record)
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
        guard record.state == .providerSucceeded || record.state == .completed,
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
        let replaysUnknownAcceptance = expected.state == .submitting
            || expected.state == .acceptanceUnknown
        do {
            try Task.checkCancellation()
        } catch {
            let message = replaysUnknownAcceptance
                ? "Recovery stopped locally before replaying the persisted Mirelo idempotency key. The earlier submission may still have been accepted."
                : "Mirelo submission was cancelled before any provider request was sent."
            _ = try? store.update(expected) {
                $0.state = replaysUnknownAcceptance ? .acceptanceUnknown : .failed
                $0.lastError = message
            }
            throw CancellationError()
        }
        var submitting = expected
        if submitting.state != .submitting {
            submitting = try store.update(submitting) {
                $0.state = .submitting
                $0.lastError = nil
            }
        }
        var createStarted = false
        do {
            do {
                try Task.checkCancellation()
            } catch {
                let message = replaysUnknownAcceptance
                    ? "Recovery stopped locally before replaying the persisted Mirelo idempotency key. The earlier submission may still have been accepted."
                    : "Mirelo submission was cancelled before any provider request was sent."
                _ = try? store.update(submitting) {
                    $0.state = replaysUnknownAcceptance ? .acceptanceUnknown : .failed
                    $0.lastError = message
                }
                throw CancellationError()
            }
            createStarted = true
            let receipt = try await client.create(
                operation: submitting.operation,
                body: submitting.requestBody,
                idempotencyKey: submitting.idempotencyKey
            )
            do {
                return try store.update(submitting) {
                    $0.state = .accepted
                    $0.providerJobID = receipt.id
                    $0.providerStatusURL = receipt.statusURL
                    $0.lastProviderStatus = "accepted"
                    $0.lastError = nil
                }
            } catch {
                guard let current = try store.load(
                    projectKey: submitting.projectKey,
                    logicalJobID: submitting.logicalJobID
                ) else { throw error }
                if current.providerJobID == receipt.id,
                   (current.state == .accepted || current.state == .pollingInterrupted) {
                    return current
                }
                guard current.providerJobID == nil,
                      (current.state == .submitting || current.state == .acceptanceUnknown) else {
                    throw error
                }
                return try store.update(current) {
                    $0.state = .accepted
                    $0.providerJobID = receipt.id
                    $0.providerStatusURL = receipt.statusURL
                    $0.lastProviderStatus = "accepted"
                    $0.lastError = nil
                }
            }
        } catch is CancellationError {
            if !createStarted {
                throw CancellationError()
            }
            let message = submitting.operation.usesIdempotencyKey
                ? "Submission was interrupted. NexGenVideo will recover the same Mirelo v3 job with its persisted idempotency key; cancellation does not claim the server stopped."
                : Self.unknownAcceptanceMessage
            _ = try? store.update(submitting) {
                $0.state = .acceptanceUnknown
                $0.lastError = message
            }
            throw GenerationRequestError.gate(message)
        } catch let error as MireloHTTPError {
            if !replaysUnknownAcceptance && Self.definitivelyRejected(error) {
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
                try Task.checkCancellation()
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
        let joinedErrors = errors?.compactMap { $0["message"] as? String }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        let message = (errorObject?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? joinedErrors.flatMap { $0.isEmpty ? nil : $0 }
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
        return [400, 401, 402, 403, 404, 405, 406, 411, 413, 414, 415, 416, 417, 422, 429, 431]
            .contains(status)
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
