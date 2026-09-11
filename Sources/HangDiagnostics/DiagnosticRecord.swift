import CryptoKit
import Darwin
import Foundation
import Synchronization

public enum DiagnosticOperation: String, Codable, Sendable {
    case startup, heartbeat, runLoop, context, scroll, window
    case runtimeReceive, runtimeApply, apiReceive, apiApply
    case projection, markdown, imageDecode, pipelineRefresh, replaySnapshot
    case recovered, stopped, captureFailure, dropped, testWait, testSpin
}

public struct DiagnosticRecord: Codable, Sendable {
    public let sequence: UInt64
    public let uptime: Double
    public let operation: DiagnosticOperation
    public let correlation: UInt64
    public let end: Bool
    public let values: [Double]
    public let hadNonFiniteValues: Bool

    public init(sequence: UInt64, uptime: Double, operation: DiagnosticOperation,
                correlation: UInt64 = 0, end: Bool = false, values: [Double] = []) {
        self.sequence = sequence
        self.uptime = uptime
        self.operation = operation
        self.correlation = correlation
        self.end = end
        self.hadNonFiniteValues = values.contains { !$0.isFinite }
        self.values = Array(values.prefix(12)).map { $0.isFinite ? $0 : 0 }
    }
}

public final class DiagnosticRing: @unchecked Sendable {
    private let lock = NSLock()
    private let counter = Atomic<UInt64>(0)
    private let losses = Atomic<UInt64>(0)
    private var slots: [DiagnosticRecord?]
    private var readIndex = 0
    private var count = 0

    public init(capacity: Int = 8192) {
        precondition(capacity > 0)
        slots = Array(repeating: nil, count: capacity)
    }

    public var dropped: UInt64 { losses.load(ordering: .relaxed) }

    @discardableResult
    public func append(_ operation: DiagnosticOperation, correlation: UInt64 = 0,
                       end: Bool = false, values: [Double] = []) -> UInt64 {
        guard lock.try() else {
            losses.wrappingAdd(1, ordering: .relaxed)
            return 0
        }
        defer { lock.unlock() }
        let id = counter.wrappingAdd(1, ordering: .relaxed).newValue
        guard count < slots.count else {
            losses.wrappingAdd(1, ordering: .relaxed)
            return id
        }
        slots[(readIndex + count) % slots.count] = DiagnosticRecord(
            sequence: id, uptime: ProcessInfo.processInfo.systemUptime,
            operation: operation, correlation: correlation, end: end, values: values
        )
        count += 1
        return id
    }

    public func drain() -> [DiagnosticRecord] {
        lock.lock()
        defer { lock.unlock() }
        var result: [DiagnosticRecord] = []
        result.reserveCapacity(count)
        while count > 0 {
            if let item = slots[readIndex] { result.append(item) }
            slots[readIndex] = nil
            readIndex = (readIndex + 1) % slots.count
            count -= 1
        }
        return result
    }
}

public struct DiagnosticHeartbeat: Codable, Sendable {
    public let startupID: UUID
    public let processID: Int32
    public let writerUptime: Double
    public let mainUptime: Double
    public let runLoopUptime: Double
    public let dropped: UInt64
    public let stopped: Bool

    public init(startupID: UUID, processID: Int32, writerUptime: Double,
                mainUptime: Double, runLoopUptime: Double, dropped: UInt64, stopped: Bool) {
        self.startupID = startupID
        self.processID = processID
        self.writerUptime = writerUptime
        self.mainUptime = mainUptime
        self.runLoopUptime = runLoopUptime
        self.dropped = dropped
        self.stopped = stopped
    }
}

public struct DiagnosticHangState: Sendable {
    public enum Action: Equatable, Sendable {
        case pin, sample(Int), recovered, suspended
    }
    private var lastTick: Double?
    private var pinned = false
    private var samples = 0
    private var baseline: Double = 0

    public init() {}

    public mutating func tick(now: Double, mainUptime: Double) -> Action? {
        defer { lastTick = now }
        if let lastTick, now - lastTick > 3.5 {
            baseline = now
            pinned = false
            samples = 0
            return .suspended
        }
        let age = now - max(mainUptime, baseline)
        if age < 2 {
            defer { pinned = false; samples = 0 }
            return pinned ? .recovered : nil
        }
        if !pinned { pinned = true; return .pin }
        if samples == 0 && age >= 5 { samples = 1; return .sample(1) }
        if samples == 1 && age >= 15 { samples = 2; return .sample(2) }
        return nil
    }
}

public struct DiagnosticHelperRecovery: Sendable {
    public enum Action: Equatable, Sendable {
        case restart(Int)
        case backoff(until: Double)
    }

    private let retryLimit: Int
    private let retryWindow: Double
    private var exits: [Double] = []
    private var retryAfter: Double?

    public init(retryLimit: Int = 3, retryWindow: Double = 60) {
        precondition(retryLimit > 0 && retryWindow > 0)
        self.retryLimit = retryLimit
        self.retryWindow = retryWindow
    }

