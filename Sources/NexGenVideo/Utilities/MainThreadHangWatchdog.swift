import Dispatch
import Foundation

struct MainThreadHangContext: Codable, Equatable, Sendable {
    let surface: String
    let phase: String?
    let stage: String?
    let isStreaming: Bool
    let hasDialog: Bool
    let hasGateApproval: Bool
    let hasSpendApproval: Bool

    static let application = MainThreadHangContext(
        surface: "application",
        phase: nil,
        stage: nil,
        isStreaming: false,
        hasDialog: false,
        hasGateApproval: false,
        hasSpendApproval: false
    )
}

struct MainThreadHangProbeState {
    enum Action: Equatable {
        case ping(UInt64)
        case capture(stallSeconds: TimeInterval)
    }

    private struct Probe {
        let id: UInt64
        let issuedAt: TimeInterval
    }

    let stallThreshold: TimeInterval
    let monitorSuspensionThreshold: TimeInterval

    private var nextProbeID: UInt64 = 0
    private var pendingProbe: Probe?
    private var didReportPendingProbe = false
    private var lastMonitorTick: TimeInterval?

    init(
        stallThreshold: TimeInterval,
        monitorSuspensionThreshold: TimeInterval
    ) {
        self.stallThreshold = stallThreshold
        self.monitorSuspensionThreshold = monitorSuspensionThreshold
    }

    mutating func tick(at now: TimeInterval) -> Action? {
        defer { lastMonitorTick = now }

        if let lastMonitorTick,
           now - lastMonitorTick > monitorSuspensionThreshold {
            if !didReportPendingProbe {
                pendingProbe = nil
            }
        }

        if let pendingProbe {
            guard now - pendingProbe.issuedAt >= stallThreshold,
                  !didReportPendingProbe
            else { return nil }
            didReportPendingProbe = true
            return .capture(stallSeconds: now - pendingProbe.issuedAt)
        }

        nextProbeID &+= 1
        pendingProbe = Probe(id: nextProbeID, issuedAt: now)
        didReportPendingProbe = false
        return .ping(nextProbeID)
    }

    mutating func acknowledge(_ probeID: UInt64) {
        guard let pendingProbe, probeID >= pendingProbe.id else { return }
        self.pendingProbe = nil
        didReportPendingProbe = false
    }
}

final class MainThreadHangWatchdog: @unchecked Sendable {
    static let shared = MainThreadHangWatchdog()

    static let diagnosticsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NexGenVideo", isDirectory: true)

    private struct ContextRecord: Codable, Sendable {
        let recordedAt: Date
        let context: MainThreadHangContext
    }

    private struct Report: Codable, Sendable {
        let schemaVersion: Int
        let detectedAt: Date
        let appVersion: String
        let appBuild: String
        let operatingSystem: String
        let processID: Int32
        let stallSeconds: TimeInterval
        let sampleFilenameIfAvailable: String
        var sampleStatus: String
        let recentContexts: [ContextRecord]
    }

    private struct CaptureSnapshot: Sendable {
        let stallSeconds: TimeInterval
        let contexts: [ContextRecord]
    }

    private static let tickInterval: TimeInterval = 1
    static let stallThreshold: TimeInterval = 8
    private static let monitorSuspensionThreshold: TimeInterval = 3.5
    private static let sampleDurationSeconds = 3
    private static let sampleTimeoutSeconds: TimeInterval = 8
    private static let maximumContextRecords = 32

    private let monitorQueue = DispatchQueue(
        label: "de.h5ventures.nexgenvideo.hang-watchdog",
        qos: .utility
    )
    private let captureQueue = DispatchQueue(
        label: "de.h5ventures.nexgenvideo.hang-capture",
        qos: .utility
    )

    @MainActor
    private var started = false
    @MainActor
    private var timer: (any DispatchSourceTimer)?
    private var probeState = MainThreadHangProbeState(
        stallThreshold: MainThreadHangWatchdog.stallThreshold,
        monitorSuspensionThreshold: MainThreadHangWatchdog.monitorSuspensionThreshold
    )
    private var contextRecords: [ContextRecord] = [
        ContextRecord(recordedAt: Date(), context: .application),
    ]

