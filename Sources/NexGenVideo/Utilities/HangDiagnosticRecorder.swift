import AppKit
import CryptoKit
import Foundation
import HangDiagnostics
import HangStackSampler
import Synchronization

private struct DiagnosticCaptureIssue: Codable {
    let uptime: Double
    let code: String
    let detail: String?
}

final class HangDiagnosticRecorder: @unchecked Sendable {
    static let shared = HangDiagnosticRecorder()
    static let root = MainThreadHangWatchdog.diagnosticsDirectory
        .appendingPathComponent("HangIncidents", isDirectory: true)
        .resolvingSymlinksInPath()
    private let enabled = Atomic<Bool>(false)
    private let mainPulse = Atomic<UInt64>(0)
    private let loopPulse = Atomic<UInt64>(0)
    private let stopping = Atomic<Bool>(false)
    private let startRequested = Atomic<Bool>(false)
    private let ring = DiagnosticRing()
    private let writer = DispatchQueue(label: "de.h5ventures.nexgenvideo.diagnostic-writer", qos: .utility)
    private let pulseQueue = DispatchQueue(label: "de.h5ventures.nexgenvideo.diagnostic-heartbeat", qos: .utility)
    private let snapshotSlots = DispatchSemaphore(value: 2)
    private let samplerLifetime = DispatchGroup()
    private let snapshotLosses = Atomic<UInt64>(0)
    private var session: URL?
    private var startupID = UUID()
    private var timer: DispatchSourceTimer?
    private var pulseTimer: DispatchSourceTimer?
    private var helper: Process?
    private var segment: UInt64 = 0
    private var files: [(URL, Int, Double)] = []
    private var journalBytes = 0
    private var contentBytes = 0
    private var key: SymmetricKey?
    private var previousSnapshot: HangDiagnosticTranscript?
    private var previousFrameDigest: String?
    private var snapshotOrdinal: UInt64 = 0
    private var replayEpochs: [(began: Double, files: [(URL, Int)])] = []
    private let contentEnabled = Atomic<Bool>(false)
    private var notifiedIncidents: Set<String> = []
    @MainActor private var observer: CFRunLoopObserver?
    @MainActor private var mainTimer: Timer?
    private var captureIssues: [DiagnosticCaptureIssue] = []
    private var helperRecovery = DiagnosticHelperRecovery()

    init() {}

    var isEnabled: Bool { enabled.load(ordering: .relaxed) }
    var recordsContent: Bool { isEnabled && contentEnabled.load(ordering: .relaxed) }

    @discardableResult
    func record(_ operation: DiagnosticOperation, correlation: UInt64 = 0,
                end: Bool = false, values: [Double] = []) -> UInt64 {
        guard isEnabled else { return 0 }
        return ring.append(operation, correlation: correlation, end: end, values: values)
    }

