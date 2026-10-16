import Foundation
import os

/// Spend transactions a generation task of this process is still working on.
enum ActiveSpendTransactions {
    private static let state = OSAllocatedUnfairLock(initialState: Set<String>())

    static func begin(_ transactionID: String?) {
        guard let transactionID else { return }
        state.withLock { _ = $0.insert(transactionID) }
    }

    static func end(_ transactionID: String?) {
        guard let transactionID else { return }
        state.withLock { _ = $0.remove(transactionID) }
    }

    static var current: Set<String> { state.withLock { $0 } }
}

/// One read-only answer from a provider about a submitted run.
enum ProviderRunStatus: Sendable, Equatable {
    case running
    case completed(GenerationProviderCost?)
    case failed(String, GenerationProviderCost?)
}

/// An MCP connection that can list tools and ask a status tool about an accepted job.
protocol MCPStatusClient: MCPToolCalling {
    func discoverTools() async throws -> [MCPProviderClient.DiscoveredTool]
    func disconnect() async
}

extension MCPProviderClient: MCPStatusClient {}

/// How status-only reconciliation reaches providers; tests replace every live dependency.
struct ProviderRunReconciliation: Sendable {
    var session: URLSession = .shared
    var minimumInterval: TimeInterval = 60
    var providerKey: @Sendable (GenerationProvider) -> String? = { ProviderKeychain.load($0) }
    var falCharge: @Sendable (_ requestID: String, _ endpoint: String, _ apiKey: String) async -> GenerationMoney? = {
        try? await ProviderMoneyClient.shared.falCharge(requestId: $0, endpoint: $1, apiKey: $2)
    }
    var mcpClient: @Sendable (GenerationProvider) async -> (any MCPStatusClient)? = {
        await ProviderMCP.client(for: $0) as (any MCPStatusClient)?
    }
}

/// A submitted run whose provider receipt can be queried for its status.
struct ReconcilableRun: Sendable, Equatable {
    let transactionID: String
    let reservation: GenerationSpendEvent
    let requestID: String
}

extension GenerationService {
    /// Open runs with a real, resumable provider receipt, in ledger order.
    nonisolated static func reconcilableRuns(in log: GenerationLog, excluding skipped: Set<String>) -> [ReconcilableRun] {
        var reservations: [String: GenerationSpendEvent] = [:]
        var receipts: [String: GenerationSpendEvent] = [:]
        var closed: Set<String> = []
        var order: [String] = []
        for event in log.spendEvents {
            switch event.kind {
            case .reserved:
                guard reservations[event.transactionId] == nil else { continue }
                reservations[event.transactionId] = event
                order.append(event.transactionId)
            case .submitted:
                receipts[event.transactionId] = event
            case .charged, .settled, .released:
                closed.insert(event.transactionId)
            }
        }
        return order.compactMap { id in
            guard !closed.contains(id), !skipped.contains(id),
                  let reservation = reservations[id], let receipt = receipts[id],
                  receipt.providerRequestResumable == true,
                  let requestID = receipt.providerRequestId, !requestID.isEmpty else { return nil }
            return ReconcilableRun(transactionID: id, reservation: reservation, requestID: requestID)
        }
    }

    /// Status reads only — never a submit, retry or cancel; an unknown answer leaves the run untouched.
    @discardableResult
    func reconcileOpenRuns(editor: EditorViewModel, now: Date = Date()) async -> Int {
        guard let home = editor.workingRoot, !reconcilingHomes.contains(home) else { return 0 }
        if let last = lastReconciliation[home], now.timeIntervalSince(last) < reconciliation.minimumInterval {
            return 0
        }
        lastReconciliation[home] = now
        reconcilingHomes.insert(home)
        defer { reconcilingHomes.remove(home) }
        let skipped = ActiveSpendTransactions.current.union(GenerationBatchStore.batchTransactionIDs(home: home))
        var settled = 0
        for run in Self.reconcilableRuns(in: editor.generationLog, excluding: skipped) {
            guard editor.workingRoot == home else { break }
            guard let status = await providerStatus(of: run), status != .running else { continue }
            guard editor.workingRoot == home,
                  !ActiveSpendTransactions.current.contains(run.transactionID) else { continue }
            if await settleReconciled(run, status: status, editor: editor) { settled += 1 }
        }
        return settled
    }

    private func providerStatus(of run: ReconcilableRun) async -> ProviderRunStatus? {
        let event = run.reservation
        let config = reconciliation
        if event.transport == .mcp {
            guard let client = await config.mcpClient(event.provider) else { return nil }
            let status: ProviderRunStatus?
            do {
                let tools = try await client.discoverTools()
                status = try await MCPGenerationExecutor.status(jobID: run.requestID, tools: tools, client: client)
            } catch {
                status = nil
            }
            await client.disconnect()
            return status
        }
        guard let key = config.providerKey(event.provider) else { return nil }
        do {
            switch event.provider {
            case .fal:
                return try await FalClient(apiKey: key, session: config.session)
                    .status(endpoint: event.endpoint, requestId: run.requestID)
            case .runway:
                return try await RunwayClient(apiKey: key, session: config.session).status(taskId: run.requestID)
            case .marble:
                return try await MarbleClient(apiKey: key, session: config.session).status(operationId: run.requestID)
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    private func settleReconciled(_ run: ReconcilableRun, status: ProviderRunStatus, editor: EditorViewModel) async -> Bool {
        let event = run.reservation
        let binding = event.transport == .api ? nil : ProviderBinding(
            provider: event.provider, transport: event.transport, kind: .generation,
            providerRef: event.endpoint, billing: .perCall)
        let authorization = GenerationAuthorization(
            transactionId: run.transactionID,
            target: ResolvedGenerationTarget(modelId: event.model, provider: event.provider,
                endpoint: event.endpoint, binding: binding),
            estimate: event.money
        )
        switch status {
        case .running:
            return false
        case .completed(let cost):
            var billed: GenerationMoney?
            if event.provider == .fal, event.transport == .api, let key = reconciliation.providerKey(.fal) {
                billed = await reconciliation.falCharge(run.requestID, event.endpoint, key)
            }
            guard Self.isOpen(run.transactionID, in: editor.generationLog),
                  !ActiveSpendTransactions.current.contains(run.transactionID) else { return false }
            markFinished(authorization: authorization, billed: billed, providerCost: cost,
                note: "The provider confirmed the run finished; its output never reached NexGenVideo.", editor: editor)
        case .failed(let message, let cost):
            guard Self.isOpen(run.transactionID, in: editor.generationLog) else { return false }
            markFinished(authorization: authorization, providerCost: cost,
                note: "The provider confirmed the run ended without a result: \(message)", editor: editor)
        }
        return !Self.isOpen(run.transactionID, in: editor.generationLog)
    }

    nonisolated static func isOpen(_ transactionID: String, in log: GenerationLog) -> Bool {
        !log.spendEvents.contains {
            $0.transactionId == transactionID && [.charged, .settled, .released].contains($0.kind)
        }
    }
}
