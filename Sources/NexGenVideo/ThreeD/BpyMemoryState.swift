import BpyRuntimeProtocol
import Foundation

nonisolated enum BpyMemoryPressure: UInt32, Codable, Sendable {
    case normal = 1, warning = 2, critical = 4
}

nonisolated enum BpyMemoryStop: String, Codable, Sendable {
    case diagnosticMemory, pressure, monitorUnavailable, monitorUnresponsive, deadline, serviceStall, cancelled, closed, cleanupFailed
    case diagnosticSafety
    case executionFailed
    case launchFailed, transportLost
    case ownershipViolation, orphanedWorker
    case observationFailed
    case disk
    case fileCount = "file-count"
    case processCount = "process-count"
}

nonisolated enum BpyAdmissionFailure: String, LocalizedError, Codable, Equatable, Sendable {
    case cancelled, closed, timedOut, pressure, sensorUnavailable, sensorUnresponsive, cleanupFailed
    case launchFailed, transportLost, executionFailed

    var errorDescription: String? {
        switch self {
        case .cancelled: "The 3D operation was cancelled."
        case .closed: "The 3D session is closed. Reopen the location."
        case .timedOut: "The 3D operation waited too long to start. Retry after the current render finishes."
        case .pressure: "macOS reported critical memory pressure. Retry when memory is available."
        case .sensorUnavailable: "macOS memory pressure is unavailable. Restart NexGenVideo before retrying."
        case .sensorUnresponsive: "Memory monitoring stopped responding. Retry after cleanup finishes."
        case .cleanupFailed: "3D cleanup could not be verified. Save your project and restart NexGenVideo."
        case .launchFailed: "The 3D worker could not start. Check the runtime diagnostics before retrying."
        case .transportLost: "The connection to the 3D runtime was lost. Retry after cleanup finishes."
        case .executionFailed: "The 3D operation failed. Check its diagnostics before retrying."
        }
    }
}

nonisolated struct BpyExecutionInterruption: LocalizedError, Sendable {
    let reason: BpyMemoryStop
    var errorDescription: String? {
        switch reason {
        case .pressure: BpyAdmissionFailure.pressure.errorDescription
        case .monitorUnavailable: BpyAdmissionFailure.sensorUnavailable.errorDescription
        case .monitorUnresponsive: BpyAdmissionFailure.sensorUnresponsive.errorDescription
        case .serviceStall: "The 3D service stopped reporting progress. Retry after runtime cleanup finishes."
        case .observationFailed: "The 3D process could not be monitored safely. Retry after runtime cleanup finishes."
        case .launchFailed: BpyAdmissionFailure.launchFailed.errorDescription
        case .ownershipViolation: "The 3D process identity changed unexpectedly. Check runtime diagnostics before retrying."
        case .orphanedWorker: "The 3D supervisor ended before its rendering process. Wait for runtime recovery before retrying."
        case .transportLost: BpyAdmissionFailure.transportLost.errorDescription
        case .closed: BpyAdmissionFailure.closed.errorDescription
        case .cancelled: BpyAdmissionFailure.cancelled.errorDescription
        case .cleanupFailed: BpyAdmissionFailure.cleanupFailed.errorDescription
        case .deadline: "The 3D operation exceeded its deadline."
        case .executionFailed: BpyAdmissionFailure.executionFailed.errorDescription
        case .disk: "The 3D operation exceeded its temporary storage limit. Reduce its output before retrying."
        case .fileCount: "The 3D operation created too many temporary files. Reduce its output before retrying."
        case .processCount: "The 3D operation started an unauthorized process. Remove the process launch before retrying."
        case .diagnosticMemory, .diagnosticSafety: "The controlled memory diagnostic stopped."
        }
    }
}

nonisolated enum BpyLaunchDeferral: Error { case observation }

nonisolated struct BpyStopGround: Codable, Sendable {
    let reason: BpyMemoryStop
    let clock: BpyClockReading?
}