    private init() {}

    @MainActor
    func start() {
        guard !started else { return }
        started = true

        try? FileManager.default.createDirectory(
            at: Self.diagnosticsDirectory,
            withIntermediateDirectories: true
        )

        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(
            deadline: .now() + Self.tickInterval,
            repeating: Self.tickInterval,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            self?.monitorTick()
        }
        self.timer = timer
        timer.resume()
        Log.hang.notice("main-thread watchdog started")
    }

    func update(context: MainThreadHangContext) {
        monitorQueue.async { [weak self] in
            guard let self,
                  self.contextRecords.last?.context != context
            else { return }
            self.contextRecords.append(
                ContextRecord(recordedAt: Date(), context: context)
            )
            if self.contextRecords.count > Self.maximumContextRecords {
                self.contextRecords.removeFirst(
                    self.contextRecords.count - Self.maximumContextRecords
                )
            }
        }
    }

    func resetContext() {
        update(context: .application)
    }

    private func monitorTick() {
        let now = ProcessInfo.processInfo.systemUptime
        let action = probeState.tick(at: now)

        switch action {
        case .ping(let probeID):
            DispatchQueue.main.async { [weak self] in
                self?.acknowledge(probeID)
            }
        case .capture(let stallSeconds):
            let snapshot = CaptureSnapshot(
                stallSeconds: stallSeconds,
                contexts: contextRecords
            )
            captureQueue.async { [weak self] in
                self?.capture(snapshot)
            }
        case nil:
            break
        }
    }

    private func acknowledge(_ probeID: UInt64) {
        monitorQueue.async { [weak self] in
            self?.probeState.acknowledge(probeID)
        }
    }

    private func capture(_ snapshot: CaptureSnapshot) {
        let timestamp = Self.filenameTimestamp(Date())
        let stem = "NexGenVideo-\(timestamp)-main-thread-hang"
        let sampleURL = Self.diagnosticsDirectory
            .appendingPathComponent("\(stem).sample.txt")
        let reportURL = Self.diagnosticsDirectory
            .appendingPathComponent("\(stem).json")
        let info = ProcessInfo.processInfo
        var report = Report(
            schemaVersion: 1,
            detectedAt: Date(),
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "?",
            appBuild: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "?",
            operatingSystem: info.operatingSystemVersionString,
            processID: info.processIdentifier,
            stallSeconds: snapshot.stallSeconds,
            sampleFilenameIfAvailable: sampleURL.lastPathComponent,
            sampleStatus: "pending",
            recentContexts: snapshot.contexts
        )

        do {
            try write(report, to: reportURL)
            Log.hang.notice(
                "main thread unresponsive; report=\(reportURL.lastPathComponent)"
            )
        } catch {
            Log.hang.notice(
                "hang report write failed: \(Log.detail(error))"
            )
        }

        report.sampleStatus = captureProcessSample(to: sampleURL)
        do {
            try write(report, to: reportURL)
        } catch {
            Log.hang.notice(
                "hang report status update failed: \(Log.detail(error))"
            )
        }
    }

    private func captureProcessSample(to url: URL) -> String {
        let process = Process()
        let completed = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            String(Self.sampleDurationSeconds),
            "-mayDie",
            "-file",
            url.path,
        ]
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
            guard completed.wait(
                timeout: .now() + Self.sampleTimeoutSeconds
            ) == .success else {
                process.terminate()
                _ = completed.wait(timeout: .now() + 1)
                Log.hang.notice("main-thread sample timed out")
                return "timedOut"
            }
            guard process.terminationStatus == 0 else {
                Log.hang.notice(
                    "main-thread sample exited with status \(process.terminationStatus)"
                )
                return "failed(\(process.terminationStatus))"
            }
            Log.hang.notice(
                "main-thread sample written file=\(url.lastPathComponent)"
            )
            return "completed"
        } catch {
            Log.hang.notice(
                "main-thread sample failed: \(Log.detail(error))"
            )
            return "failed"
        }
    }

    private func write(_ report: Report, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: Self.diagnosticsDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "")
    }
}