    @MainActor
    func configure() {
        if startRequested.load(ordering: .relaxed) {
            let alert = NSAlert()
            alert.messageText = "Restart to change recording mode"
            alert.informativeText = "Stop recording now, then restart NexGenVideo to choose a different mode. Existing recordings are kept."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Stop recording")
            if alert.runModal() == .alertSecondButtonReturn {
                stop()
                UserDefaults.standard.removeObject(forKey: "hangDiagnosticMode")
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Record UI hang diagnostics"
        alert.informativeText = "Diagnostics stay on this Mac until you export them. Structural recording includes UI timing and thread stacks. Replay recording also includes displayed chat text and images, encrypted on disk. Hang recordings, replay content and exported recordings are kept until you delete them. New recording stops when stored diagnostics reach 1 GB."
        alert.addButton(withTitle: "Record with replay content")
        alert.addButton(withTitle: "Record structure only")
        alert.addButton(withTitle: "Disable recording")
        let result = alert.runModal()
        UserDefaults.standard.set(result == .alertFirstButtonReturn ? "replay"
            : result == .alertSecondButtonReturn ? "structure" : "disabled", forKey: "hangDiagnosticMode")
        if result == .alertThirdButtonReturn {
            stop()
            return
        }
        start(includeContent: result == .alertFirstButtonReturn)
    }

    @MainActor
    func start(includeContent: Bool) {
        guard !startRequested.exchange(true, ordering: .relaxed) else { return }
        ngv_sampler_initialize()
        let id = UUID()
        let contentKey = includeContent ? SymmetricKey(size: .bits256) : nil
        if let contentKey {
            let encoded = contentKey.withUnsafeBytes { Data($0) }.base64EncodedString()
            KeychainStore.save(encoded, account: "hang-diagnostic-\(id.uuidString)")
            guard KeychainStore.load(account: "hang-diagnostic-\(id.uuidString)") == encoded else {
                KeychainStore.delete(account: "hang-diagnostic-\(id.uuidString)")
                startRequested.store(false, ordering: .relaxed)
                Self.showFailure("Cannot protect replay content in Keychain. Recording was not started.")
                return
            }
            if HangDiagnosticSelfTest.requested,
               let output = ProcessInfo.processInfo.environment["NGV_HANG_SELFTEST_KEY"] {
                try? DiagnosticFiles.write(Data(encoded.utf8), to: URL(fileURLWithPath: output))
            }
        }
        let metadata = [
            "schema": "1", "startupID": id.uuidString,
            "version": AppVersion.marketing ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "commit": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? "unknown",
            "configuration": Bundle.main.object(forInfoDictionaryKey: "NGVBuildConfiguration") as? String ?? "unknown",
            "sdk": Bundle.main.object(forInfoDictionaryKey: "NGVBuildSDK") as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "mode": includeContent ? "encrypted-replay" : "structure",
        ]
        let folder = Self.root.appendingPathComponent(id.uuidString, isDirectory: true)
        let now = DispatchTime.now().uptimeNanoseconds
        mainPulse.store(now, ordering: .relaxed)
        loopPulse.store(now, ordering: .relaxed)
        stopping.store(false, ordering: .relaxed)
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue
            | CFRunLoopActivity.afterWaiting.rawValue, true, 0) { [weak self] _, _ in
            self?.loopPulse.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
        }
        if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        let mainTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mainPulse.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
                for window in NSApp.windows where window.isVisible {
                    self.record(.window, values: [Double(window.windowNumber), window.frame.width,
                        window.frame.height, window.backingScaleFactor, NSApp.modalWindow == nil ? 0 : 1,
                        window.isKeyWindow ? 1 : 0, window.firstResponder is NSTextView ? 1 : 0])
                }
            }
        }
        self.mainTimer = mainTimer
        RunLoop.main.add(mainTimer, forMode: .common)
        writer.async { [self] in
            guard !stopping.load(ordering: .relaxed) else {
                KeychainStore.delete(account: "hang-diagnostic-\(id.uuidString)")
                return
            }
            do {
                try DiagnosticFiles.directory(Self.root)
                try Self.prune(excluding: id)
                try DiagnosticRetention.checkStorageBudget(at: Self.root)
                try DiagnosticFiles.directory(folder)
                try DiagnosticFiles.replace(metadata, at: folder.appendingPathComponent("build.json"))
                startupID = id
                session = folder
                key = contentKey
                captureIssues.removeAll()
                helperRecovery = DiagnosticHelperRecovery()
                contentEnabled.store(includeContent, ordering: .relaxed)
                try launchHelper(folder: folder, id: id)
                enabled.store(true, ordering: .relaxed)
                let timer = DispatchSource.makeTimerSource(queue: writer)
                timer.schedule(deadline: .now(), repeating: .milliseconds(500))
                timer.setEventHandler { [weak self] in self?.flush() }
                self.timer = timer
                timer.resume()
                startHeartbeat(folder: folder, id: id)
                startSampler(folder: folder)
            } catch {
                recordIssue("setup-failed", detail: Self.errorCode(error))
                if let session {
                    try? DiagnosticFiles.replace(captureIssues, at: session.appendingPathComponent("capture-error.json"))
                }
                enabled.store(false, ordering: .relaxed)
                contentEnabled.store(false, ordering: .relaxed)
                stopping.store(true, ordering: .relaxed)
                startRequested.store(false, ordering: .relaxed)
                let message = (error as? CocoaError)?.code == .fileWriteOutOfSpace
                    ? "Stored diagnostics reached 1 GB. Existing recordings and keys are preserved. Export and delete recordings from Help before starting a new recording."
                    : "Diagnostic recording could not start. Existing recordings and keys are preserved."
                DispatchQueue.main.async { [self] in finishFailedStart(message) }
            }
        }
    }

    @MainActor
    private func finishFailedStart(_ message: String) {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        mainTimer?.invalidate()
        mainTimer = nil
        if !HangDiagnosticSelfTest.requested { Self.showFailure(message) }
    }

    @MainActor
    func stop() {
        enabled.store(false, ordering: .relaxed)
        stopping.store(true, ordering: .relaxed)
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        mainTimer?.invalidate()
        mainTimer = nil
        writer.async { [self] in
            flush()
            timer?.cancel()
            timer = nil
        }
        pulseQueue.async { [self] in
            pulseTimer?.cancel()
            pulseTimer = nil
        }
        writer.async { [self] in
            if helper?.isRunning == true { helper?.terminate() }
        }
    }

    func terminateHelperForSelfTest() {
        guard ProcessInfo.processInfo.environment["NGV_HANG_SELFTEST"] == "helper-restart" else { return }
        writer.async { [self] in
            if helper?.isRunning == true { helper?.terminate() }
        }
    }

    private func flush() {
        guard let session else { return }
        let now = ProcessInfo.processInfo.systemUptime
        do {
            let records = ring.drain()
            if !records.isEmpty {
                let bytes = try JSONEncoder().encode(records)
                if journalBytes + bytes.count <= 32 * 1024 * 1024 {
                    let file = session.appendingPathComponent(String(format: "events-%012llu.json", segment))
                    segment &+= 1
                    try DiagnosticFiles.write(bytes, to: file)
                    files.append((file, bytes.count, now))
                    journalBytes += bytes.count
                } else { recordIssue("journal-limit") }
            }
            if !FileManager.default.fileExists(atPath: session.appendingPathComponent("pinned.json").path) {
                while let first = files.first, now - first.2 > 120 {
                    try FileManager.default.removeItem(at: first.0)
                    journalBytes -= first.1
                    files.removeFirst()
                }
            }
            if helper?.isRunning != true && !stopping.load(ordering: .relaxed) {
                recoverHelper(now: now, folder: session)
            }
            if !captureIssues.isEmpty {
                try DiagnosticFiles.replace(captureIssues, at: session.appendingPathComponent("capture-error.json"))
            }
            if let folders = try? FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil) {
                for folder in folders where folder.lastPathComponent.hasPrefix("incident-") {
                    if !notifiedIncidents.contains(folder.lastPathComponent),
                       let data = try? Data(contentsOf: folder.appendingPathComponent("incident.json")),
                       let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       report["recoveredUptime"] != nil, let samples = report["samples"] as? [String], !samples.isEmpty {
                        notifiedIncidents.insert(folder.lastPathComponent)
                        DispatchQueue.main.async { HangDiagnosticUI.notifySaved() }
                    }
                }
            }
        } catch {
            recordIssue("write-failed", detail: Self.errorCode(error))
            Log.hang.error("Diagnostic recording write failed", telemetry: "hang_diagnostic_write_failed")
        }
    }

    private func launchHelper(folder: URL, id: UUID) throws {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/NexGenVideoDiagnostics")
        process.arguments = [String(getpid()), id.uuidString, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        helper = process
    }

    private func recoverHelper(now: Double, folder: URL) {
        guard let action = helperRecovery.helperExited(
            now: now,
            stopping: stopping.load(ordering: .relaxed)
        ) else { return }
        let exit = Self.helperExitDescription(helper)
        switch action {
        case .restart(let attempt):
            do {
                try launchHelper(folder: folder, id: startupID)
                recordIssue("helper-exited", detail: "\(exit); restarted=\(attempt)", uptime: now)
                Log.hang.warning(
                    "Diagnostic helper exited (\(exit)); restarted",
                    telemetry: "hang_diagnostic_helper_restarted",
                    data: ["attempt": attempt, "exit": exit]
                )
            } catch {
                recordIssue(
                    "helper-restart-failed",
                    detail: "\(exit); attempt=\(attempt); error=\(Self.errorCode(error))",
                    uptime: now
                )
                Log.hang.error(
                    "Diagnostic helper restart failed",
                    telemetry: "hang_diagnostic_helper_restart_failed",
                    data: ["attempt": attempt, "exit": exit]
                )
            }
        case .backoff(let retryAfter):
            recordIssue("helper-restart-backoff", detail: "\(exit); retry-after=\(retryAfter)", uptime: now)
            Log.hang.error(
                "Diagnostic helper entered restart backoff",
                telemetry: "hang_diagnostic_helper_backoff",
                data: ["exit": exit]
            )
        }
    }

    private func recordIssue(_ code: String, detail: String? = nil,
                             uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard captureIssues.last?.code != code || captureIssues.last?.detail != detail else { return }
        captureIssues.append(DiagnosticCaptureIssue(uptime: uptime, code: code, detail: detail))
        if captureIssues.count > 32 { captureIssues.removeFirst(captureIssues.count - 32) }
    }

    private static func helperExitDescription(_ process: Process?) -> String {
        guard let process else { return "missing-process" }
        switch process.terminationReason {
        case .exit: return "exit-status-\(process.terminationStatus)"
        case .uncaughtSignal: return "signal-\(process.terminationStatus)"
        @unknown default: return "unknown-\(process.terminationStatus)"
        }
    }

    private static func errorCode(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain)-\(value.code)"
    }

    private func startHeartbeat(folder: URL, id: UUID) {
        pulseQueue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: pulseQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(500))
            timer.setEventHandler { [self] in
                try? DiagnosticFiles.replace(DiagnosticHeartbeat(
                    startupID: id, processID: getpid(), writerUptime: ProcessInfo.processInfo.systemUptime,
                    mainUptime: Double(mainPulse.load(ordering: .relaxed)) / 1_000_000_000,
                    runLoopUptime: Double(loopPulse.load(ordering: .relaxed)) / 1_000_000_000,
                    dropped: ring.dropped + snapshotLosses.load(ordering: .relaxed),
                    stopped: stopping.load(ordering: .relaxed)
                ), at: folder.appendingPathComponent("heartbeat.json"))
            }
            pulseTimer = timer
            timer.resume()
        }
    }

    private func startSampler(folder: URL) {
        samplerLifetime.enter()
        Thread.detachNewThread { [self] in
            defer { samplerLifetime.leave() }
            var lastRequest = ""
            while !stopping.load(ordering: .relaxed) {
                if let data = try? Data(contentsOf: folder.appendingPathComponent("sample-request.json")),
                   let request = try? JSONDecoder().decode(String.self, from: data),
                   request != lastRequest, UUID(uuidString: request) != nil {
                    lastRequest = request
                    for index in 0..<3 {
                        let output = folder.appendingPathComponent("self-\(request)-\(index).stacks")
                        let partial = output.appendingPathExtension("partial")
                        let result = partial.path.withCString { ngv_capture_self($0) }
                        do {
                            guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
                            try FileManager.default.moveItem(at: partial, to: output)
                        } catch {
                            try? DiagnosticFiles.replace("capture-or-finalize-failed:\(result)",
                                at: folder.appendingPathComponent("self-capture-error.json"))
                        }
                        Thread.sleep(forTimeInterval: 1)
                    }
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    func snapshot(_ value: HangDiagnosticTranscript, correlation: UInt64) {
        let capturedUptime = ProcessInfo.processInfo.systemUptime
        guard recordsContent, snapshotSlots.wait(timeout: .now()) == .success else {
            if recordsContent { snapshotLosses.wrappingAdd(1, ordering: .relaxed) }
            return
        }
        writer.async { [self] in
            defer { snapshotSlots.signal() }
            guard let key, let session else { return }
            do {
                let now = ProcessInfo.processInfo.systemUptime
                let pinned = FileManager.default.fileExists(atPath: session.appendingPathComponent("pinned.json").path)
                if !pinned, replayEpochs.last.map({ now - $0.began >= 60 }) ?? true {
                    replayEpochs.append((now, []))
                    previousSnapshot = nil
                    previousFrameDigest = nil
                }
                if replayEpochs.isEmpty { replayEpochs.append((now, [])) }
                while !pinned, replayEpochs.count > 1, now - replayEpochs[1].began > 120 {
                    for (file, size) in replayEpochs[0].files {
                        try FileManager.default.removeItem(at: file)
                        contentBytes -= size
                    }
                    replayEpochs.removeFirst()
                }
                snapshotOrdinal &+= 1
                guard Set(value.messages.map(\.id)).count == value.messages.count else {
                    recordIssue("duplicate-message-identity")
                    return
                }
                let frame = HangDiagnosticReplayFrame(sequence: snapshotOrdinal, uptime: capturedUptime, predecessor: previousFrameDigest,
                                                     previous: previousSnapshot, current: value)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let encoded = DiagnosticPrivacy.scrubJSON(try encoder.encode(frame))
                guard encoded.count <= 32 * 1024 * 1024,
                      (try? JSONDecoder().decode(HangDiagnosticReplayFrame.self, from: encoded)) != nil else {
                    recordIssue("snapshot-size-or-privacy-limit")
                    return
                }
                let encrypted = try AES.GCM.seal(encoded, using: key,
                    authenticating: Data(startupID.uuidString.utf8)).combined!
                guard contentBytes + encrypted.count <= 256 * 1024 * 1024 else {
                    recordIssue("content-limit")
                    contentEnabled.store(false, ordering: .relaxed)
                    return
                }
                let name = String(format: "replay-%012llu.enc", snapshotOrdinal)
                try DiagnosticFiles.write(encrypted, to: session.appendingPathComponent(name))
                replayEpochs[replayEpochs.count - 1].files.append((session.appendingPathComponent(name), encrypted.count))
                contentBytes += encrypted.count
                previousSnapshot = value
                previousFrameDigest = DiagnosticFiles.digest(encoded)
                record(.replaySnapshot, correlation: correlation, end: true, values: [Double(snapshotOrdinal)])
            } catch { recordIssue("snapshot-failed", detail: Self.errorCode(error)) }
        }
    }

    private static func prune(excluding id: UUID) throws {
        let folders = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && $0.lastPathComponent != id.uuidString }
            .filter { !hasLiveOwner($0) }
        for folder in try DiagnosticRetention.removableRecordings(folders) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    @MainActor
    private static func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Diagnostic recording unavailable"
        alert.informativeText = message
        alert.runModal()
    }

    private static func hasLiveOwner(_ folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("heartbeat.json")),
              let pulse = try? JSONDecoder().decode(DiagnosticHeartbeat.self, from: data),
              !pulse.stopped, pulse.processID > 0 else { return false }
        return kill(pulse.processID, 0) == 0 || errno == EPERM
    }

    func deleteRecordings() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writer.async { [self] in
                do {
                    pulseQueue.sync { [self] in pulseTimer?.cancel(); pulseTimer = nil }
                    guard samplerLifetime.wait(timeout: .now() + 5) == .success else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    if helper?.isRunning == true { helper?.terminate() }
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    while helper?.isRunning == true && ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    guard helper?.isRunning != true else { throw CocoaError(.fileWriteUnknown) }
                    let folders = try FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)
                    for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
                        guard folder.lastPathComponent == startupID.uuidString || !Self.hasLiveOwner(folder) else {
                            throw CocoaError(.fileWriteNoPermission)
                        }
                        try FileManager.default.removeItem(at: folder)
                        KeychainStore.delete(account: "hang-diagnostic-\(folder.lastPathComponent)")
                    }
                    session = nil
                    key = nil
                    previousSnapshot = nil
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func pruneExpiredRecordings() {
        writer.async {
            guard let folders = try? FileManager.default.contentsOfDirectory(at: Self.root,
                includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return }
            for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil && !Self.hasLiveOwner(folder) {
                guard (try? DiagnosticRetention.requiresExplicitDeletion(folder)) == false,
                      let date = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate,
                      Date().timeIntervalSince(date) > 7 * 86400 else { continue }
                do {
                    try FileManager.default.removeItem(at: folder)
                } catch { continue }
            }
        }
    }

    func stageExport(from folder: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            writer.async {
                do {
                    try DiagnosticFiles.copyRecording(from: folder, to: destination)
                    try DiagnosticFiles.replace(true, at: folder.appendingPathComponent("exported.json"))
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func exportCurrentForSelfTest(to directory: URL) async throws {
        guard HangDiagnosticSelfTest.requested else { return }
        try await withCheckedThrowingContinuation { continuation in
            writer.async { [self] in
                do {
                    guard let session else { throw CocoaError(.fileNoSuchFile) }
                    try DiagnosticFiles.copyRecording(from: session,
                        to: directory.appendingPathComponent(session.lastPathComponent))
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
