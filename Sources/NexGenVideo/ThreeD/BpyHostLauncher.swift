import BpyRuntimeProtocol
import CryptoKit
import Darwin
import Foundation

nonisolated final class BpyHostLauncher: @unchecked Sendable {
    struct Binding: Sendable {
        let slot: String
        let identity: BpyAdmissionIdentity
        let pair: BpyStoragePair
        let limits: BpyRuntimeLimits
        let workerVolume: BpyRuntimeVolume
        let dataVolume: BpyRuntimeVolume
        let sourceSHA256: String?
        let fingerprint: String?
        let diagnosticDeniedPaths: [String]
    }

    private final class PipeEnds: @unchecked Sendable {
        let read: FileHandle
        let write: FileHandle

        init() throws {
            let descriptors = try BpySpawnGuard.withLock {
                var values: [Int32] = [-1, -1]
                guard pipe(&values) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                do {
                    for descriptor in values {
                        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                    }
                    guard fcntl(values[1], F_SETNOSIGPIPE, 1) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                    return values
                } catch { values.forEach { Darwin.close($0) }; throw error }
            }
            read = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
            write = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        }

        func release() throws {
            var byte: UInt8 = 1
            guard Darwin.write(write.fileDescriptor, &byte, 1) == 1 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            try write.close()
        }
    }

    private final class Launch: @unchecked Sendable {
        let lock = NSLock()
        let request: BpyMonitorRequest
        let spec: BpyHostLaunchSpec
        let binding: Binding
        let service: BpyObservedProcess
        let memory: BpyMemoryCoordinator
        let epoch = UUID()
        let supervisorGate: PipeEnds
        let childGate: PipeEnds
        let reports: PipeEnds
        let output: PipeEnds
        let errors: PipeEnds
        var process: BpyOwnedProcess?
        var supervisor: BpyObservedProcess?
        var observation: BpyProcessObservation?
        var worker: BpyObservedProcess?
        var childPID: Int32?
        var stage: BpyLaunchStage?
        var reportData = Data()
        var log = Data()
        var logBase: UInt64 = 0
        var logTotal = 0
        var streams = BpyLaunchLifecycle.Streams()
        var replay: BpyLaunchReplay?
        var launchError: Int32?
        var spawnFinished = false
        var released = false
        var childReleased = false
        var termination: BpyProcessTermination?
        var workerEnded = false
        var stop: BpyMemoryStop?
        var stopAt: TimeInterval?
        var stopDeliveredAt: TimeInterval?
        var snapshot: BpyMonitorResponse?
        var snapshotAt: TimeInterval?
        let authorizationLock = NSLock()
        let diagnosticGate: PipeEnds
        var diagnosticBaseline: BpyObservedProcess?
        var diagnosticObserved: BpyObservedProcess?
        var footprintProbe: BpyFootprintProbe?
        var diagnosticChunks: [UInt64] = []
        var diagnosticCapReached = false
        var diagnosticMapping: BpyMappingDiagnostic?
        var diagnosticAllocationObjectBytes: Int?
        var diagnosticStdoutBurst: BpyStdoutBurst?
        var outputDigest = SHA256()
        var outputBytes: UInt64 = 0
        var outputPaused: BpyClockReading?
        var outputResumed: BpyClockReading?
        var childReadyWritten: BpyClockReading?
        var childReadyReceived: BpyClockReading?
        private var ioRetired = false
        var configurationFile: BpyRuntimeFile?

        init(request: BpyMonitorRequest, spec: BpyHostLaunchSpec, binding: Binding, service: BpyObservedProcess, memory: BpyMemoryCoordinator) throws {
            self.request = request; self.spec = spec; self.binding = binding; self.service = service
            self.memory = memory
            supervisorGate = try PipeEnds(); childGate = try PipeEnds(); reports = try PipeEnds()
            output = try PipeEnds(); errors = try PipeEnds(); diagnosticGate = try PipeEnds()
        }

        func startReaders() {
            startOutputReaders()
            startReportReader()
        }

        private func startOutputReaders() {
            for (handle, isError) in [(output.read, false), (errors.read, true)] {
                handle.readabilityHandler = { [weak self] handle in
                    guard let self else { return }
                    let data: Data
                    do { data = try Self.readReady(handle, maximum: 65_536) }
                    catch {
                        self.recordReadFailure(error, channel: isError ? .errors : .output, handle: handle)
                        return
                    }
                    self.lock.withLock {
                        if !data.isEmpty {
                            if !isError, self.spec.boundary == .diagnosticStdoutBurst {
                                self.outputDigest.update(data: data)
                                self.outputBytes += UInt64(data.count)
                            }
                            let retained = data.prefix(max(0, self.binding.limits.stdoutBytes - self.logTotal))
                            self.log.append(contentsOf: retained)
                            self.logTotal += retained.count
                        } else {
                            if isError { self.streams.errors.reachedEOF() } else { self.streams.output.reachedEOF() }
                            handle.readabilityHandler = nil
                        }
                    }
                }
            }
        }

        private func startReportReader() {
            reports.read.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data: Data
                do { data = try Self.readReady(handle, maximum: 4_096) }
                catch {
                    self.recordReadFailure(error, channel: .report, handle: handle)
                    return
                }
                self.lock.withLock {
                    guard !data.isEmpty else {
                        if !self.reportData.isEmpty { self.stage = .invalidLaunch }
                        self.streams.report.reachedEOF()
                        handle.readabilityHandler = nil
                        return
                    }
                    guard self.reportData.count + data.count <= 16_384 else {
                        self.stage = .invalidLaunch
                        return
                    }
                    self.reportData.append(data)
                    while let newline = self.reportData.firstIndex(of: 0x0a) {
                        let line = self.reportData.prefix(upTo: newline)
                        self.reportData.removeSubrange(...newline)
                        guard let report = try? JSONDecoder().decode(BpyLaunchReport.self, from: line),
                              report.schema == "nexgenvideo/bpy-launch-report/1", report.pid > 1 else {
                            self.stage = .invalidLaunch
                            continue
                        }
                        if report.stage == .childReady {
                            self.childPID = report.pid
                            self.childReadyWritten = report.clock
                            self.childReadyReceived = BpyRuntimeClock.read()
                        }
                        if let burst = report.stdoutBurst {
                            guard self.spec.boundary == .diagnosticStdoutBurst, report.stage == .stdoutBurstComplete,
                                  report.pid == self.childPID else { self.stage = .invalidLaunch; continue }
                            self.diagnosticStdoutBurst = burst
                        }
                        if let mapping = report.mapping {
                            guard self.spec.boundary == .diagnosticVirtualMapping, report.stage == .virtualMappingSucceeded,
                                  report.pid == self.childPID else { self.stage = .invalidLaunch; continue }
                            self.diagnosticMapping = mapping
                        }
                        if report.stage == .diagnosticProgress || report.stage == .diagnosticAllocationCap {
                            guard self.spec.boundary?.isFootprintDiagnostic == true,
                                  report.pid == self.childPID, let bytes = report.requestedBytes else {
                                self.stage = .invalidLaunch; continue
                            }
                            if self.spec.boundary == .diagnosticPythonFootprint {
                                guard let size = report.allocationObjectBytes, (257...512).contains(size),
                                      self.diagnosticAllocationObjectBytes.map({ $0 == size }) ?? true else {
                                    self.stage = .invalidLaunch; continue
                                }
                                self.diagnosticAllocationObjectBytes = size
                            }
                            if report.stage == .diagnosticProgress {
                                let previous = self.diagnosticChunks.last ?? 0
                                guard previous < BpyFootprintProbe.maximum, bytes == previous + BpyFootprintProbe.chunk else {
                                    self.stage = .invalidLaunch; continue
                                }
                                self.diagnosticChunks.append(bytes)
                            } else {
                                guard bytes == BpyFootprintProbe.maximum, self.diagnosticChunks.last == bytes else {
                                    self.stage = .invalidLaunch; continue
                                }
                                self.diagnosticCapReached = true
                            }
                            continue
                        }
                        self.stage = report.stage
                    }
                }
            }
        }

        func pauseOutput() throws {
            guard let clock = BpyRuntimeClock.read() else { throw BpyAdmissionFailure.sensorUnavailable }
            try lock.withLock {
                guard !ioRetired, outputPaused == nil, spec.boundary == .diagnosticStdoutBurst else { throw POSIXError(.EPERM) }
                outputPaused = clock
            }
            output.read.readabilityHandler = nil; errors.read.readabilityHandler = nil
        }

        func resumeOutput() {
            let resume = lock.withLock {
                guard !ioRetired, outputPaused != nil, outputResumed == nil, let clock = BpyRuntimeClock.read() else { return false }
                outputResumed = clock
                return true
            }
            if resume { startOutputReaders() }
        }

        func stdoutCapture() -> BpyStdoutCapture? {
            guard let burst = diagnosticStdoutBurst, let paused = outputPaused, let resumed = outputResumed,
                  let written = childReadyWritten, let received = childReadyReceived else { return nil }
            var digest = outputDigest
            return .init(burst: burst, capturedBytes: outputBytes,
                capturedSHA256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                paused: paused, resumed: resumed, childReadyWritten: written, childReadyReceived: received)
        }

        private static func readReady(_ handle: FileHandle, maximum: Int) throws -> Data {
            var buffer = [UInt8](repeating: 0, count: maximum)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress!, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                return Data(buffer.prefix(count))
            }
        }

        private func recordReadFailure(_ error: any Error, channel: BpyLaunchLifecycle.Channel, handle: FileHandle) {
            let code = Int32((error as NSError).code)
            let reserved = lock.withLock {
                guard !ioRetired, streams[channel] == .open else { return false }
                streams[channel] = .failing(code)
                return true
            }
            guard reserved else { return }
            let fallback = lock.withLock { stop ?? .observationFailed }
            let reason = (try? memory.receipt(spec.permit).stop) ?? fallback
            requestStop(reason)
            memory.cancel(spec.permit, reason: reason)
            lock.withLock {
                if !ioRetired, streams[channel] == .failing(code) { streams[channel] = .failed(code) }
                handle.readabilityHandler = nil
            }
            if channel != .report { try? handle.close() }
        }

        func requestStop(_ reason: BpyMemoryStop) {
            let process: BpyOwnedProcess? = lock.withLock {
                if stop == nil { stop = reason; stopAt = BpyRuntimeClock.read()?.awake }
                return self.process
            }
            if let process {
                do {
                    try process.signal(SIGTERM)
                    lock.withLock { if stopDeliveredAt == nil { stopDeliveredAt = BpyRuntimeClock.read()?.awake } }
                } catch { }
            }
        }

        func closeParentCopies() {
            for handle in [supervisorGate.read, childGate.read, diagnosticGate.read, reports.write, output.write, errors.write] {
                try? handle.close()
            }
        }

        func workerHasEnded() throws -> Bool {
            let identity = lock.withLock { (worker, childPID, streams.report == .eof) }
            guard identity.2 else { return false }
            if let worker = identity.0 { return try BpyKernelInspection.process(worker.pid)?.start != worker.start }
            if let pid = identity.1 { return try BpyKernelInspection.process(pid) == nil }
            return true
        }

        var reaped: Bool { lock.withLock { (termination != nil && workerEnded) || (launchError != nil && process == nil) } }

        func releaseConfiguration() {
            let file = lock.withLock { let file = configurationFile; configurationFile = nil; return file }
            file?.release()
        }

        func retireIO() {
            let retire = lock.withLock {
                let unstarted = launchError != nil && process == nil
                guard !ioRetired, unstarted || (termination != nil && workerEnded && streams.terminal) else { return false }
                ioRetired = true; snapshot = nil; reportData.removeAll()
                return true
            }
            guard retire else { return }
            for pipe in [supervisorGate, childGate, reports, output, errors, diagnosticGate] {
                pipe.read.readabilityHandler = nil
                try? pipe.read.close(); try? pipe.write.close()
            }
        }
    }

    private final class Quarantine: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.launch.quarantine", qos: .utility)
        private var launches: [UUID: Launch] = [:]
        private var timer: DispatchSourceTimer?

        func retain(_ values: [Launch]) {
            lock.withLock {
                for value in values { launches[value.request.execution] = value }
                guard !launches.isEmpty, timer == nil else { return }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
                timer.setEventHandler { [weak self] in self?.reap() }
                self.timer = timer
                timer.resume()
            }
        }

        private func reap() {
            let values = lock.withLock { Array(launches.values) }
            for launch in values {
                do {
                    guard let process = launch.lock.withLock({ launch.process }), try !process.isRunning else { continue }
                    guard try launch.workerHasEnded() else { continue }
                    let termination = try process.waitForTermination(timeout: 0)
                    launch.memory.launchEnded(launch.spec.permit)
                    launch.memory.childExited(launch.spec.permit)
                    launch.memory.finish(launch.spec.permit)
                    launch.lock.withLock { launch.termination = termination; launch.workerEnded = true }
                    launch.releaseConfiguration()
                    _ = lock.withLock { launches.removeValue(forKey: launch.request.execution) }
                } catch { continue }
            }
            lock.withLock {
                if launches.isEmpty { timer?.cancel(); timer = nil }
            }
        }
    }

    private static let quarantine = Quarantine()

    private final class ProcessRelease: @unchecked Sendable { var process: BpyOwnedProcess? }
    private struct FailedLaunch {
        let specification: String
        let service: BpyObservedProcess
        let code: Int32
        let epoch: UUID?
    }

    private let lock = NSLock()
    private let transport: UUID
    private let layout: BpyRuntimeBundleLayout
    private let memory: BpyMemoryCoordinator
    private let observed: @Sendable (BpyObservedProcess?) -> Void
    private let observationQueue = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.launch.identity")
    private var observedExecution: UUID?
    private let watcher = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.launch.observer", qos: .userInitiated)
    private var bindings: [UUID: Binding] = [:]
    private var launches: [UUID: Launch] = [:]
    private var retired: [UUID: BpyRetiredLaunch] = [:]
    private var failed: [UUID: FailedLaunch] = [:]
    private var stoppedPermits = Set<UUID>()
    private let retirement = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.launch.retirement", qos: .utility)
    private var authorizedPermits: Set<UUID> = []
    private var timer: DispatchSourceTimer?
    private var canaryWrite: URL?

    init(transport: UUID, layout: BpyRuntimeBundleLayout, memory: BpyMemoryCoordinator = .shared,
         observed: @escaping @Sendable (BpyObservedProcess?) -> Void) {
        self.transport = transport; self.layout = layout; self.memory = memory; self.observed = observed
    }

    deinit {
        timer?.cancel()
        Self.quarantine.retain(launches.values.filter { !$0.reaped })
    }

    func install(_ binding: Binding) throws {
        guard binding.identity.transport == transport, binding.pair.isValid(limits: binding.limits),
              binding.workerVolume.lease == binding.pair.worker, binding.dataVolume.lease == binding.pair.data else {
            throw BpyAdmissionFailure.closed
        }
        try BpyRetentionLedger.shared.configure(slot: binding.slot, limits: binding.limits)
        try lock.withLock {
            guard bindings[binding.identity.id] == nil, !stoppedPermits.contains(binding.identity.id) else { throw BpyAdmissionFailure.closed }
            bindings[binding.identity.id] = binding
        }
        do {
            try memory.bind(binding.identity.id, handler: .init(request: { [weak self] reason in
                self?.requestStop(permit: binding.identity.id, reason: reason)
            }, cleanup: { [weak self] in self?.cleanup(permit: binding.identity.id) }))
        } catch { finishUnstarted(permit: binding.identity.id); throw error }
    }

    func authorize(execution: UUID, pid: Int32, start: UInt64) throws -> Bool {
        if let previous = lock.withLock({ retired[execution] }) { return try previous.authorize(pid: pid, start: start) }
        guard let launch = lock.withLock({ launches[execution] }) else { throw POSIXError(.EPERM) }
        launch.authorizationLock.lock()
        defer { launch.authorizationLock.unlock() }
        guard
              let supervisor = launch.lock.withLock({ launch.supervisor }),
              supervisor.pid == pid, supervisor.start == start else { throw POSIXError(.EPERM) }
        if launch.lock.withLock({ launch.released }) { return true }
        if launch.reaped || launch.lock.withLock({ launch.stop != nil }) { return false }
        if try memory.receipt(launch.spec.permit).stop != nil { return false }
        guard try BpyKernelInspection.matches(supervisor) else {
            if (try memory.receipt(launch.spec.permit)).stop != nil { return false }
            if let process = launch.lock.withLock({ launch.process }), try !process.isRunning { return false }
            throw POSIXError(.EPERM)
        }
        guard try BpyLaunchGateRelease.authorize(memory: memory, permit: launch.spec.permit, lock: launch.lock,
            stopped: { launch.stop != nil }, writing: { try launch.supervisorGate.release() },
            released: { launch.released = true }) else { return false }
        _ = lock.withLock { authorizedPermits.insert(launch.spec.permit) }
        return true
    }

    func diagnosticGate(execution: UUID) throws -> BpyHeldGateEvidence {
        guard isSelfTest, let launch = lock.withLock({ launches[execution] }) else { throw POSIXError(.EPERM) }
        launch.authorizationLock.lock()
        defer { launch.authorizationLock.unlock() }
        let supervisor = try launch.lock.withLock {
            guard launch.spec.mode == .job, !launch.released, !launch.childReleased,
                  launch.childPID == nil, launch.stop == nil, let supervisor = launch.supervisor else { throw POSIXError(.EPERM) }
            return supervisor
        }
        guard try BpyKernelInspection.matches(supervisor) else { throw POSIXError(.EPERM) }
        guard let clock = BpyRuntimeClock.read(), let source = launch.binding.sourceSHA256 else { throw POSIXError(.EIO) }
        return .init(execution: execution, permit: launch.spec.permit, process: supervisor, clock: clock,
            sourceSHA256: source, configurationSHA256: launch.spec.configurationSHA256)
    }

    func diagnosticEnded(execution: UUID) throws -> BpyMonitorResponse {
        guard isSelfTest, let record = lock.withLock({ retired[execution] }) else { throw POSIXError(.EPERM) }
        return record.diagnosticSnapshot
    }

    func diagnosticReapedLaunch(execution: UUID) throws -> Bool {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false,
              let launch = lock.withLock({ launches[execution] }) else { throw POSIXError(.EPERM) }
        return launch.reaped
    }

    func diagnosticRecovered() throws -> Bool {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else { throw POSIXError(.EPERM) }
        return recovered
    }

    func inspect(_ request: BpyMonitorRequest, service: BpyObservedProcess) throws -> BpyMonitorResponse {
        guard request.schema == "nexgenvideo/bpy-monitor-request/2", request.transport == transport else {
            throw POSIXError(.EPERM)
        }
        if request.operation == .launch { return try launch(request, service: service) }
        if let previous = lock.withLock({ retired[request.execution] }) {
            let result = try previous.inspect(request, peer: service, memory: memory)
            pruneBinding(permit: previous.permit)
            return result
        }
        let launch = try lock.withLock {
            guard let launch = launches[request.execution] else { throw POSIXError(.EPERM) }
            return launch
        }
        guard let replay = launch.lock.withLock({ launch.replay }) else { throw POSIXError(.EPERM) }
        if let saved = try replay.begin(request, peer: service) { return saved }
        var result: BpyMonitorResponse
        do {
        switch request.operation {
        case .sample, .release:
            let fresh = launch.lock.withLock { launch.snapshotAt }
            if launch.lock.withLock({ launch.childReleased && launch.termination == nil }) {
                guard let fresh, try BpyRuntimeClock.awakeSeconds() - fresh <= BpyMemoryState.observationBudget else {
                    throw POSIXError(.ETIMEDOUT)
                }
                memory.serviceObserved(launch.spec.permit)
            }
            result = try response(request, launch: launch)
        case .terminate:
            let reason: BpyMemoryStop
            switch request.stopCause ?? .cancelled {
            case .cancelled: reason = .cancelled
            case .disk: reason = .disk
            case .fileCount: reason = .fileCount
            case .processCount: reason = .processCount
            case .failure: reason = .executionFailed
            }
            memory.cancel(launch.spec.permit, reason: reason)
            result = try response(request, launch: launch)
        case .collecting:
            try memory.beginCollection(launch.spec.permit)
            result = try response(request, launch: launch)
        case .commit:
            _ = try memory.commit(launch.spec.permit)
            result = try response(request, launch: launch, status: .committed)
        case .detach:
            guard launch.reaped else { throw POSIXError(.EBUSY) }
            result = try response(request, launch: launch, status: .detached)
            guard result.outputComplete else { throw POSIXError(.EBUSY) }
            launch.retireIO()
        default: throw POSIXError(.EPERM)
        }
        } catch {
            result = .init(status: .refused, request: request, epoch: launch.epoch, service: launch.service,
                errorCode: Int32((error as NSError).code))
        }
        try replay.complete(result, request: request)
        if result.status == .detached { retire(launch, response: result) }
        return result
    }

    private func launch(_ request: BpyMonitorRequest, service: BpyObservedProcess) throws -> BpyMonitorResponse {
        guard let spec = request.launch, spec.schema == "nexgenvideo/bpy-host-launch/2",
              request.epoch == nil, request.sequence == 0 else {
            throw POSIXError(.EPERM)
        }
        if let previous = lock.withLock({ retired[request.execution] }) {
            return try previous.launch(request, spec: spec, peer: service)
        }
        if let previous = lock.withLock({ failed[request.execution] }) {
            guard try BpyRetiredLaunch.digest(spec) == previous.specification,
                  previous.service.pid == service.pid, previous.service.start == service.start,
                  previous.service.executable == service.executable else { throw POSIXError(.EPERM) }
            return .init(status: .refused, request: request, epoch: previous.epoch, service: service, errorCode: previous.code)
        }
        guard let binding = lock.withLock({ stoppedPermits.contains(spec.permit) ? nil : bindings[spec.permit] }), spec.job == binding.identity.job,
              spec.workerLease == binding.pair.worker.id, spec.dataLease == binding.pair.data.id,
              spec.injections.isEmpty || isSelfTest,
              spec.mode != .autoexecPositive || (binding.identity.diagnosticAutoexec && isSelfTest),
              spec.mode != .boundary || isSelfTest else { throw POSIXError(.EPERM) }
        if let previous = lock.withLock({ launches[request.execution] }) {
            guard previous.spec == spec, previous.service.pid == service.pid,
                  previous.service.start == service.start else { throw POSIXError(.EPERM) }
            return try response(request, launch: previous)
        }
        do { try memory.prepareLaunch(spec.permit) }
        catch is BpyLaunchDeferral {
            let receipt = try memory.receipt(spec.permit)
            return .init(status: .deferred, request: request, service: service, firstRelease: receipt.firstRelease,
                admissionDeadline: binding.identity.admissionDeadline,
                runningDeadline: receipt.firstRelease.map { $0 + binding.identity.runningTimeout })
        }
        var created: Launch?
        do {
            let launch = try Launch(request: request, spec: spec, binding: binding, service: service, memory: memory)
            created = launch
            try lock.withLock {
                guard launches.count + retired.count + failed.count < 65_536,
                      bindings[spec.permit] != nil, !stoppedPermits.contains(spec.permit),
                      !launches.values.contains(where: { !$0.reaped }) else { throw POSIXError(.EBUSY) }
                launches[request.execution] = launch
            }
            try spawn(launch)
        } catch {
            if let created {
                created.lock.withLock { created.launchError = Int32((error as NSError).code) }
                if created.lock.withLock({ created.process != nil }) { created.closeParentCopies() }
                created.requestStop(.launchFailed)
            }
            if created.map({ value in value.lock.withLock { value.process == nil } }) ?? true {
                memory.launchEnded(spec.permit)
                created?.releaseConfiguration()
                created?.retireIO()
            }
            memory.cancel(spec.permit, reason: .launchFailed)
            if created.map({ value in value.lock.withLock { value.process == nil } }) ?? true {
                memory.finish(spec.permit)
                let failure = try? BpyRetiredLaunch.digest(spec)
                if let failure {
                    lock.withLock {
                        failed[request.execution] = .init(specification: failure, service: service,
                            code: Int32((error as NSError).code), epoch: created?.epoch)
                        launches.removeValue(forKey: request.execution)
                    }
                }
                pruneBinding(permit: spec.permit)
            }
            startWatcher()
            return .init(status: .refused, request: request, epoch: created?.epoch,
                service: service, errorCode: Int32((error as NSError).code))
        }
        guard let launch = created else { throw POSIXError(.EIO) }
        startWatcher()
        return try response(request, launch: launch, status: .launched)
    }

    private func spawn(_ launch: Launch) throws {
        defer { launch.lock.withLock { launch.spawnFinished = true } }
        let spec = launch.spec, pair = launch.binding.pair
        guard try memory.receipt(spec.permit).stop == nil, launch.lock.withLock({ launch.stop == nil }) else {
            throw BpyAdmissionFailure.closed
        }
        let workerMount = try BpyStoragePaths.validateMount(pair.worker, maximumBytes: launch.binding.limits.physicalStorageBytes)
        defer { Darwin.close(workerMount) }
        guard let dataBytes = launch.binding.limits.dataStorageBytes else { throw POSIXError(.EINVAL) }
        let dataMount = try BpyStoragePaths.validateMount(pair.data, maximumBytes: dataBytes)
        defer { Darwin.close(dataMount) }
        try validate(spec, identity: launch.binding.identity)
        let root = try open(spec.workerRoot, relativeTo: workerMount, device: pair.worker.device, directory: true)
        defer { Darwin.close(root) }
        let configuration = try open(spec.configuration, relativeTo: dataMount, device: pair.data.device, directory: false)
        defer { Darwin.close(configuration) }
        let rootPath = try path(root)
        let configurationBytes = try captureConfiguration(configuration, expectedSHA256: spec.configurationSHA256)
        var sourceDescriptor: Int32 = -1
        defer { if sourceDescriptor >= 0 { Darwin.close(sourceDescriptor) } }
        var readPaths: [String] = []
        for (files, mount, device) in [(spec.readFiles, dataMount, pair.data.device),
                                      (spec.workerReadFiles, workerMount, pair.worker.device)] {
            for name in files {
                let isSource = spec.mode == .job && name == transport.uuidString + "/jobs/" + (spec.job?.uuidString ?? "") + "/source.py"
                let file = try open(name, relativeTo: mount, device: device, directory: false,
                    maximum: isSource ? 4 * 1_024 * 1_024 : launch.binding.limits.inputBytes + launch.binding.limits.outputBytes)
                defer { Darwin.close(file) }
                if isSource {
                    guard let expected = launch.binding.sourceSHA256,
                          try digest(file) == expected else { throw POSIXError(.EPERM) }
                    sourceDescriptor = fcntl(file, F_DUPFD_CLOEXEC, 0)
                    guard sourceDescriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                }
                readPaths.append(try path(file))
            }
        }
        let frozen = try BpyHostConfiguration.freeze(configurationBytes, context: .init(mode: spec.mode,
            identity: launch.binding.identity, limits: launch.binding.limits,
            workerMount: pair.worker.mountPath, dataMount: pair.data.mountPath, root: rootPath,
            sitePackages: spec.mode == .boundary ? "" : try BpyRuntimePath.canonical(layout.runtime.appendingPathComponent("site-packages")),
            readPaths: Set(readPaths), sourceSHA256: launch.binding.sourceSHA256, fingerprint: launch.binding.fingerprint,
            diagnosticDeniedPaths: launch.binding.diagnosticDeniedPaths))
        let configurationRoot = try BpyHostStaging.shared.directory("launch-" + launch.request.execution.uuidString)
        let ledger = BpyRetentionLedger.shared
        let reservation = try ledger.reserve(slot: launch.binding.slot, owner: launch.binding.identity.owner,
            kind: .control, bytes: UInt64(frozen.count))
        let frozenFile: BpyRuntimeFile
        var created: BpyRuntimeFile?
        do {
            frozenFile = try ledger.creatingFile(reservation, bytes: UInt64(frozen.count)) {
                try BpyRuntimeFile.copy(data: frozen, to: configurationRoot.appendingPathComponent("worker.json"),
                    maximum: BpyHostConfiguration.maximumBytes, disposed: { removed, _ in
                        if removed { ledger.release(reservation); _ = rmdir(configurationRoot.path) }
                    })
            }
            created = frozenFile
            try ledger.bind(reservation, file: frozenFile)
            ledger.settle(reservation)
        } catch {
            if let created { created.release() } else { ledger.settle(reservation) }
            throw error
        }
        launch.lock.withLock { launch.configurationFile = frozenFile }
        let boundaryPath = spec.boundary == .externalReadonly ? readPaths.last : nil
        readPaths.append(frozenFile.url.path)
        guard let host = try BpyKernelInspection.process(getpid()),
              let canaryRead = Bundle.main.executableURL else { throw POSIXError(.EIO) }
        let canaryWrite = try lock.withLock { () -> URL in
            if let canaryWrite = self.canaryWrite { return canaryWrite }
            let directory = try BpyHostStaging.shared.directory("canary-" + transport.uuidString)
            let file = directory.appendingPathComponent("outside-write")
            try Data("host canary".utf8).write(to: file, options: .withoutOverwriting)
            self.canaryWrite = file
            return file
        }
        let environment = ["HOME": rootPath + "/home", "TMPDIR": rootPath + "/tmp", "LANG": "en_US.UTF-8",
            "BLENDER_USER_CONFIG": rootPath + "/blender-config", "BLENDER_USER_SCRIPTS": rootPath + "/blender-scripts",
            "BLENDER_USER_DATAFILES": rootPath + "/blender-data", "PYTHONDONTWRITEBYTECODE": "1"]
        let boundaryOnly = spec.mode == .boundary && spec.boundary != .diagnosticPythonFootprint
        let configurationValue = BpySupervisorConfiguration(hostPID: host.pid, hostStart: host.start,
            mode: spec.mode, python: boundaryOnly ? try BpyRuntimePath.canonical(layout.supervisor)
                : try BpyRuntimePath.canonical(layout.runtime.appendingPathComponent("python/bin/python3.13")),
            worker: boundaryOnly ? try BpyRuntimePath.canonical(layout.supervisor)
                : try BpyRuntimePath.canonical(layout.runtime.appendingPathComponent("worker.py")),
            runtime: try BpyRuntimePath.canonical(boundaryOnly ? layout.service.appendingPathComponent("Contents") : layout.runtime), readPaths: Array(Set(readPaths)).sorted(),
            canaryRead: try BpyRuntimePath.canonical(canaryRead), canaryWrite: canaryWrite.path,
            boundary: spec.boundary, boundaryPath: boundaryPath ?? canaryWrite.path,
            injections: spec.injections, environment: environment)
        launch.startReaders()
        guard try memory.receipt(spec.permit).stop == nil, launch.lock.withLock({ launch.stop == nil }) else {
            throw BpyAdmissionFailure.closed
        }
        var descriptors = [BpyLaunchDescriptors.release: launch.supervisorGate.read.fileDescriptor,
            BpyLaunchDescriptors.report: launch.reports.write.fileDescriptor,
            BpyLaunchDescriptors.childRelease: launch.childGate.read.fileDescriptor,
            BpyLaunchDescriptors.root: root,
            BpyLaunchDescriptors.diagnosticRelease: launch.diagnosticGate.read.fileDescriptor]
        if sourceDescriptor >= 0 { descriptors[BpyLaunchDescriptors.source] = sourceDescriptor }
        let process = try frozenFile.withDescriptor { frozenDescriptor in
            descriptors[BpyLaunchDescriptors.configuration] = frozenDescriptor
            return try BpyOwnedProcess(executable: layout.supervisor,
            arguments: ["host-supervise", try JSONEncoder().encode(configurationValue).base64EncodedString()],
            environment: environment, directory: URL(fileURLWithPath: rootPath), output: launch.output.write,
            errors: launch.errors.write, allowsForcedTermination: false, directoryDescriptor: root,
            inheritedDescriptors: descriptors)
        }
        launch.lock.withLock { launch.process = process }
        try launch.supervisorGate.read.close(); try launch.childGate.read.close(); try launch.diagnosticGate.read.close()
        try launch.reports.write.close(); try launch.output.write.close(); try launch.errors.write.close()
        guard let supervisor = try BpyKernelInspection.process(process.processIdentifier),
              supervisor.parent == host.pid, supervisor.executable == (try BpyRuntimePath.canonical(layout.supervisor)) else {
            throw POSIXError(.EPERM)
        }
        try launch.binding.workerVolume.bindLaunch(supervisor: supervisor)
        try launch.binding.dataVolume.bindLaunch(supervisor: supervisor)
        let workerExecutable = try BpyRuntimePath.canonical(spec.mode == .boundary && spec.boundary != .diagnosticPythonFootprint ? layout.supervisor
            : layout.runtime.appendingPathComponent("python/bin/python3.13"))
        let observation = BpyProcessObservation(supervisor: supervisor, workerExecutable: workerExecutable)
        let stopped = launch.lock.withLock {
            launch.supervisor = supervisor; launch.observation = observation
            launch.replay = BpyLaunchReplay(epoch: launch.epoch, transport: transport,
                execution: launch.request.execution, service: launch.service, supervisor: supervisor)
            return launch.stop != nil
        }
        publish(supervisor, execution: launch.request.execution)
        if stopped { launch.requestStop(.closed) }
        else if launch.binding.identity.kind != .job || lock.withLock({ authorizedPermits.contains(spec.permit) }) {
            _ = try authorize(execution: launch.request.execution, pid: supervisor.pid, start: supervisor.start)
        }
    }

    private func startWatcher() {
        lock.withLock {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: watcher)
            timer.schedule(deadline: .now(), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.observeLaunches() }
            self.timer = timer
            timer.resume()
        }
    }

    private func observeLaunches() {
        let active = lock.withLock { Array(launches.values) }
        for launch in active {
            if !launch.reaped {
                do { try observe(launch) }
                catch is BpyLaunchDeferral { continue }
                catch {
                    let reason = launch.lock.withLock { launch.stop } ?? Self.observationStop(error: error, stage: launch.lock.withLock { launch.stage })
                    launch.requestStop(reason)
                    memory.cancel(launch.spec.permit, reason: reason)
                }
            }
            retireFailure(launch)
        }
        lock.withLock {
            if launches.values.allSatisfy({ value in value.reaped && value.lock.withLock { value.launchError == nil } }) {
                timer?.cancel(); timer = nil
            }
        }
    }

    static func observationStop(error: any Error, stage: BpyLaunchStage?) -> BpyMemoryStop {
        if let stage, stage.rawValue >= 80 { return .launchFailed }
        if let code = (error as? POSIXError)?.code {
            if code == .EPERM { return .ownershipViolation }
            if code == .EBUSY { return .orphanedWorker }
            if code == .EOVERFLOW { return .processCount }
            if code == .EPIPE { return .launchFailed }
        }
        return .observationFailed
    }

    private func observe(_ launch: Launch) throws {
        let snapshot = launch.lock.withLock { (launch.process, launch.supervisor, launch.childPID, launch.worker, launch.childReleased, launch.stage) }
        guard let process = snapshot.0 else { return }
        let mayAuthorize = try BpyLaunchLifecycle.poll(hasProcess: true, isRunning: { try process.isRunning },
            reap: {
                let termination = try process.waitForTermination(timeout: 0)
                launch.lock.withLock { launch.termination = termination }
            }, hasSupervisor: { launch.lock.withLock { launch.supervisor != nil } },
            spawnFinished: { launch.lock.withLock { launch.spawnFinished } },
            stopped: { launch.lock.withLock { launch.stop != nil } },
            failure: { launch.lock.withLock {
                if let stage = launch.stage, stage.rawValue >= 80 { return .launchFailed }
                if launch.streams.errorCode != 0 { return .observationFailed }
                return nil
            } }, reportEOF: { launch.lock.withLock { launch.streams.report == .eof } }, workerEnded: launch.workerHasEnded,
            stop: { reason in
                let recorded = (try? memory.receipt(launch.spec.permit).stop) ?? reason
                launch.requestStop(recorded); memory.cancel(launch.spec.permit, reason: recorded)
            },
            finish: {
                if launch.lock.withLock({ launch.childReleased }) { memory.childExited(launch.spec.permit) }
                memory.launchEnded(launch.spec.permit)
                if launch.lock.withLock({ launch.stop != nil }) { memory.finish(launch.spec.permit) }
                launch.lock.withLock { launch.workerEnded = true }
                launch.releaseConfiguration()
                publish(nil, execution: launch.request.execution)
            })
        guard mayAuthorize else { return }
        guard launch.lock.withLock({ launch.stop == nil }), try memory.receipt(launch.spec.permit).stop == nil else { return }
        guard let supervisor = launch.lock.withLock({ launch.supervisor }) else { return }
        if !launch.lock.withLock({ launch.released }),
           launch.binding.identity.kind != .job || lock.withLock({ authorizedPermits.contains(launch.spec.permit) }) {
            _ = try authorize(execution: launch.request.execution, pid: supervisor.pid, start: supervisor.start)
        }
        guard launch.lock.withLock({ launch.stop == nil }), try memory.receipt(launch.spec.permit).stop == nil else { return }
        if let stage = snapshot.5, stage.rawValue >= 80 { throw POSIXError(.EIO) }
        if !snapshot.4, let pid = snapshot.2 {
            guard let child = try BpyKernelInspection.process(pid), child.parent == supervisor.pid,
                  child.executable == supervisor.executable else { throw POSIXError(.EPERM) }
            guard let observation = launch.lock.withLock({ launch.observation }) else { throw POSIXError(.EIO) }
            try observation.captureChild(child)
            try launch.binding.workerVolume.bindLaunch(supervisor: supervisor, worker: child)
            try launch.binding.dataVolume.bindLaunch(supervisor: supervisor, worker: child)
            launch.lock.withLock { launch.worker = child }
            let childKind: BpyMemoryState.Child
            switch launch.spec.mode {
            case .probe: childKind = .probe
            case .job: childKind = .worker
            case .verify: childKind = .verifier
            case .autoexecPositive: childKind = .autoexec
            case .boundary: childKind = .boundary
            }
            _ = try memory.releaseChild(launch.spec.permit, child: childKind) {
                try BpyLaunchGateRelease.write(lock: launch.lock, stopped: { launch.stop != nil },
                    writing: { try launch.childGate.release() }, released: { launch.childReleased = true })
            }
        }
        guard let observation = launch.lock.withLock({ launch.observation }) else { throw POSIXError(.EIO) }
        let sample = try observation.sample()
        let worker = sample.worker
        if let worker { launch.lock.withLock { launch.worker = worker } }
        if let mode = launch.spec.boundary, mode.isHostDiagnostic, let worker,
           let stage = launch.lock.withLock({ launch.stage }),
           [.diagnosticReady, .diagnosticExecReady, .virtualMappingSucceeded].contains(stage) {
            let baseline = launch.lock.withLock { launch.diagnosticBaseline }
            if baseline == nil {
                guard stage == (mode == .diagnosticFootprintAfterExec ? .diagnosticExecReady : .diagnosticReady) else {
                    throw POSIXError(.EPERM)
                }
                let receipt = try memory.receipt(launch.spec.permit)
                guard let first = receipt.firstRelease else { throw POSIXError(.EIO) }
                let probe: BpyFootprintProbe?
                if mode.isFootprintDiagnostic { probe = try BpyFootprintProbe(baseline: worker, deadline: first + receipt.identity.runningTimeout) }
                else { probe = nil }
                launch.lock.withLock { launch.diagnosticBaseline = worker; launch.footprintProbe = probe }
                if mode == .diagnosticStdoutBurst {
                    try launch.pauseOutput()
                    watcher.asyncAfter(deadline: .now() + .milliseconds(250)) { launch.resumeOutput() }
                }
                try launch.diagnosticGate.release()
            } else if mode.isFootprintDiagnostic {
                let snapshot = launch.lock.withLock { (launch.footprintProbe, launch.diagnosticChunks.last ?? 0, launch.diagnosticCapReached) }
                guard let probe = snapshot.0 else { throw POSIXError(.EIO) }
                switch probe.observe(worker, requested: snapshot.1, capReached: snapshot.2, at: try BpyRuntimeClock.awakeSeconds()) {
                case .continuing: break
                case .proven:
                    launch.lock.withLock { launch.diagnosticObserved = worker }
                    memory.cancel(launch.spec.permit, reason: .diagnosticMemory)
                case .unsafe: memory.cancel(launch.spec.permit, reason: .diagnosticSafety)
                }
            }
        }
        let now = try BpyRuntimeClock.awakeSeconds()
        if let clock = BpyRuntimeClock.read() {
            BpyRuntimeObservation.shared.processes(supervisor: sample.supervisor, worker: worker, service: launch.service, clock: clock)
        }
        let response = BpyMonitorResponse(status: .observed, request: launch.request, epoch: launch.epoch,
            service: launch.service, supervisor: sample.supervisor, descendants: sample.descendants, worker: worker, vnodes: sample.vnodes)
        launch.lock.withLock { launch.snapshot = response; launch.snapshotAt = now }
    }

    private func response(_ request: BpyMonitorRequest, launch: Launch,
                          status: BpyMonitorResponse.Status? = nil) throws -> BpyMonitorResponse {
        if let error = launch.lock.withLock({ launch.launchError }) {
            return .init(status: .refused, request: request, epoch: launch.epoch, service: launch.service, errorCode: error)
        }
        let receipt = try memory.receipt(launch.spec.permit)
        return try launch.lock.withLock {
            guard request.outputOffset >= launch.logBase, request.outputOffset <= launch.logBase + UInt64(launch.log.count) else {
                throw POSIXError(.EINVAL)
            }
            let consumed = Int(request.outputOffset - launch.logBase)
            if consumed > 0 { launch.log.removeFirst(consumed); launch.logBase = request.outputOffset }
            let end = min(launch.log.count, 65_536)
            let snapshot = launch.snapshot
            let gone = launch.termination != nil && launch.workerEnded
            return BpyMonitorResponse(status: status ?? (gone ? .gone : .observed), request: request, epoch: launch.epoch,
                service: launch.service, supervisor: gone ? nil : launch.supervisor,
                descendants: gone ? [] : snapshot?.descendants ?? [], worker: gone ? nil : snapshot?.worker,
                vnodes: gone ? [] : snapshot?.vnodes ?? [],
                ended: gone ? (launch.supervisor.map { [$0] } ?? []) + (launch.worker.map { [$0] } ?? []) : [],
                errorCode: launch.streams.errorCode,
                exitStatus: launch.termination?.exitStatus, terminationSignal: launch.termination?.signal,
                stdout: Data(launch.log.prefix(end)), stage: launch.stage, firstRelease: receipt.firstRelease,
                terminalCommit: receipt.terminalCommit, stopReason: receipt.stop?.rawValue,
                nextOutputOffset: launch.logBase + UInt64(end), outputComplete: gone && launch.streams.terminal && end == launch.log.count,
                admissionDeadline: receipt.identity.admissionDeadline,
                runningDeadline: receipt.firstRelease.map { $0 + receipt.identity.runningTimeout },
                cleanupDeadline: receipt.cleanupStarted.map { $0 + BpyMemoryState.cleanupBudget },
                stopDeliveredAt: launch.stopDeliveredAt,
                diagnosticBaseline: launch.diagnosticBaseline, diagnosticObserved: launch.diagnosticObserved,
                diagnosticThresholdBytes: launch.spec.boundary?.isFootprintDiagnostic == true ? BpyFootprintProbe.delta : nil,
                diagnosticSafetyBytes: launch.footprintProbe?.safety, diagnosticChunks: launch.diagnosticChunks,
                diagnosticMapping: launch.diagnosticMapping, diagnosticAllocationObjectBytes: launch.diagnosticAllocationObjectBytes,
                diagnosticStdout: launch.stdoutCapture())
        }
    }

    func requestStop(permit: UUID? = nil, reason: BpyMemoryStop) {
        let active = lock.withLock { launches.values.filter { permit == nil || $0.spec.permit == permit } }
        for launch in active { launch.requestStop(reason) }
        finishUnstarted(permit: permit)
    }

    func beginRecovery(reason: BpyMemoryStop) {
        let permits = lock.withLock { Set(bindings.keys).union(launches.values.filter { !$0.reaped }.map(\.spec.permit)) }
        for permit in permits { memory.cancel(permit, reason: reason) }
        requestStop(reason: reason)
    }

    func cleanup(permit: UUID? = nil) {
        finishUnstarted(permit: permit)
        let active = lock.withLock { launches.values.filter { permit == nil || $0.spec.permit == permit } }
        for launch in active {
            if launch.reaped {
                if (try? memory.receipt(launch.spec.permit).stop) != nil {
                    memory.finish(launch.spec.permit)
                    pruneBinding(permit: launch.spec.permit)
                }
                continue
            }
            guard let process = launch.lock.withLock({ launch.process }), let now = BpyRuntimeClock.read()?.awake else { continue }
            guard let began = (try? memory.receipt(launch.spec.permit))?.cleanupStarted else { continue }
            let deadline = began + BpyMemoryState.cleanupBudget
            do {
                let termination = try process.waitForTermination(timeout: max(0, deadline - now))
                guard try launch.workerHasEnded() else { continue }
                if launch.lock.withLock({ launch.childReleased }) { memory.childExited(launch.spec.permit) }
                memory.launchEnded(launch.spec.permit)
                memory.finish(launch.spec.permit)
                launch.lock.withLock { launch.termination = termination; launch.workerEnded = true }
                launch.releaseConfiguration()
                publish(nil, execution: launch.request.execution)
            } catch { continue }
        }
        if permit == nil, recovered {
            let directory = BpyHostStaging.shared.location("canary-" + transport.uuidString)
            BpyStagingCleanup.shared.discard(directory.appendingPathComponent("outside-write")) {
                _ = rmdir(directory.path)
            }
        }
    }

    private func finishUnstarted(permit: UUID?) {
        let pending = lock.withLock { bindings.keys.filter { permit == nil || $0 == permit } }
        for id in pending {
            BpyLaunchLifecycle.finishUnstarted(permit: id, memory: memory) {
                lock.withLock {
                    guard bindings[id] != nil, !launches.values.contains(where: { $0.spec.permit == id }) else { return false }
                    stoppedPermits.insert(id)
                    bindings.removeValue(forKey: id)
                    return true
                }
            }
        }
    }

    var recovered: Bool { lock.withLock { launches.values.allSatisfy(\.reaped) } }

    private var isSelfTest: Bool {
        ["NGV_SELFTEST_BPY", "NGV_SELFTEST_BPY_BOUNDARY", "NGV_SELFTEST_BPY_HOST_CRASH"].contains {
            ProcessInfo.processInfo.environment[$0]?.isEmpty == false
        }
    }

    private func publish(_ process: BpyObservedProcess?, execution: UUID) {
        observationQueue.sync {
            if process == nil {
                guard observedExecution == execution else { return }
                observedExecution = nil
            } else { observedExecution = execution }
            observed(process)
        }
    }

    private func validate(_ spec: BpyHostLaunchSpec, identity: BpyAdmissionIdentity) throws {
        let prefix = transport.uuidString + "/"
        let jobPrefix = spec.job.map { prefix + "jobs/" + $0.uuidString + "/" }
        let expected: String
        switch spec.mode {
        case .probe:
            guard identity.kind == .probe, spec.job == nil else { throw POSIXError(.EPERM) }
            expected = prefix + "probe"
        case .boundary:
            guard identity.kind == .boundary, let boundary = spec.boundary else { throw POSIXError(.EPERM) }
            expected = prefix + "boundary/" + boundary.rawValue
        case .job, .verify, .autoexecPositive:
            guard identity.kind == .job, let jobPrefix else { throw POSIXError(.EPERM) }
            expected = jobPrefix + (spec.mode == .job ? "worker" : spec.mode == .verify ? "verification" : "autoexec-positive")
        }
        guard spec.workerRoot == expected, spec.readFiles.count <= 512, spec.workerReadFiles.count <= 256,
              Set(spec.readFiles).count == spec.readFiles.count, Set(spec.workerReadFiles).count == spec.workerReadFiles.count,
              spec.configurationSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              spec.configuration.hasPrefix(jobPrefix ?? prefix),
              spec.readFiles.allSatisfy({ $0.hasPrefix(jobPrefix ?? prefix) }),
              spec.workerReadFiles.allSatisfy({ $0.hasPrefix((jobPrefix ?? prefix) + "worker/outputs/") }),
              spec.mode != .job || spec.readFiles.contains((jobPrefix ?? prefix) + "source.py") else {
            throw POSIXError(.EPERM)
        }
    }

    private func open(_ name: String, relativeTo mount: Int32, device: UInt64,
                      directory: Bool, maximum: UInt64 = 4 * 1_024 * 1_024) throws -> Int32 {
        guard !name.hasPrefix("/"), !name.isEmpty, name.utf8.count <= 1_024,
              name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !name.utf8.contains(0) else { throw POSIXError(.EPERM) }
        let descriptor = openat(mount, name, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, UInt64(UInt32(bitPattern: status.st_dev)) == device,
              status.st_uid == getuid(), status.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || (status.st_nlink == 1 && status.st_size >= 0 && UInt64(status.st_size) <= maximum) else {
            Darwin.close(descriptor)
            throw POSIXError(.EPERM)
        }
        return descriptor
    }

    private func path(_ descriptor: Int32) throws -> String {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &bytes) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return String(cString: bytes)
    }

    private func digest(_ descriptor: Int32) throws -> String {
        var result = SHA256(), buffer = [UInt8](repeating: 0, count: 65_536)
        var offset: off_t = 0
        while true {
            let count = pread(descriptor, &buffer, buffer.count, offset)
            guard count >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            result.update(data: Data(buffer.prefix(count)))
            offset += off_t(count)
        }
        return result.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func captureConfiguration(_ descriptor: Int32, expectedSHA256: String) throws -> Data {
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_nlink == 1, before.st_size >= 0,
              UInt64(before.st_size) <= BpyHostConfiguration.maximumBytes else { throw POSIXError(.EINVAL) }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = pread(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == expectedSHA256, fstat(descriptor, &after) == 0,
              after.st_nlink == 1,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw POSIXError(.EPERM) }
        return data
    }

    private func retire(_ launch: Launch, response: BpyMonitorResponse) {
        let identity = launch.lock.withLock { (launch.supervisor, launch.replay, launch.released) }
        guard let supervisor = identity.0, let replay = identity.1,
              let record = try? BpyRetiredLaunch(spec: launch.spec, service: launch.service, supervisor: supervisor,
                  authorized: identity.2, replay: replay, response: response) else { return }
        let disposal = ProcessRelease()
        lock.withLock {
            guard launches[response.execution] === launch else { return }
            retired[response.execution] = record
            launches.removeValue(forKey: response.execution)
            launch.lock.withLock { disposal.process = launch.process; launch.process = nil }
        }
        retirement.async { disposal.process = nil }
        pruneBinding(permit: launch.spec.permit)
    }

    private func retireFailure(_ launch: Launch) {
        guard launch.reaped, let code = launch.lock.withLock({ launch.launchError }),
              launch.lock.withLock({ launch.streams.terminal }),
              let digest = try? BpyRetiredLaunch.digest(launch.spec) else { return }
        launch.retireIO()
        let disposal = ProcessRelease()
        lock.withLock {
            guard launches[launch.request.execution] === launch else { return }
            failed[launch.request.execution] = .init(specification: digest, service: launch.service, code: code, epoch: launch.epoch)
            launches.removeValue(forKey: launch.request.execution)
            launch.lock.withLock { disposal.process = launch.process; launch.process = nil }
        }
        retirement.async { disposal.process = nil }
        pruneBinding(permit: launch.spec.permit)
    }

    private func pruneBinding(permit: UUID) {
        let receipt = try? memory.receipt(permit)
        guard receipt == nil || receipt?.cleanupComplete == true else { return }
        lock.withLock {
            guard launches.values.filter({ $0.spec.permit == permit }).allSatisfy(\.reaped) else { return }
            bindings.removeValue(forKey: permit); authorizedPermits.remove(permit)
        }
    }

}
