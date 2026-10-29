import Foundation

@MainActor
final class AgentModelEvidenceRendezvous {
    struct Key: Hashable, Sendable {
        let sessionID: UUID
        let turnID: UUID
        let toolUseID: String
    }

    private struct Waiter {
        let key: Key
        let continuation: CheckedContinuation<AgentModelResponseEvidence?, Never>
        let deadline: Task<Void, Never>
    }

    private var sessionID: UUID?
    private var turnID: UUID?
    private var responses: [String: AgentModelResponseEvidence] = [:]
    private var rejectedIDs = Set<String>()
    private var waiters: [UUID: Waiter] = [:]

    var pendingCount: Int { waiters.count }

    func begin(sessionID: UUID, turnID: UUID) {
        invalidate()
        self.sessionID = sessionID
        self.turnID = turnID
    }

    func invalidate() {
        sessionID = nil
        turnID = nil
        responses.removeAll()
        rejectedIDs.removeAll()
        for id in Array(waiters.keys) { finish(id, evidence: nil) }
    }

    func receive(_ evidence: AgentModelResponseEvidence) {
        guard evidence.sessionID == sessionID, evidence.turnID == turnID,
              !rejectedIDs.contains(evidence.toolUseID) else { return }
        let conflicting = responses[evidence.toolUseID].map { $0 != evidence } ?? false
        if conflicting {
            rejectedIDs.insert(evidence.toolUseID)
            responses.removeValue(forKey: evidence.toolUseID)
        } else {
            responses[evidence.toolUseID] = evidence
        }
        let ids = waiters.filter { $0.value.key.toolUseID == evidence.toolUseID }.map(\.key)
        for id in ids { finish(id, evidence: conflicting ? nil : evidence) }
    }

    func wait(for key: Key, timeout: Duration = .seconds(5)) async -> AgentModelResponseEvidence? {
        guard !Task.isCancelled, key.sessionID == sessionID, key.turnID == turnID,
              !key.toolUseID.isEmpty, !rejectedIDs.contains(key.toolUseID) else { return nil }
        if let evidence = responses[key.toolUseID] { return evidence }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, key.sessionID == sessionID, key.turnID == turnID,
                      !rejectedIDs.contains(key.toolUseID) else { continuation.resume(returning: nil); return }
                if let evidence = responses[key.toolUseID] { continuation.resume(returning: evidence); return }
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(id, evidence: nil)
                }
                waiters[id] = Waiter(key: key, continuation: continuation, deadline: deadline)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, evidence: nil) }
        }
    }

    private func finish(_ id: UUID, evidence: AgentModelResponseEvidence?) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.deadline.cancel()
        waiter.continuation.resume(returning: evidence)
    }
}