    public mutating func helperExited(now: Double, stopping: Bool) -> Action? {
        guard !stopping else { return nil }
        if let retryAfter {
            guard now >= retryAfter else { return nil }
            exits.removeAll()
            self.retryAfter = nil
        }
        exits.removeAll { now - $0 >= retryWindow }
        guard exits.count < retryLimit else {
            let retryAfter = (exits.first ?? now) + retryWindow
            self.retryAfter = retryAfter
            return .backoff(until: retryAfter)
        }
        exits.append(now)
        return .restart(exits.count)
    }
}

public enum DiagnosticFiles {
    public static func copyRecording(from source: URL, to destination: URL) throws {
        let began = ProcessInfo.processInfo.systemUptime
        guard source.resolvingSymlinksInPath().path == source.standardizedFileURL.path else {
            throw CocoaError(.fileReadNoPermission)
        }
        try directory(destination)
        guard let enumerator = FileManager.default.enumerator(at: source,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { throw CocoaError(.fileReadUnknown) }
        var digests: [String: String] = [:]
        var total = 0
        for case let file as URL in enumerator {
            let attributes = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard attributes.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
            guard attributes.isRegularFile == true else { continue }
            let rootComponents = source.standardizedFileURL.pathComponents
            let fileComponents = file.standardizedFileURL.pathComponents
            guard fileComponents.starts(with: rootComponents) else { throw CocoaError(.fileReadNoPermission) }
            let relative = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
            guard !relative.contains(".."), !relative.hasPrefix("/"),
                  isRecordingFile(relative) else { continue }
            let size = attributes.fileSize ?? 0
            guard size <= 40 * 1024 * 1024, total + size <= 1024 * 1024 * 1024,
                  digests.count < 8192 else { throw CocoaError(.fileReadTooLarge) }
            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            let target = destination.appendingPathComponent(relative)
            try directory(target.deletingLastPathComponent())
            try write(bytes, to: target)
            digests[relative] = digest(bytes)
            total += bytes.count
        }
        try replace(digests, at: destination.appendingPathComponent("checksums.json"))
        try replace([
            "schema": "hang-export/1", "bytes": String(total),
            "exportBeganUptime": String(began),
            "exportCompletedUptime": String(ProcessInfo.processInfo.systemUptime),
            "completeness": "Check heartbeat losses, capture-error, helper-error and requested versus completed stack files.",
            "replayScope": "UI state and displayed transcript images; library media bytes and pipeline artifact bytes are not copied. Pack binaries are not embedded. Geometry is recorded, not restored by replay.",
        ], at: destination.appendingPathComponent("export.json"))
    }

    private static func isRecordingFile(_ relative: String) -> Bool {
        if ["build.json", "heartbeat.json", "pinned.json", "sample-request.json", "capture-error.json", "helper-error.json", "self-capture-error.json"].contains(relative) { return true }
        let patterns = [#"^events-[0-9]{12}\.json$"#, #"^replay-[0-9]{12}\.enc$"#,
                        #"^self-[A-Fa-f0-9-]{36}-[0-2]\.stacks$"#,
                        #"^incident-[A-Fa-f0-9-]{36}/incident\.json$"#]
        return patterns.contains { relative.range(of: $0, options: .regularExpression) != nil }
    }

    public static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func write(_ data: Data, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try atomic(data, at: url)
    }

    public static func replace<T: Encodable>(_ value: T, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try atomic(encoder.encode(value), at: url)
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func atomic(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

public struct DiagnosticReplayDelta: Codable, Sendable {
    public let sequence: UInt64
    public let uptime: Double
    public let predecessor: String?
    public let digest: String
    public let prefix: Int
    public let suffix: Int
    public let inserted: Data

    public init(sequence: UInt64, previous: Data?, current: Data) {
        self.sequence = sequence
        uptime = ProcessInfo.processInfo.systemUptime
        predecessor = previous.map(DiagnosticFiles.digest)
        digest = DiagnosticFiles.digest(current)
        let old = previous ?? Data()
        var prefix = 0
        var suffix = 0
        while prefix < min(old.count, current.count), old[prefix] == current[prefix] { prefix += 1 }
        while suffix < min(old.count, current.count) - prefix,
              old[old.count - suffix - 1] == current[current.count - suffix - 1] { suffix += 1 }
        self.prefix = prefix
        self.suffix = suffix
        inserted = current.subdata(in: prefix..<(current.count - suffix))
    }

    public func apply(to previous: Data?) throws -> Data {
        let old = previous ?? Data()
        guard predecessor == previous.map(DiagnosticFiles.digest), prefix >= 0, suffix >= 0,
              prefix <= old.count, suffix <= old.count - prefix else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let output = old.prefix(prefix) + inserted + old.suffix(suffix)
        guard DiagnosticFiles.digest(output) == digest else { throw CocoaError(.fileReadCorruptFile) }
        return output
    }
}
