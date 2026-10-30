import BpyRuntimeProtocol
import Darwin
import Foundation

nonisolated final class BpyRuntimeObservation: @unchecked Sendable {
    private struct Pressure: Codable, Sendable {
        let controller: UUID
        let sample: BpyMemoryCoordinator.Sample
    }
    private struct Lifecycle: Codable, Sendable {
        let controller: UUID
        let event: String
        let clock: BpyClockReading?
    }
    private struct Swap: Codable, Sendable {
        let clock: BpyClockReading
        let total: UInt64?
        let used: UInt64?
        let available: UInt64?
        let bytes: Int
        let error: Int32?
    }
    private struct Activity: Codable, Sendable {
        let id: UUID
        let parent: UUID?
        let scope: String
        let event: String
        let clock: BpyClockReading?
    }
    private struct Footprint: Codable, Sendable {
        let role: String
        let pid: Int32
        let start: UInt64
        var current: UInt64?
        var peak: UInt64
        var clock: BpyClockReading
        var error: Int32?
        var status = "live"
        var exitObserved: BpyClockReading? = nil
    }
    private struct Stop: Codable, Sendable {
        let controller: UUID
        let permit: UUID
        let reason: BpyMemoryStop
        let decision: BpyClockReading?
        let hasHandler: Bool
        let requestInvoked: BpyClockReading?
    }
    private struct ProcessCleanup: Codable, Sendable {
        let controller: UUID
        let permit: UUID
        let started: TimeInterval?
        let finished: TimeInterval?
        let complete: Bool
        let grounds: [BpyStopGround]
    }
    private struct Trace: Codable, Sendable {
        var pressure: [Pressure] = []
        var lifecycle: [Lifecycle] = []
        var swap: [Swap] = []
        var activity: [Activity] = []
        var footprints: [String: Footprint] = [:]
        var stops: [Stop] = []
        var processCleanup: [String: ProcessCleanup] = [:]
        var overflow = false
    }

    static let shared = BpyRuntimeObservation()
    private let enabled = ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false
    var isEnabled: Bool { enabled }
    private let queue = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.observation", qos: .utility)
    private var trace = Trace()
    private var lastSwap: TimeInterval?
    private var lastSystemObservation: [String: TimeInterval] = [:]

    func pressure(controller: UUID, sample: BpyMemoryCoordinator.Sample) {
        guard enabled else { return }
        queue.async { [self] in
            guard trace.pressure.count < 262_144 else { trace.overflow = true; return }
            trace.pressure.append(.init(controller: controller, sample: sample))
            if lastSwap.map({ sample.clock.awake - $0 >= 1 }) ?? true {
                lastSwap = sample.clock.awake
                if let swap = Self.readSwap() { trace.swap.append(swap) }
            }
        }
    }

    func lifecycle(controller: UUID, event: String) {
        guard enabled else { return }
        let reading = BpyRuntimeClock.read()
        queue.async { [self] in
            guard trace.lifecycle.count < 16_384 else { trace.overflow = true; return }
            trace.lifecycle.append(.init(controller: controller, event: event, clock: reading))
        }
    }

    func activity(id: UUID, parent: UUID?, scope: String, event: String) {
        guard enabled else { return }
        let clock = BpyRuntimeClock.read()
        queue.async { [self] in
            guard trace.activity.count < 16_384 else { trace.overflow = true; return }
            trace.activity.append(.init(id: id, parent: parent, scope: scope, event: event, clock: clock))
        }
    }

    func processes(supervisor: BpyObservedProcess?, worker: BpyObservedProcess?, service: BpyObservedProcess,
                   clock: BpyClockReading) {
        guard enabled else { return }
        queue.async { [self] in
            if let supervisor { record(supervisor, role: "supervisor", clock: clock) }
            if let worker { record(worker, role: "worker", clock: clock) }
            for (pid, expected, role) in [(getpid(), nil as UInt64?, "host"), (service.pid, Optional(service.start), "service")] {
                let key = role + ":" + String(pid)
                guard lastSystemObservation[key].map({ clock.awake - $0 >= 1 }) ?? true else { continue }
                lastSystemObservation[key] = clock.awake
                if let value = try? BpyKernelInspection.process(pid), expected == nil || value.start == expected,
                   let observed = BpyRuntimeClock.read() { record(value, role: role, clock: observed) }
            }
        }
    }

    func stop(controller: UUID, permit: UUID, reason: BpyMemoryStop, decision: BpyClockReading?, hasHandler: Bool) {
        guard enabled else { return }
        let invoked = hasHandler ? BpyRuntimeClock.read() : nil
        queue.async { [self] in
            guard trace.stops.count < 16_384 else { trace.overflow = true; return }
            trace.stops.append(.init(controller: controller, permit: permit, reason: reason, decision: decision,
                hasHandler: hasHandler, requestInvoked: invoked))
        }
    }

    func processCleanup(controller: UUID, receipt: BpyMemoryCoordinator.PermitReceipt) {
        guard enabled else { return }
        let proof = ProcessCleanup(controller: controller, permit: receipt.identity.id, started: receipt.cleanupStarted,
            finished: receipt.cleanupFinishedAt, complete: receipt.cleanupComplete, grounds: receipt.grounds)
        let key = receipt.identity.id.uuidString
        queue.async { [self] in
            guard trace.processCleanup[key] != nil || trace.processCleanup.count < 16_384 else { trace.overflow = true; return }
            trace.processCleanup[key] = proof
        }
    }

    private func record(_ process: BpyObservedProcess, role: String, clock: BpyClockReading) {
        let key = role + ":" + String(process.pid) + ":" + String(process.start)
        guard trace.footprints[key] != nil || trace.footprints.count < 16_384 else { trace.overflow = true; return }
        trace.footprints[key] = .init(role: role, pid: process.pid, start: process.start, current: process.footprint,
            peak: max(trace.footprints[key]?.peak ?? 0, process.footprint), clock: clock, error: nil)
    }

    func evidence() throws -> [String: Any] {
        guard enabled else { throw SpatialSceneError.changed }
        let value = queue.sync {
            for key in Array(trace.footprints.keys) {
                guard var value = trace.footprints[key], let clock = BpyRuntimeClock.read() else { continue }
                do {
                    let current = try BpyKernelInspection.process(value.pid)
                    if let current, current.start == value.start {
                        value.current = current.footprint
                        value.peak = max(value.peak, current.footprint)
                        value.clock = clock; value.status = "live"; value.exitObserved = nil
                    } else {
                        value.status = "exited"; value.exitObserved = clock
                    }
                } catch { value.error = Int32((error as NSError).code) }
                trace.footprints[key] = value
            }
            return trace
        }
        guard !value.overflow, !value.pressure.isEmpty, !value.swap.isEmpty, !value.activity.isEmpty else { throw SpatialSceneError.changed }
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
        guard let evidenceClock = BpyRuntimeClock.read() else { throw BpyAdmissionFailure.sensorUnavailable }
        var result: [String: Any] = ["schema": "nexgenvideo/bpy-runtime-observation/1",
            "osVersion": "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)",
            "osBuild": try Self.string("kern.osversion"), "kernel": try Self.string("kern.version"),
            "architecture": try Self.string("hw.machine"), "genuinePressureTransitionsProven": false,
            "evidenceClock": try JSONSerialization.jsonObject(with: JSONEncoder().encode(evidenceClock)),
            "trace": try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))]
        if let image = ProcessInfo.processInfo.environment["ImageVersion"], !image.isEmpty {
            result["imageVersionStatus"] = "present"; result["imageVersion"] = image
        } else { result["imageVersionStatus"] = "absent" }
        var maximumGap: TimeInterval = 0, sleepChange: TimeInterval = 0
        for (controller, samples) in Dictionary(grouping: value.pressure, by: \.controller) {
            let valid = samples.map(\.sample).filter { ["sysctl", "selftest-sensor"].contains($0.source) && $0.error == nil && $0.pressure != nil }
                .sorted { $0.clock.awake < $1.clock.awake }
            let lifecycle = value.lifecycle.filter { $0.controller == controller }.sorted { ($0.clock?.awake ?? 0) < ($1.clock?.awake ?? 0) }
            var began: BpyClockReading?
            for event in lifecycle {
                guard let clock = event.clock else { throw SpatialSceneError.changed }
                if event.event == "dispatch-source-resumed" { began = clock }
                else if event.event == "sampling-ended", let first = began {
                    let observations = [first] + valid.filter { $0.clock.awake >= first.awake && $0.clock.awake <= clock.awake }.map(\.clock) + [clock]
                    for (left, right) in zip(observations, observations.dropFirst()) {
                        maximumGap = max(maximumGap, right.awake - left.awake)
                        sleepChange = max(sleepChange, abs(right.sleepOffset - left.sleepOffset))
                    }
                    began = nil
                }
            }
            guard began == nil else { throw BpyRuntimeError.invalidOutput("Pressure observation outlived runtime shutdown.") }
        }
        result["maximumAwakeObservationGap"] = maximumGap
        result["maximumSleepOffsetChange"] = sleepChange
        result["observerWatchdogExpiryCount"] = value.stops.filter { $0.reason == .monitorUnresponsive }.count
        result["activitiesEnded"] = try Dictionary(grouping: value.activity, by: \.id).values.allSatisfy { events in
            guard events.count == 2, let begin = events.first, let end = events.last,
                  begin.event == "begin", end.event == "end", begin.scope == end.scope, begin.parent == end.parent,
                  let first = begin.clock, let last = end.clock, last.awake >= first.awake else {
                throw BpyRuntimeError.invalidOutput("A runtime activity did not finish before shutdown.")
            }
            return true
        }
        return result
    }

    private static func readSwap() -> Swap? {
        var value = xsw_usage(), bytes = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &value, &bytes, nil, 0)
        let failure = result == 0 ? nil : errno
        guard let clock = BpyRuntimeClock.read() else { return nil }
        let valid = result == 0 && bytes == MemoryLayout<xsw_usage>.size
        return .init(clock: clock, total: valid ? value.xsu_total : nil, used: valid ? value.xsu_used : nil,
            available: valid ? value.xsu_avail : nil, bytes: bytes, error: failure ?? (valid ? nil : EPROTO))
    }

    private static func string(_ name: String) throws -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, (1...32_768).contains(size) else { throw POSIXError(.EIO) }
        var buffer = [CChar](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes { sysctlbyname(name, $0.baseAddress, &size, nil, 0) }
        guard status == 0, size > 0, size <= buffer.count, buffer[size - 1] == 0,
              let value = buffer.withUnsafeBufferPointer({ String(validatingCString: $0.baseAddress!) }), !value.isEmpty else {
            throw POSIXError(.EIO)
        }
        return value
    }
}
