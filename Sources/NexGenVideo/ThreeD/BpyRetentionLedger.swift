import BpyRuntimeProtocol
import Foundation

nonisolated final class BpyRetentionLedger: @unchecked Sendable {
    enum Kind: String, Sendable { case retained, transfer, checkpoint, decode, control }
    struct Entry: Sendable {
        let id: UUID
        let slot: String
        let owner: UUID
        let kind: Kind
        var bytes: UInt64
        var identities: [BpyRuntimeFileIdentity]
        var pending: [UUID: UInt64] = [:]
        var settled = false
    }

    static let shared = BpyRetentionLedger()
    private let lock = NSLock()
    private var capacities: [String: [Kind: UInt64]] = [:]
    private var entries: [UUID: Entry] = [:]

    func configure(slot: String, limits: BpyRuntimeLimits) throws {
        guard bpyRuntimeServiceNames.contains(slot), let retained = limits.retainedOutputBytes else {
            throw BpyRuntimeError.invalidInput("Invalid 3D retention limits.")
        }
        let proposed: [Kind: UInt64] = [.retained: retained, .transfer: limits.outputBytes,
            .checkpoint: 2 * max(limits.inputBytes, limits.outputBytes), .decode: limits.outputBytes + UInt64(limits.renderPixels) * 12,
            .control: 64 * 1_024 * 1_024]
        try lock.withLock {
            for (kind, maximum) in proposed {
                let used = entries.values.filter { $0.slot == slot && $0.kind == kind }.reduce(UInt64(0)) { $0 + $1.bytes }
                guard used <= maximum else { throw BpyRuntimeError.rejected("Release retained 3D results before changing limits.") }
            }
            capacities[slot] = proposed
        }
    }

    func reserve(slot: String, owner: UUID, kind: Kind, bytes: UInt64) throws -> UUID {
        try lock.withLock {
            guard let maximum = capacities[slot]?[kind], entries.count < 16_384 else {
                throw BpyRuntimeError.rejected("The 3D retention ledger is unavailable.")
            }
            let used = entries.values.filter { $0.slot == slot && $0.kind == kind }.reduce(UInt64(0)) { $0 + $1.bytes }
            guard used <= maximum, bytes <= maximum - used else {
                throw BpyRuntimeError.rejected("Release retained 3D results before starting another job.")
            }
            let id = UUID()
            entries[id] = Entry(id: id, slot: slot, owner: owner, kind: kind, bytes: bytes, identities: [])
            return id
        }
    }

    func bind(_ id: UUID, file: BpyRuntimeFile) throws {
        try lock.withLock {
            guard var entry = entries[id], !entry.settled else {
                throw BpyRuntimeError.invalidOutput("The 3D result reservation is missing.")
            }
            let used = entry.identities.reduce(UInt64(0)) { $0 + $1.bytes } + entry.pending.values.reduce(0, +)
            guard used <= entry.bytes, file.byteCount <= entry.bytes - used,
                  !entry.identities.contains(file.identity) else { throw SpatialSceneError.changed }
            entry.identities.append(file.identity); entries[id] = entry
        }
    }

    func settle(_ id: UUID) {
        lock.withLock {
            guard var entry = entries[id] else { return }
            entry.bytes = entry.identities.reduce(0) { $0 + $1.bytes } + entry.pending.values.reduce(0, +); entry.settled = true
            if entry.identities.isEmpty && entry.pending.isEmpty { entries.removeValue(forKey: id) }
            else { entries[id] = entry }
        }
    }

    func disposed(_ id: UUID, identity: BpyRuntimeFileIdentity, bytes: UInt64) {
        lock.withLock {
            guard var entry = entries[id], entry.bytes >= bytes,
                  entry.identities.contains(identity) else { return }
            entry.bytes -= bytes; entry.identities.removeAll { $0 == identity }
            if entry.settled && entry.identities.isEmpty && entry.pending.isEmpty { entries.removeValue(forKey: id) }
            else { entries[id] = entry }
        }
    }

    func deferCleanup(_ id: UUID, bytes: UInt64, cleanup: BpyRuntimeFile.Cleanup) {
        lock.withLock {
            guard var entry = entries[id] else { return }
            entry.pending[cleanup.id] = bytes
            entries[id] = entry
        }
        cleanup.whenComplete { [self] in
            lock.withLock {
                guard var entry = entries[id], let bytes = entry.pending.removeValue(forKey: cleanup.id) else { return }
                if entry.settled { entry.bytes -= bytes }
                if entry.settled && entry.identities.isEmpty && entry.pending.isEmpty { entries.removeValue(forKey: id) }
                else { entries[id] = entry }
            }
        }
    }

    func creatingFile(_ id: UUID, bytes: UInt64, _ operation: () throws -> BpyRuntimeFile) throws -> BpyRuntimeFile {
        do { return try operation() }
        catch {
            if let failure = error as? BpyRuntimeFile.CreationError {
                deferCleanup(id, bytes: bytes, cleanup: failure.cleanup)
            }
            throw error
        }
    }

    func release(_ id: UUID) { _ = lock.withLock { entries.removeValue(forKey: id) } }
    func waitForDisposal(owner: UUID, deadline: TimeInterval?) -> Bool {
        while lock.withLock({ entries.values.contains { $0.owner == owner } }) {
            guard let deadline, let now = BpyRuntimeClock.read()?.awake, now < deadline else { return false }
            Thread.sleep(forTimeInterval: min(0.005, deadline - now))
        }
        return true
    }
    var snapshot: [Entry] { lock.withLock { Array(entries.values) } }
}