nonisolated struct BpyChildRelease: Codable, Sendable {
    let child: BpyMemoryState.Child
    let clock: BpyClockReading
}

nonisolated struct BpyAdmissionIdentity: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case probe, job, boundary }
    let id: UUID
    let owner: UUID
    let generation: UUID
    let transport: UUID
    let job: UUID?
    let kind: Kind
    let insertedAt: TimeInterval
    let admissionDeadline: TimeInterval
    let timeout: TimeInterval
    let diagnosticAutoexec: Bool
    var runningTimeout: TimeInterval { kind == .probe ? 120 : timeout }
}

nonisolated struct BpyMemoryState: Sendable {
    enum Admission: Equatable, Sendable {
        case queued, granted, failed(BpyAdmissionFailure)
    }

    enum Child: String, Codable, Sendable { case probe, worker, verifier, autoexec, boundary }

    struct Permit: Sendable {
        let identity: BpyAdmissionIdentity
        var admission: Admission = .queued
        var grantedAt: TimeInterval?
        var firstRelease: TimeInterval?
        var children: [Child] = []
        var releases: [BpyChildRelease] = []
        var childRunning = false
        var launchPrepared = false
        var collecting = false
        var stop: BpyMemoryStop?
        var cleanupStarted: TimeInterval?
        var cleanupComplete = false
        var cleanupFinishedAt: TimeInterval?
        var terminalCommit: TimeInterval?
        var lastServiceObservation: TimeInterval?
        var grounds: [BpyStopGround] = []
    }

    struct Effect: Equatable, Sendable {
        enum Operation: Equatable, Sendable { case wake, refresh, stop(BpyMemoryStop) }
        let permit: UUID?
        let operation: Operation
    }

    static let freshness: TimeInterval = 0.25
    static let observationBudget: TimeInterval = 2.25
    static let cleanupBudget: TimeInterval = 5
    static let normalDwell: TimeInterval = 1

    private(set) var permits: [UUID: Permit] = [:]
    private(set) var queue: [UUID] = []
    private(set) var generations: [UUID: UUID] = [:]
    private(set) var closedOwners: Set<UUID> = []
    private(set) var pressure: BpyMemoryPressure?
    private(set) var sampleAt: TimeInterval?
    private(set) var lastSuccess: TimeInterval?
    private(set) var sensorUnavailable = false
    private(set) var cleanupFailed = false
    private(set) var criticalLatched = false
    private(set) var normalSince: TimeInterval?
    private var lastNormalSample: TimeInterval?
    private(set) var previousClock: BpyClockReading?
    private(set) var wakeRecoveryUntil: TimeInterval?
    private(set) var effects: [Effect] = []

    mutating func clockUnavailable(at clock: BpyClockReading?) {
        sensorUnavailable = true; sampleAt = nil; pressure = nil; normalSince = nil
        queue.removeAll()
        for id in Array(permits.keys) {
            guard var permit = permits[id] else { continue }
            if permit.admission == .queued {
                permit.admission = .failed(.sensorUnavailable); permit.cleanupComplete = true
                effects.append(.init(permit: id, operation: .wake))
            } else if permit.admission == .granted, !permit.cleanupComplete {
                if !permit.grounds.contains(where: { $0.reason == .monitorUnavailable }) {
                    permit.grounds.append(.init(reason: .monitorUnavailable, clock: clock))
                }
                if permit.stop == nil {
                    permit.stop = .monitorUnavailable; permit.cleanupStarted = clock?.awake
                    effects.append(.init(permit: id, operation: .stop(.monitorUnavailable)))
                }
            }
            permits[id] = permit
        }
    }

    mutating func register(owner: UUID, generation: UUID) throws {
        guard !closedOwners.contains(owner), generations[owner] == nil || generations[owner] == generation else {
            throw BpyAdmissionFailure.closed
        }
        generations[owner] = generation
    }

    mutating func enqueue(_ identity: BpyAdmissionIdentity, at clock: BpyClockReading) throws {
        observe(clock)
        guard clock.isValid, identity.timeout.isFinite, identity.timeout > 0,
              identity.insertedAt == clock.awake,
              identity.admissionDeadline > clock.awake,
              identity.admissionDeadline <= clock.awake + identity.timeout else {
            throw BpyAdmissionFailure.timedOut
        }
        guard !closedOwners.contains(identity.owner), generations[identity.owner] == identity.generation else {
            throw BpyAdmissionFailure.closed
        }
        guard !cleanupFailed else { throw BpyAdmissionFailure.cleanupFailed }
        guard !sensorUnavailable else { throw BpyAdmissionFailure.sensorUnavailable }
        if let previous = permits[identity.id] {
            guard previous.identity == identity else { throw BpyAdmissionFailure.closed }
            return
        }
        guard permits.count < 65_536 else { throw BpyAdmissionFailure.cleanupFailed }
        permits[identity.id] = Permit(identity: identity)
        queue.append(identity.id)
        advance(at: clock)
    }

    mutating func sampled(_ level: BpyMemoryPressure?, permanent: Bool, at clock: BpyClockReading) {
        observe(clock)
        guard clock.isValid else {
            sampleAt = nil
            normalSince = nil
            return
        }
        if permanent { sensorUnavailable = true }
        guard !sensorUnavailable, let level else {
            sampleAt = nil
            pressure = nil
            normalSince = nil
            advance(at: clock)
            return
        }
        pressure = level
        sampleAt = clock.awake
        lastSuccess = clock.awake
        wakeRecoveryUntil = nil
        if level == .normal {
            if normalSince == nil || lastNormalSample.map({ clock.awake - $0 > Self.freshness }) ?? true {
                normalSince = clock.awake
            }
            lastNormalSample = clock.awake
        } else { normalSince = nil }
        if level == .critical { criticalLatched = true }
        advance(at: clock)
    }

    mutating func notified(flags: UInt, at clock: BpyClockReading) {
        observe(clock)
        if flags & UInt(BpyMemoryPressure.critical.rawValue) != 0 {
            criticalLatched = true
            sampleAt = nil
            normalSince = nil
        }
        effects.append(.init(permit: nil, operation: .refresh))
        advance(at: clock)
    }

    mutating func advance(at clock: BpyClockReading, admitting: Bool = true) {
        observe(clock)
        guard clock.isValid else { return }
        let now = clock.awake
        let fresh = isFresh(at: now)
        let recoveryDeadline = wakeRecoveryUntil ?? lastSuccess.map { $0 + Self.observationBudget }
        let unobserved = !fresh && (recoveryDeadline == nil || now >= recoveryDeadline!)
        for id in Array(permits.keys) {
            guard var permit = permits[id] else { continue }
            if sensorUnavailable && permit.admission == .queued {
                permit.admission = .failed(.sensorUnavailable)
                queue.removeAll { $0 == id }
                effects.append(.init(permit: id, operation: .wake))
            }
            if permit.admission == .queued || (permit.admission == .granted && permit.firstRelease == nil && permit.stop == nil) {
                if now >= permit.identity.admissionDeadline {
                    if permit.launchPrepared {
                        permit.stop = .deadline
                        permit.grounds.append(.init(reason: .deadline, clock: clock))
                        permit.cleanupStarted = now
                        effects.append(.init(permit: id, operation: .stop(.deadline)))
                    } else {
                        permit.admission = .failed(.timedOut)
                        permit.cleanupComplete = true
                    }
                    queue.removeAll { $0 == id }
                    effects.append(.init(permit: id, operation: .wake))
                }
            }
            if permit.admission == .granted, !permit.cleanupComplete {
                var reasons: [BpyMemoryStop] = []
                if criticalLatched { reasons.append(.pressure) }
                if sensorUnavailable { reasons.append(.monitorUnavailable) }
                else if unobserved { reasons.append(.monitorUnresponsive) }
                if let first = permit.firstRelease, permit.terminalCommit == nil,
                   (permit.collecting ? now > first + permit.identity.runningTimeout + 15
                                      : now >= first + permit.identity.runningTimeout) { reasons.append(.deadline) }
                if let observed = permit.lastServiceObservation, permit.childRunning,
                   now - observed >= Self.observationBudget { reasons.append(.serviceStall) }
                if cleanupFailed { reasons.append(.cleanupFailed) }
                for reason in reasons where !permit.grounds.contains(where: { $0.reason == reason }) {
                    permit.grounds.append(.init(reason: reason, clock: clock))
                }
                if permit.stop == nil, let reason = reasons.first {
                    permit.stop = reason
                    permit.cleanupStarted = now
                    effects.append(.init(permit: id, operation: .stop(reason)))
                }
            }
            permits[id] = permit
        }
        if !cleanupFailed && permits.values.contains(where: {
            !$0.cleanupComplete && $0.cleanupStarted.map { now >= $0 + Self.cleanupBudget } == true
        }) {
            failCleanup(at: clock)
        }
        let pendingCleanup = permits.values.contains { $0.stop != nil && !$0.cleanupComplete }
        if criticalLatched, !pendingCleanup, fresh {
            if pressure == .warning || (pressure == .normal && normalSince.map { now - $0 >= Self.normalDwell } == true) {
                criticalLatched = false
            }
        }
        guard admitting, !cleanupFailed, !sensorUnavailable, !criticalLatched, fresh,
              pressure == .normal || pressure == .warning else { return }
        let maximum = pressure == .warning ? 1 : 2
        var occupied = permits.values.filter { $0.admission == .granted && !$0.cleanupComplete }.count
        while occupied < maximum, let id = queue.first {
            queue.removeFirst()
            guard var permit = permits[id], permit.admission == .queued else { continue }
            guard !closedOwners.contains(permit.identity.owner),
                  generations[permit.identity.owner] == permit.identity.generation else {
                permit.admission = .failed(.closed)
                permits[id] = permit
                effects.append(.init(permit: id, operation: .wake))
                continue
            }
            permit.admission = .granted
            permit.grantedAt = now
            permits[id] = permit
            occupied += 1
            effects.append(.init(permit: id, operation: .wake))
        }
    }

    mutating func releaseChild(permit id: UUID, child: Child, at clock: BpyClockReading) throws {
        advance(at: clock)
        guard clock.isValid, var permit = permits[id], permit.admission == .granted,
              !permit.cleanupComplete, !closedOwners.contains(permit.identity.owner),
              generations[permit.identity.owner] == permit.identity.generation else {
            throw BpyAdmissionFailure.closed
        }
        guard permit.stop == nil, !cleanupFailed else { throw failure(for: permit.stop) }
        guard isFresh(at: clock.awake), pressure != .critical, !criticalLatched else {
            throw BpyLaunchDeferral.observation
        }
        guard !permit.childRunning, !permit.collecting else { throw BpyAdmissionFailure.closed }
        let valid: Bool
        switch permit.identity.kind {
        case .probe: valid = child == .probe && permit.children.isEmpty
        case .boundary: valid = child == .boundary && permit.children.isEmpty
        case .job:
            valid = (child == .worker && permit.children.isEmpty)
                || (child == .verifier && permit.children == [.worker])
                || (child == .autoexec && permit.identity.diagnosticAutoexec && permit.children == [.worker, .verifier])
        }
        guard valid else { throw BpyAdmissionFailure.closed }
        if permit.firstRelease == nil {
            guard clock.awake < permit.identity.admissionDeadline else { throw BpyAdmissionFailure.timedOut }
            permit.firstRelease = clock.awake
        }
        permit.children.append(child)
        permit.releases.append(.init(child: child, clock: clock))
        permit.childRunning = true
        permit.launchPrepared = false
        permit.lastServiceObservation = clock.awake
        permits[id] = permit
    }

    mutating func childExited(permit id: UUID, at clock: BpyClockReading) {
        observe(clock)
        permits[id]?.childRunning = false
        permits[id]?.lastServiceObservation = clock.awake
        if let permit = permits[id], let first = permit.firstRelease,
           clock.awake < first + permit.identity.runningTimeout {
            let terminal: Child
            switch permit.identity.kind {
            case .probe: terminal = .probe
            case .boundary: terminal = .boundary
            case .job: terminal = permit.identity.diagnosticAutoexec ? .autoexec : .verifier
            }
            if permit.children.last == terminal { permits[id]?.collecting = true }
        }
    }

    mutating func prepareLaunch(permit id: UUID, at clock: BpyClockReading) throws {
        advance(at: clock)
        guard var permit = permits[id], permit.admission == .granted,
              permit.stop == nil, !permit.launchPrepared, !permit.childRunning,
              !permit.collecting, !closedOwners.contains(permit.identity.owner),
              generations[permit.identity.owner] == permit.identity.generation else {
            throw BpyAdmissionFailure.closed
        }
        guard isFresh(at: clock.awake), !criticalLatched else { throw BpyLaunchDeferral.observation }
        permit.launchPrepared = true
        permits[id] = permit
    }

    mutating func launchEnded(permit id: UUID) {
        permits[id]?.launchPrepared = false
    }

    mutating func authorizePrepared(permit id: UUID, at clock: BpyClockReading) throws {
        advance(at: clock)
        guard let permit = permits[id], permit.admission == .granted, permit.launchPrepared,
              permit.stop == nil, !permit.cleanupComplete, !closedOwners.contains(permit.identity.owner),
              generations[permit.identity.owner] == permit.identity.generation else { throw BpyAdmissionFailure.closed }
        guard isFresh(at: clock.awake), !criticalLatched else { throw BpyLaunchDeferral.observation }
    }

    mutating func serviceObserved(permit id: UUID, at clock: BpyClockReading) {
        advance(at: clock, admitting: false)
        if clock.isValid { permits[id]?.lastServiceObservation = clock.awake }
    }

    mutating func beginCollection(permit id: UUID, at clock: BpyClockReading) throws {
        advance(at: clock)
        guard var permit = permits[id], permit.admission == .granted,
              permit.stop == nil, !permit.childRunning, permit.collecting, let first = permit.firstRelease,
              clock.awake <= first + permit.identity.runningTimeout + 15 else { throw BpyAdmissionFailure.timedOut }
        permit.collecting = true
        permits[id] = permit
    }

    mutating func commit(permit id: UUID, at clock: BpyClockReading) throws {
        if permits[id]?.terminalCommit != nil, permits[id]?.cleanupComplete == true { return }
        advance(at: clock)
        guard var permit = permits[id], permit.admission == .granted,
              permit.stop == nil, !permit.childRunning, !permit.launchPrepared, permit.collecting,
              let first = permit.firstRelease, clock.awake <= first + permit.identity.runningTimeout + 15 else {
            throw BpyAdmissionFailure.timedOut
        }
        permit.terminalCommit = clock.awake
        permits[id] = permit
        finish(permit: id, at: clock)
    }

    mutating func finish(permit id: UUID, at clock: BpyClockReading) {
        advance(at: clock, admitting: false)
        guard var permit = permits[id], !permit.childRunning, !permit.launchPrepared else { return }
        permit.cleanupComplete = true
        if permit.cleanupFinishedAt == nil { permit.cleanupFinishedAt = clock.awake }
        permits[id] = permit
        effects.append(.init(permit: id, operation: .wake))
        advance(at: clock)
    }

    mutating func cancel(permit id: UUID, reason: BpyMemoryStop, at clock: BpyClockReading) {
        observe(clock)
        guard var permit = permits[id], !permit.cleanupComplete else { return }
        queue.removeAll { $0 == id }
        if permit.firstRelease == nil && !permit.childRunning && !permit.launchPrepared {
            permit.admission = .failed(failure(for: reason))
            permit.cleanupComplete = true
            permit.cleanupFinishedAt = clock.awake
        } else if permit.stop == nil {
            permit.stop = reason
            permit.grounds.append(.init(reason: reason, clock: clock))
            permit.cleanupStarted = clock.awake
            effects.append(.init(permit: id, operation: .stop(reason)))
        }
        permits[id] = permit
        effects.append(.init(permit: id, operation: .wake))
        advance(at: clock)
    }

    mutating func close(owner: UUID, at clock: BpyClockReading) {
        closedOwners.insert(owner)
        generations.removeValue(forKey: owner)
        for id in permits.values.filter({ $0.identity.owner == owner }).map(\.identity.id) {
            cancel(permit: id, reason: .closed, at: clock)
        }
    }

    mutating func forget(permit id: UUID) {
        guard permits[id]?.cleanupComplete == true || permits[id]?.admission != .granted else { return }
        permits.removeValue(forKey: id)
        queue.removeAll { $0 == id }
    }

    mutating func retire(owner: UUID) -> Bool {
        guard !permits.values.contains(where: { $0.identity.owner == owner }) else { return false }
        generations.removeValue(forKey: owner)
        closedOwners.remove(owner)
        return true
    }

    mutating func failCleanup(at clock: BpyClockReading) {
        guard !cleanupFailed else { return }
        cleanupFailed = true
        for id in Array(permits.keys) {
            guard var permit = permits[id] else { continue }
            if permit.admission == .queued {
                permit.admission = .failed(.cleanupFailed)
                effects.append(.init(permit: id, operation: .wake))
            } else if permit.admission == .granted, !permit.cleanupComplete {
                if !permit.grounds.contains(where: { $0.reason == .cleanupFailed }) {
                    permit.grounds.append(.init(reason: .cleanupFailed, clock: clock))
                }
                if permit.stop == nil {
                    permit.stop = .cleanupFailed
                    permit.cleanupStarted = clock.awake
                    effects.append(.init(permit: id, operation: .stop(.cleanupFailed)))
                }
            }
            permits[id] = permit
        }
        queue.removeAll()
    }

    mutating func takeEffects() -> [Effect] {
        defer { effects.removeAll(keepingCapacity: true) }
        return effects
    }

    func isFresh(at now: TimeInterval) -> Bool {
        guard !sensorUnavailable, let sampleAt, let pressure, pressure != .critical,
              now >= sampleAt else { return false }
        return now - sampleAt <= Self.freshness
    }

    private func failure(for reason: BpyMemoryStop?) -> BpyAdmissionFailure {
        switch reason {
        case .closed: .closed
        case .cancelled: .cancelled
        case .cleanupFailed: .cleanupFailed
        case .deadline: .timedOut
        case .pressure: .pressure
        case .monitorUnavailable: .sensorUnavailable
        case .monitorUnresponsive: .sensorUnresponsive
        case .launchFailed: .launchFailed
        case .transportLost: .transportLost
        default: .executionFailed
        }
    }

    private mutating func observe(_ clock: BpyClockReading) {
        guard clock.isValid else { return }
        if let previousClock,
           clock.sleepOffset > previousClock.sleepOffset + previousClock.uncertainty + clock.uncertainty + 0.001 {
            sampleAt = nil
            normalSince = nil
            wakeRecoveryUntil = clock.awake + Self.observationBudget
            effects.append(.init(permit: nil, operation: .refresh))
        }
        if previousClock == nil || clock.continuous >= previousClock!.continuous { previousClock = clock }
    }
}
