import Foundation

public final class BpyRuntimeOutputLedger: @unchecked Sendable {
    public enum CheckpointChange: Equatable, Sendable { case confirm, release }
    private struct Reservation { var bytes: UInt64; var materialized: UInt64 = 0 }
    private struct FileCharge {
        let job: UUID
        let bytes: UInt64
        var identity: BpyRuntimeFileIdentity?
        var charged = true
    }
    private let lock = NSLock()
    private let capacity: UInt64
    private var reservations: [UUID: Reservation] = [:]
    private var files: [UUID: FileCharge] = [:]

    public init(capacity: UInt64) { self.capacity = capacity }

    public func reserve(_ id: UUID, maximum: UInt64) throws {
        try lock.withLock {
            guard reservations[id] == nil else { throw CocoaError(.fileWriteFileExists) }
            let used = reservations.values.reduce(UInt64(0)) { $0 + $1.bytes }
            guard used <= capacity, maximum <= capacity - used else { throw CocoaError(.fileWriteOutOfSpace) }
            reservations[id] = .init(bytes: maximum)
        }
    }

    public func materialize(_ id: UUID, bytes: UInt64) throws -> UUID {
        try lock.withLock {
            guard var reservation = reservations[id], reservation.materialized <= reservation.bytes,
                  bytes <= reservation.bytes - reservation.materialized else { throw CocoaError(.fileWriteOutOfSpace) }
            reservation.materialized += bytes
            reservations[id] = reservation
            let ticket = UUID()
            files[ticket] = .init(job: id, bytes: bytes)
            return ticket
        }
    }

    public func bind(_ ticket: UUID, file: BpyRuntimeFile) throws {
        try lock.withLock {
            guard var charge = files[ticket], charge.identity == nil, charge.bytes == file.byteCount else {
                throw CocoaError(.fileReadCorruptFile)
            }
            charge.identity = file.identity
            files[ticket] = charge
        }
    }

    public func updateCheckpoint(_ id: UUID, resultScene: BpyRuntimeFile?, confirmedScene: BpyRuntimeFile?,
                                 change: CheckpointChange) throws {
        guard let confirmedScene else {
            guard change == .release else { throw CocoaError(.fileReadCorruptFile) }
            return
        }
        switch change {
        case .confirm:
            guard resultScene == nil || resultScene?.identity == confirmedScene.identity else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try transferCheckpoint(id, file: confirmedScene, resultReleased: resultScene == nil)
        case .release:
            if let resultScene, resultScene.identity == confirmedScene.identity {
                try transferCheckpoint(id, file: resultScene, resultReleased: true)
            }
        }
    }

    private func transferCheckpoint(_ id: UUID, file: BpyRuntimeFile, resultReleased: Bool) throws {
        try lock.withLock {
            guard let entry = files.first(where: { $0.value.job == id && $0.value.identity == file.identity }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var charge = entry.value
            guard resultReleased else { return }
            guard charge.charged else { return }
            guard var reservation = reservations[id], charge.bytes <= reservation.materialized else {
                throw CocoaError(.fileReadCorruptFile)
            }
            reservation.materialized -= charge.bytes
            reservation.bytes = reservation.materialized
            charge.charged = false
            files[entry.key] = charge
            store(reservation, for: id)
        }
    }

    public func chargedBytes(_ id: UUID, file: BpyRuntimeFile) -> UInt64 {
        lock.withLock {
            files.values.first { $0.job == id && $0.identity == file.identity && $0.charged }?.bytes ?? 0
        }
    }

    public func disposed(_ ticket: UUID) {
        lock.withLock {
            guard let charge = files.removeValue(forKey: ticket), charge.charged,
                  var reservation = reservations[charge.job], charge.bytes <= reservation.materialized else { return }
            reservation.materialized -= charge.bytes
            reservation.bytes -= charge.bytes
            store(reservation, for: charge.job)
        }
    }

    public func materialized(_ id: UUID) -> UInt64 { lock.withLock { reservations[id]?.materialized ?? 0 } }

    public func settle(_ id: UUID) {
        lock.withLock {
            guard var reservation = reservations[id] else { return }
            reservation.bytes = reservation.materialized
            store(reservation, for: id)
        }
    }

    private func store(_ reservation: Reservation, for id: UUID) {
        if reservation.bytes == 0 { reservations.removeValue(forKey: id) }
        else { reservations[id] = reservation }
    }
}
