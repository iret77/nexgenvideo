import BpyRuntimeProtocol
import Darwin
import Foundation

nonisolated final class BpyGeneratedMedia: @unchecked Sendable {
    let url: URL
    private let root: URL
    private let reservation: UUID
    private let overlap: UUID
    private let maximum: UInt64
    private let diskReservation: UUID
    private let frameBytes: UInt64
    private let ledger: BpyRetentionLedger
    private var complete = false
    private let stateLock = NSLock()
    private var writers = 0
    private var abandonRequested = false

    convenience init(lease: BpyRuntimeResultLease, filename: String, width: Int, height: Int) throws {
        try self.init(slot: lease.slot, owner: lease.owner, limits: lease.limits, filename: filename, width: width, height: height)
    }

    init(slot: String, owner: UUID, limits: BpyRuntimeLimits, filename: String, width: Int, height: Int,
         ledger: BpyRetentionLedger = .shared) throws {
        self.ledger = ledger
        guard width > 0, height > 0, width <= limits.renderWidth, height <= limits.renderHeight,
              UInt64(width) * UInt64(height) <= UInt64(limits.renderPixels),
              !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent else { throw SpatialSceneError.changed }
        frameBytes = UInt64(width) * UInt64(height) * 4
        maximum = limits.outputBytes
        reservation = try ledger.reserve(slot: slot, owner: owner, kind: .retained, bytes: maximum)
        do { overlap = try ledger.reserve(slot: slot, owner: owner, kind: .transfer, bytes: maximum) }
        catch { ledger.release(reservation); throw error }
        do {
            root = try BpyHostStaging.shared.directory("media-" + UUID().uuidString)
            url = root.appendingPathComponent("writing-" + filename)
            diskReservation = try BpySequenceDiskLedger.shared.reserve(owner: owner, root: root, planned: frameBytes)
        } catch { ledger.release(reservation); ledger.release(overlap); throw error }
    }

    func checkSize(planningFrame: Bool = true) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == getuid(), value.st_nlink == 1, value.st_size >= 0 else { throw SpatialSceneError.changed }
        let bytes = UInt64(value.st_size)
        try BpySequenceDiskLedger.shared.update(diskReservation, root: root, occupied: bytes, planned: planningFrame ? frameBytes : 0)
        guard bytes <= maximum else { throw SpatialSceneError.invalid("The Clay video exceeded its output size limit.") }
    }

    func finish() throws -> BpyRuntimeFile {
        guard stateLock.withLock({ writers == 0 && !abandonRequested && !complete }) else { throw SpatialSceneError.changed }
        try checkSize(planningFrame: false)
        let ledger = ledger, reservation = reservation, diskReservation = diskReservation, root = root
        let file = try BpyRuntimeFile.adoptCompleted(at: url) { removed, _ in
            if removed {
                ledger.release(reservation)
                BpySequenceDiskLedger.shared.release(diskReservation)
                _ = rmdir(root.path)
            }
        }
        stateLock.withLock { complete = true }
        ledger.release(overlap)
        do {
            try ledger.bind(reservation, file: file)
            ledger.settle(reservation)
            return file
        } catch { file.release(); throw error }
    }

    func abandon() {
        let remove = stateLock.withLock {
            guard !complete else { return false }
            abandonRequested = true
            guard writers == 0 else { return false }
            complete = true
            return true
        }
        guard remove else { return }
        let ledger = ledger, reservation = reservation, overlap = overlap, diskReservation = diskReservation, root = root
        BpyStagingCleanup.shared.discard(url) {
            ledger.release(reservation); ledger.release(overlap)
            BpySequenceDiskLedger.shared.release(diskReservation)
            _ = rmdir(root.path)
        }
    }

    func retainForIO() throws -> BpyMediaFilePin {
        try stateLock.withLock {
            guard !complete, !abandonRequested else { throw SpatialSceneError.changed }
            writers += 1
        }
        return BpyMediaFilePin { [self] in
            let dispose = stateLock.withLock { writers -= 1; return writers == 0 && abandonRequested }
            if dispose { abandon() }
        }
    }

    func diagnosticState() throws -> (reservations: Set<UUID>, writers: Int, abandoned: Bool) {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else { throw BpyAdmissionFailure.closed }
        return stateLock.withLock { ([reservation, overlap], writers, abandonRequested) }
    }

    deinit { abandon() }
}
