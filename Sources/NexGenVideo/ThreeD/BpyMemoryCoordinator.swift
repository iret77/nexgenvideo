import BpyRuntimeProtocol
import Darwin
import Foundation

nonisolated final class BpyMemoryCoordinator: @unchecked Sendable {
    struct SensorReading: Sendable {
        let level: BpyMemoryPressure?
        let error: Int32?
        let permanent: Bool
        var byteCount: Int? = nil
    }

    struct Sample: Codable, Sendable {
        let clock: BpyClockReading
        let pressure: UInt32?
        let error: Int32?
        let source: String
        var byteCount: Int? = nil
    }

    struct StopHandler: Sendable {
        let request: @Sendable (BpyMemoryStop) -> Void
        let cleanup: @Sendable () -> Void
    }

    struct PermitReceipt: Codable, Sendable {
        let identity: BpyAdmissionIdentity
        let failure: BpyAdmissionFailure?
        let grantedAt: TimeInterval?
        let firstRelease: TimeInterval?
        let terminalCommit: TimeInterval?
        let stop: BpyMemoryStop?
        let grounds: [BpyStopGround]
        let cleanupStarted: TimeInterval?
        let cleanupComplete: Bool
        let cleanupFinishedAt: TimeInterval?
        let policy: String
        let samples: [Sample]
        let releases: [BpyChildRelease]
        let authorizationSamples: [Sample]
    }

    enum SelftestSensor: Sendable { case normal, warning, critical, missing, stalled }
    private struct Selftest: Sendable {
        let owners: Set<UUID>
        var generation = UUID()
        var mode: SelftestSensor = .normal
        var warningOnWorker = false
    }

    static let shared = BpyMemoryCoordinator()
    static let policy = "system-pressure-v1"

    private let lock = NSLock()
    private let observationID = UUID()
    private let sensorQueue = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.pressure.sensor", qos: .userInitiated)
    private let watchdogQueue = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.pressure.watchdog", qos: .userInitiated)
    private let cleanupQueue = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.pressure.cleanup", qos: .userInitiated, attributes: .concurrent)
    private let sensor: @Sendable () -> SensorReading
    private let clock: @Sendable () -> BpyClockReading?
    private var state = BpyMemoryState()
    private var wake: [UUID: DispatchSemaphore] = [:]
    private var handlers: [UUID: StopHandler] = [:]
    private var samples: [Sample] = []
    private var authorizationSamples: [UUID: [Sample]] = [:]
    private var activities: [UUID: NSObjectProtocol] = [:]
    private var sampling: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var notifications: DispatchSourceMemoryPressure?
    private var started = false
    private var pendingForget = Set<UUID>()
    private var recoveryCadence = false
    private var clockFailed = false
    private var childReleases: UInt64 = 0
    private var retiringOwners = Set<UUID>()
    private var selftest: Selftest?
    private struct Consumer {
        let owner: UUID
        let cancellation: BpyOperationCancellation
        let began: TimeInterval
        var activity: NSObjectProtocol?
        var stop: BpyMemoryStop?
        var notified = false
    }
    private var consumers: [UUID: Consumer] = [:]
    private var hostReplyReaders: [UUID: Int] = [:]

    init(sensor: @escaping @Sendable () -> SensorReading = BpyMemoryCoordinator.readPressure,
         clock: @escaping @Sendable () -> BpyClockReading? = BpyRuntimeClock.read) {
        self.sensor = sensor
        self.clock = clock
    }

    func register(owner: UUID, generation: UUID) throws {
        try lock.withLock {
            guard selftest == nil || selftest?.owners.contains(owner) == true else { throw BpyAdmissionFailure.closed }
            try state.register(owner: owner, generation: generation)
        }
    }

    func admit(owner: UUID, generation: UUID, transport: UUID, job: UUID?,
               kind: BpyAdmissionIdentity.Kind, timeout: TimeInterval,
               admissionDeadline: TimeInterval? = nil,
               diagnosticAutoexec: Bool = false, cancellation: BpyOperationCancellation,
               progress: @Sendable (TimeInterval) -> Void = { _ in }) throws -> BpyAdmissionIdentity {
        try cancellation.check()
        guard let clock = readClock() else { throw BpyAdmissionFailure.sensorUnavailable }
        let identity = BpyAdmissionIdentity(id: UUID(), owner: owner, generation: generation,
            transport: transport, job: job, kind: kind, insertedAt: clock.awake,
            admissionDeadline: min(admissionDeadline ?? (clock.awake + timeout), clock.awake + timeout),
            timeout: timeout, diagnosticAutoexec: diagnosticAutoexec)
        let signal = DispatchSemaphore(value: 0)
        let registration = cancellation.observe { [weak self] in self?.cancel(identity.id) }
        defer { withExtendedLifetime(registration) {} }
        try lock.withLock {
            wake[identity.id] = signal
            do { try state.enqueue(identity, at: clock) }
            catch { wake.removeValue(forKey: identity.id); throw error }
        }
        start()
        deliverEffects()
        var transferred = false
        defer {
            if !transferred { cancel(identity.id); forget(identity.id) }
        }
        var lastProgress = clock.awake - 1
        while true {
            if cancellation.isCancelled { cancel(identity.id) }
            guard let now = self.readClock() else {
                cancel(identity.id)
                throw BpyAdmissionFailure.sensorUnavailable
            }
            let admission = lock.withLock {
                state.advance(at: now)
                return state.permits[identity.id]?.admission
            }
            deliverEffects()
            switch admission {
            case .granted:
                try cancellation.check()
                transferred = true
                return identity
            case .failed(let error):
                forget(identity.id)
                throw error
            case .queued:
                if now.awake - lastProgress >= 1 {
                    progress(max(0, now.awake - clock.awake))
                    lastProgress = now.awake
                }
                _ = signal.wait(timeout: .now() + .milliseconds(50))
            case nil: throw BpyAdmissionFailure.closed
            }
        }
    }

    func bind(_ id: UUID, handler: StopHandler) throws {
        try lock.withLock {
            guard let permit = state.permits[id], permit.admission == .granted,
                  permit.stop == nil, !permit.cleanupComplete else { throw BpyAdmissionFailure.closed }
            handlers[id] = handler
        }
    }

    func prepareLaunch(_ id: UUID) throws {
        guard let now = readClock() else { throw BpyAdmissionFailure.sensorUnavailable }
        defer { deliverEffects() }
        let needsActivity = try lock.withLock {
            try state.prepareLaunch(permit: id, at: now)
            return activities[id] == nil
        }
        guard needsActivity else { return }
        let activity = BpyObservedActivity.begin(options: .userInitiated,
            reason: "Render and verify a 3D scene", parent: id)
        let retained = lock.withLock {
            guard let permit = state.permits[id], permit.stop == nil,
                  !permit.cleanupComplete, activities[id] == nil else { return false }
            activities[id] = activity
            return true
        }
        if !retained {
            BpyObservedActivity.end(activity)
            throw BpyAdmissionFailure.closed
        }
    }

    func releaseChild(_ id: UUID, child: BpyMemoryState.Child, release: () throws -> Void) throws -> PermitReceipt {
        guard let now = readClock() else { throw BpyAdmissionFailure.sensorUnavailable }
        defer { deliverEffects() }
        return try lock.withLock {
            let previous = state
            try state.releaseChild(permit: id, child: child, at: now)
            do { try release() }
            catch { state = previous; throw error }
            childReleases += 1
            if let authorizedAt = state.sampleAt, let sample = samples.last(where: { $0.clock.awake == authorizedAt }) {
                authorizationSamples[id, default: []].append(sample)
            }
            if child == .worker, let owner = state.permits[id]?.identity.owner, selftest?.owners.contains(owner) == true,
               selftest?.warningOnWorker == true {
                selftest?.mode = .warning
                selftest?.generation = UUID()
            }
            return try receiptLocked(id)
        }
    }

    func authorizePrepared(_ id: UUID, release: () throws -> Void) throws {
        guard let now = readClock() else { throw BpyAdmissionFailure.sensorUnavailable }
        defer { deliverEffects() }
        try lock.withLock {
            try state.authorizePrepared(permit: id, at: now)
            try release()
        }
    }

    func childExited(_ id: UUID) {
        guard let now = readClock() else { return }
        lock.withLock { state.childExited(permit: id, at: now) }
        deliverEffects()
    }

    func launchEnded(_ id: UUID) {
        lock.withLock { state.launchEnded(permit: id) }
    }

    func serviceObserved(_ id: UUID) {
        guard let now = readClock() else { return }
        lock.withLock { state.serviceObserved(permit: id, at: now) }
    }

    func beginCollection(_ id: UUID) throws {
        guard let now = readClock() else { throw BpyAdmissionFailure.sensorUnavailable }
        defer { deliverEffects() }
        try lock.withLock { try state.beginCollection(permit: id, at: now) }
    }

    func commit(_ id: UUID) throws -> PermitReceipt {
        guard let now = readClock() else { throw BpyAdmissionFailure.sensorUnavailable }
        defer { deliverEffects() }
        let finished = try lock.withLock {
            try state.commit(permit: id, at: now)
            return (try receiptLocked(id), activities.removeValue(forKey: id))
        }
        if let activity = finished.1 { BpyObservedActivity.end(activity) }
        BpyRuntimeObservation.shared.processCleanup(controller: observationID, receipt: finished.0)
        return finished.0
    }

    func receipt(_ id: UUID) throws -> PermitReceipt {
        try lock.withLock { try receiptLocked(id) }
    }

    func finish(_ id: UUID) {
        guard let now = readClock() else { return }
        let activity: NSObjectProtocol? = lock.withLock {
            state.finish(permit: id, at: now)
            guard state.permits[id]?.cleanupComplete == true else { return nil }
            return activities.removeValue(forKey: id)
        }
        if let activity { BpyObservedActivity.end(activity) }
        if BpyRuntimeObservation.shared.isEnabled, let receipt = try? self.receipt(id), receipt.cleanupComplete {
            BpyRuntimeObservation.shared.processCleanup(controller: observationID, receipt: receipt)
        }
        if lock.withLock({ pendingForget.contains(id) }) { forget(id) }
        deliverEffects()
    }

    func cancel(_ id: UUID, reason: BpyMemoryStop = .cancelled) {
        guard let now = readClock() else { return }
        lock.withLock { state.cancel(permit: id, reason: reason, at: now) }
        deliverEffects()
    }

    func close(owner: UUID) {
        guard let now = readClock() else { return }
        lock.withLock {
            state.close(owner: owner, at: now)
            for id in Array(consumers.keys) where consumers[id]?.owner == owner {
                if consumers[id]?.stop == nil { consumers[id]?.stop = .closed }
            }
        }
        deliverEffects()
    }

    func forget(_ id: UUID) {
        lock.withLock {
            guard hostReplyReaders[id] == nil else {
                pendingForget.insert(id)
                return
            }
            state.forget(permit: id)
            if state.permits[id] == nil {
                wake.removeValue(forKey: id)
                handlers.removeValue(forKey: id)
                pendingForget.remove(id)
                authorizationSamples.removeValue(forKey: id)
            } else { pendingForget.insert(id) }
            retireOwnersLocked()
        }
    }

    func retainHostReplies(_ id: UUID) throws {
        try lock.withLock {
            _ = try receiptLocked(id)
            hostReplyReaders[id, default: 0] += 1
        }
    }

    func releaseHostReplies(_ id: UUID) {
        let shouldForget = lock.withLock {
            guard let readers = hostReplyReaders[id] else { return false }
            if readers > 1 { hostReplyReaders[id] = readers - 1; return false }
            hostReplyReaders.removeValue(forKey: id)
            return pendingForget.contains(id)
        }
        if shouldForget { forget(id) }
    }

    func cleanupDeadline(for transport: UUID) -> TimeInterval? {
        lock.withLock {
            state.permits.values.filter {
                $0.identity.transport == transport && (!$0.cleanupComplete || hostReplyReaders[$0.identity.id] != nil)
            }.compactMap { $0.cleanupStarted.map { $0 + BpyMemoryState.cleanupBudget } }.min()
        }
    }

    func retire(owner: UUID) {
        lock.withLock { retiringOwners.insert(owner); retireOwnersLocked() }
    }

    private func retireOwnersLocked() {
        for owner in retiringOwners where !consumers.values.contains(where: { $0.owner == owner }) {
            if state.retire(owner: owner) { retiringOwners.remove(owner) }
        }
    }

    private func readClock() -> BpyClockReading? {
        if let reading = clock(), reading.isValid { return reading }
        let fallback = BpyRuntimeClock.read()
        let ended = lock.withLock { () -> [NSObjectProtocol] in
            guard !clockFailed else { return [] }
            clockFailed = true
            state.clockUnavailable(at: fallback)
            let values = Array(activities.values); activities.removeAll()
            return values
        }
        for activity in ended { BpyObservedActivity.end(activity) }
        if !ended.isEmpty || lock.withLock({ !state.effects.isEmpty }) { deliverEffects() }
        return fallback
    }

    private func receiptLocked(_ id: UUID) throws -> PermitReceipt {
        guard let permit = state.permits[id] else { throw BpyAdmissionFailure.closed }
        let failure: BpyAdmissionFailure?
        if case .failed(let error) = permit.admission { failure = error } else { failure = nil }
        return PermitReceipt(identity: permit.identity, failure: failure, grantedAt: permit.grantedAt, firstRelease: permit.firstRelease,
            terminalCommit: permit.terminalCommit, stop: permit.stop, grounds: permit.grounds, cleanupStarted: permit.cleanupStarted,
            cleanupComplete: permit.cleanupComplete, cleanupFinishedAt: permit.cleanupFinishedAt, policy: Self.policy,
            samples: Array(samples.filter { $0.clock.awake >= permit.identity.insertedAt }.suffix(512)), releases: permit.releases,
            authorizationSamples: authorizationSamples[id] ?? [])
    }

    func beginSelftest(owner: UUID, warningOnWorker: Bool = false) throws {
        try beginSelftest(owners: [owner], warningOnWorker: warningOnWorker)
    }

    func beginSelftest(owners: Set<UUID>, warningOnWorker: Bool = false) throws {
        try lock.withLock {
            guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false,
                  !owners.isEmpty, owners.count <= bpyRuntimeServiceNames.count,
                  selftest == nil, !state.cleanupFailed, !state.sensorUnavailable,
                  consumers.values.allSatisfy({ $0.stop != nil || owners.contains($0.owner) }),
                  state.permits.values.allSatisfy({ $0.cleanupComplete || owners.contains($0.identity.owner) }) else {
                throw BpyAdmissionFailure.closed
            }
            selftest = Selftest(owners: owners, warningOnWorker: warningOnWorker)
        }
    }

    func selftestSensor(owner: UUID, mode: SelftestSensor) throws {
        try lock.withLock {
            guard selftest?.owners.contains(owner) == true else { throw BpyAdmissionFailure.closed }
            selftest?.mode = mode; selftest?.generation = UUID()
        }
        sensorQueue.async { [weak self] in self?.sample() }
    }

    func selftestReleaseCount() throws -> UInt64 {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else { throw BpyAdmissionFailure.closed }
        return lock.withLock { childReleases }
    }

    @discardableResult
    func selftestCriticalEvent(owner: UUID) throws -> BpyClockReading {
        guard let now = readClock() else { throw BpyAdmissionFailure.sensorUnavailable }
        try lock.withLock {
            guard selftest?.owners.contains(owner) == true else { throw BpyAdmissionFailure.closed }
            let flags = DispatchSource.MemoryPressureEvent.normal.rawValue | DispatchSource.MemoryPressureEvent.critical.rawValue
            appendSample(.init(clock: now, pressure: UInt32(truncatingIfNeeded: flags), error: nil, source: "selftest-event"))
            state.notified(flags: flags, at: now)
        }
        deliverEffects()
        return now
    }

    func endSelftest(owner: UUID) {
        lock.withLock { if selftest?.owners.contains(owner) == true { selftest = nil } }
        sensorQueue.async { [weak self] in self?.sample() }
    }

    func diagnosticCleanupFailed() throws -> Bool {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else { throw BpyAdmissionFailure.closed }
        return lock.withLock { state.cleanupFailed }
    }

    private var hasWork: Bool {
        state.permits.values.contains { $0.admission == .queued || ($0.admission == .granted && !$0.cleanupComplete) }
            || consumers.values.contains { $0.stop == nil }
    }

    func beginConsumer(owner: UUID, cancellation: BpyOperationCancellation, checking: () throws -> Void = {}) throws -> BpyConsumerWork {
        try checking()
        try cancellation.check()
        guard let clock = readClock() else { throw BpyAdmissionFailure.sensorUnavailable }
        let id = UUID()
        try lock.withLock {
            guard !state.closedOwners.contains(owner), selftest == nil || selftest?.owners.contains(owner) == true else { throw BpyAdmissionFailure.closed }
            consumers[id] = Consumer(owner: owner, cancellation: cancellation, began: clock.awake)
        }
        let work = BpyConsumerWork(id: id, coordinator: self, cancellation: cancellation)
        start()
        var returned = false
        defer { if !returned { work.release() } }
        while true {
            try checking()
            try work.check()
            guard let now = readClock() else { throw BpyAdmissionFailure.sensorUnavailable }
            let ready = lock.withLock { state.isFresh(at: now.awake) && !state.criticalLatched }
            if ready {
                let activity = BpyObservedActivity.begin(options: .userInitiated, reason: "Validate and encode 3D media", parent: id)
                let retained = lock.withLock {
                    guard consumers[id]?.stop == nil, consumers[id] != nil else { return false }
                    consumers[id]?.activity = activity
                    return true
                }
                if !retained { BpyObservedActivity.end(activity); try work.check(); throw BpyAdmissionFailure.closed }
                returned = true
                return work
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    func checkConsumer(_ id: UUID) throws {
        guard let now = readClock() else { throw BpyAdmissionFailure.sensorUnavailable }
        let reason = lock.withLock { () -> BpyMemoryStop? in
            state.advance(at: now, admitting: false)
            updateConsumers(at: now.awake)
            return consumers[id]?.stop ?? (consumers[id] == nil ? .closed : nil)
        }
        deliverEffects()
        if let reason { throw BpyExecutionInterruption(reason: reason) }
    }

    func cancelConsumer(_ id: UUID) {
        lock.withLock { if consumers[id]?.stop == nil { consumers[id]?.stop = .cancelled } }
        deliverEffects()
    }

    func endConsumer(_ id: UUID) {
        let activity = lock.withLock {
            let activity = consumers.removeValue(forKey: id)?.activity
            retireOwnersLocked()
            return activity
        }
        if let activity { BpyObservedActivity.end(activity) }
        reconcileTimers()
    }

    func failConsumerCleanup(_ id: UUID, since began: TimeInterval?) {
        guard let began, began.isFinite, let now = readClock(), now.awake >= began + BpyMemoryState.cleanupBudget else { return }
        lock.withLock {
            guard consumers[id]?.stop != nil else { return }
            consumers[id]?.stop = .cleanupFailed
        }
        deliverEffects()
    }

    private func updateConsumers(at now: TimeInterval) {
        for id in Array(consumers.keys) {
            guard var work = consumers[id], work.stop == nil else { continue }
            let deadline = max(max(state.lastSuccess ?? work.began, work.began) + BpyMemoryState.observationBudget,
                state.wakeRecoveryUntil ?? 0)
            if state.cleanupFailed { work.stop = .cleanupFailed }
            else if state.sensorUnavailable || clockFailed { work.stop = .monitorUnavailable }
            else if state.criticalLatched { work.stop = .pressure }
            else if now >= deadline { work.stop = .monitorUnresponsive }
            consumers[id] = work
        }
    }

    private func start() {
        lock.withLock {
            guard !started, hasWork else { return }
            started = true
            let sampling = DispatchSource.makeTimerSource(queue: sensorQueue)
            sampling.schedule(deadline: .now(), repeating: .milliseconds(50))
            sampling.setEventHandler { [weak self] in self?.sample() }
            let watchdog = DispatchSource.makeTimerSource(queue: watchdogQueue)
            watchdog.schedule(deadline: .now(), repeating: .milliseconds(50))
            watchdog.setEventHandler { [weak self] in self?.tick() }
            let notifications = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: watchdogQueue)
            notifications.setEventHandler { [weak self, weak notifications] in
                guard let self, let notifications, let now = self.readClock() else { return }
                self.lock.withLock {
                    self.appendSample(.init(clock: now, pressure: UInt32(truncatingIfNeeded: notifications.data.rawValue),
                        error: nil, source: "dispatch-event"))
                    self.state.notified(flags: notifications.data.rawValue, at: now)
                }
                self.deliverEffects()
            }
            self.sampling = sampling; self.watchdog = watchdog; self.notifications = notifications
            sampling.resume(); watchdog.resume(); notifications.resume()
            BpyRuntimeObservation.shared.lifecycle(controller: observationID, event: "dispatch-source-resumed")
        }
    }

    private func reconcileTimers() {
        lock.withLock {
            guard started else { return }
            if !hasWork {
                BpyRuntimeObservation.shared.lifecycle(controller: observationID, event: "sampling-ended")
                sampling?.cancel(); watchdog?.cancel(); notifications?.cancel()
                sampling = nil; watchdog = nil; notifications = nil; started = false; recoveryCadence = false
            } else if (state.cleanupFailed || clockFailed), !recoveryCadence {
                recoveryCadence = true
                sampling?.schedule(deadline: .now() + 1, repeating: .seconds(1))
                watchdog?.schedule(deadline: .now() + 1, repeating: .seconds(1))
            }
        }
    }

    private func sample() {
        if lock.withLock({ state.sensorUnavailable }) { return }
        let injected = lock.withLock { selftest }
        let reading: SensorReading
        if let injected {
            switch injected.mode {
            case .normal: reading = .init(level: .normal, error: nil, permanent: false)
            case .warning: reading = .init(level: .warning, error: nil, permanent: false)
            case .critical: reading = .init(level: .critical, error: nil, permanent: false)
            case .missing: reading = .init(level: nil, error: ENOENT, permanent: true)
            case .stalled:
                _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 3)
                reading = .init(level: nil, error: ETIMEDOUT, permanent: false)
            }
        } else { reading = sensor() }
        guard let now = readClock() else { return }
        lock.withLock {
            guard injected?.generation == selftest?.generation else { return }
            appendSample(.init(clock: now, pressure: reading.level?.rawValue,
                error: reading.error, source: injected == nil ? "sysctl" : "selftest-sensor", byteCount: reading.byteCount))
            state.sampled(reading.level, permanent: reading.permanent, at: now)
        }
        deliverEffects()
    }

    private func tick() {
        guard let now = readClock() else { return }
        lock.withLock { state.advance(at: now) }
        deliverEffects()
    }

    private func appendSample(_ sample: Sample) {
        BpyRuntimeObservation.shared.pressure(controller: observationID, sample: sample)
        samples.append(sample)
        if samples.count > 4_096 { samples.removeFirst(samples.count - 4_096) }
    }

    private func deliverEffects() {
        let consumerEffects = lock.withLock { () -> [(BpyOperationCancellation, NSObjectProtocol?)] in
            if let now = state.previousClock?.awake { updateConsumers(at: now) }
            var actions: [(BpyOperationCancellation, NSObjectProtocol?)] = []
            for id in Array(consumers.keys) {
                guard var work = consumers[id], work.stop != nil, !work.notified else { continue }
                work.notified = true
                actions.append((work.cancellation, work.activity))
                work.activity = nil; consumers[id] = work
            }
            return actions
        }
        let batch = lock.withLock { () -> ([BpyMemoryState.Effect], [UUID: StopHandler], [NSObjectProtocol]) in
            let effects = state.takeEffects()
            let ended: [NSObjectProtocol]
            if state.cleanupFailed { ended = Array(activities.values); activities.removeAll() }
            else { ended = [] }
            for effect in effects where effect.operation == .wake {
                if let id = effect.permit { wake[id]?.signal() }
            }
            return (effects, handlers, ended)
        }
        let stops: [(UUID, BpyMemoryStop, StopHandler?)] = batch.0.compactMap {
            guard let id = $0.permit, case .stop(let reason) = $0.operation else { return nil }
            return (id, reason, batch.1[id])
        }
        for (id, reason, handler) in stops {
            if BpyRuntimeObservation.shared.isEnabled {
                let clock = lock.withLock { state.permits[id]?.grounds.first(where: { $0.reason == reason })?.clock }
                BpyRuntimeObservation.shared.stop(controller: observationID, permit: id, reason: reason, decision: clock, hasHandler: handler != nil)
            }
            handler?.request(reason)
        }
        for (cancellation, activity) in consumerEffects {
            if let activity { BpyObservedActivity.end(activity) }
            cancellation.cancel()
        }
        for (id, _, handler) in stops {
            if let handler {
                cleanupQueue.async {
                    let activity = BpyObservedActivity.begin(options: .userInitiatedAllowingIdleSystemSleep,
                        reason: "Recover a 3D rendering process", parent: id)
                    defer { BpyObservedActivity.end(activity) }
                    handler.cleanup()
                }
            } else { finish(id) }
        }
        for activity in batch.2 { BpyObservedActivity.end(activity) }
        if batch.0.contains(where: { $0.operation == .refresh }) {
            sensorQueue.async { [weak self] in self?.sample() }
        }
        reconcileTimers()
    }

    private static func readPressure() -> SensorReading {
        var value: UInt32 = 0
        var size = MemoryLayout.size(ofValue: value)
        let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0)
        guard result == 0 else {
            let error = errno
            return .init(level: nil, error: error, permanent: [ENOENT, ENOTSUP, EACCES, EPERM].contains(error))
        }
        guard size == MemoryLayout<UInt32>.size, let pressure = BpyMemoryPressure(rawValue: value) else {
            return .init(level: nil, error: EPROTO, permanent: true, byteCount: size)
        }
        return .init(level: pressure, error: nil, permanent: false, byteCount: size)
    }
}
