import AppKit
import CryptoKit
import Foundation
import HangDiagnostics
import HangStackSampler
import Synchronization

final class HangDiagnosticRecorder: @unchecked Sendable {
    static let shared = HangDiagnosticRecorder()
    static let root = MainThreadHangWatchdog.diagnosticsDirectory
        .appendingPathComponent("HangIncidents", isDirectory: true)
    private let enabled = Atomic<Bool>(false)
    private let mainPulse = Atomic<UInt64>(0)
    private let loopPulse = Atomic<UInt64>(0)
    private let stopping = Atomic<Bool>(false)
    private let startRequested = Atomic<Bool>(false)
    private let ring = DiagnosticRing()
    private let writer = DispatchQueue(label: "de.h5ventures.nexgenvideo.diagnostic-writer", qos: .utility)
    private let pulseQueue = DispatchQueue(label: "de.h5ventures.nexgenvideo.diagnostic-heartbeat", qos: .utility)
    private let snapshotSlots = DispatchSemaphore(value: 2)
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
    private var previousSnapshot: Data?
    private var snapshotOrdinal: UInt64 = 0
    private var replayEpochs: [(began: Double, files: [(URL, Int)])] = []
    private let contentEnabled = Atomic<Bool>(false)
    private var failure: String?
    @MainActor private var observer: CFRunLoopObserver?
    @MainActor private var mainTimer: Timer?

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
        alert.informativeText = "Diagnostics stay on this Mac until you export them. Structural recording includes UI timing and thread stacks. Replay recording also includes displayed chat text and images, encrypted on disk. Recordings expire after seven days."
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
                Self.showFailure("Cannot protect replay content in Keychain. Recording was not started.")
                return
            }
        }
        let metadata = [
            "schema": "1", "startupID": id.uuidString,
            "version": AppVersion.marketing ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "commit": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "mode": includeContent ? "encrypted-replay" : "structure",
        ]
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NexGenVideoDiagnostics")
        let process = Process()
        process.executableURL = executable
        let folder = Self.root.appendingPathComponent(id.uuidString, isDirectory: true)
        process.arguments = [String(getpid()), id.uuidString, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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
                        window.frame.height, window.backingScaleFactor, NSApp.modalWindow == nil ? 0 : 1])
                }
            }
        }
        self.mainTimer = mainTimer
        RunLoop.main.add(mainTimer, forMode: .common)
        writer.async { [self] in
            do {
                try DiagnosticFiles.directory(Self.root)
                try Self.prune(excluding: id)
                try DiagnosticFiles.directory(folder)
                try DiagnosticFiles.replace(metadata, at: folder.appendingPathComponent("build.json"))
                startupID = id
                session = folder
                key = contentKey
                contentEnabled.store(includeContent, ordering: .relaxed)
                helper = process
                try process.run()
                enabled.store(true, ordering: .relaxed)
                let timer = DispatchSource.makeTimerSource(queue: writer)
                timer.schedule(deadline: .now(), repeating: .milliseconds(500))
                timer.setEventHandler { [weak self] in self?.flush() }
                self.timer = timer
                timer.resume()
                startHeartbeat(folder: folder, id: id)
                startSampler(folder: folder)
            } catch {
                failure = "setup-failed"
                DispatchQueue.main.async { Self.showFailure("Diagnostic recording could not start.") }
            }
        }
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
                } else { failure = "journal-limit" }
            }
            if !FileManager.default.fileExists(atPath: session.appendingPathComponent("pinned.json").path) {
                while let first = files.first, now - first.2 > 120 {
                    try FileManager.default.removeItem(at: first.0)
                    journalBytes -= first.1
                    files.removeFirst()
                }
            }
            if let failure {
                try DiagnosticFiles.replace(failure, at: session.appendingPathComponent("capture-error.json"))
            }
            if helper?.isRunning != true && !stopping.load(ordering: .relaxed) {
                failure = "helper-exited"
            }
        } catch { failure = "write-failed" }
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
        Thread.detachNewThread { [self] in
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
                        if result == 0 { try? FileManager.default.moveItem(at: partial, to: output) }
                        if result != 0 {
                            try? DiagnosticFiles.replace(result, at: folder.appendingPathComponent("self-capture-error.json"))
                        }
                        Thread.sleep(forTimeInterval: 1)
                    }
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    func snapshot<T: Encodable & Sendable>(_ value: T, correlation: UInt64) {
        guard recordsContent, snapshotSlots.wait(timeout: .now()) == .success else {
            if recordsContent { snapshotLosses.wrappingAdd(1, ordering: .relaxed) }
            return
        }
        writer.async { [self] in
            defer { snapshotSlots.signal() }
            guard let key, let session else { return }
            do {
                let bytes = DiagnosticPrivacy.scrubJSON(try JSONEncoder().encode(value))
                guard (try? JSONSerialization.jsonObject(with: bytes)) != nil else {
                    failure = "privacy-filter-rejected-snapshot"
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                let pinned = FileManager.default.fileExists(atPath: session.appendingPathComponent("pinned.json").path)
                if !pinned, replayEpochs.last.map({ now - $0.began >= 60 }) ?? true {
                    replayEpochs.append((now, []))
                    previousSnapshot = nil
                }
                if replayEpochs.isEmpty { replayEpochs.append((now, [])) }
                while !pinned, replayEpochs.count > 1, now - replayEpochs[1].began > 120 {
                    for (file, size) in replayEpochs[0].files {
                        try FileManager.default.removeItem(at: file)
                        contentBytes -= size
                    }
                    replayEpochs.removeFirst()
                }
                guard bytes.count <= 32 * 1024 * 1024,
                      contentBytes < 256 * 1024 * 1024 else {
                    failure = "content-limit"
                    return
                }
                snapshotOrdinal &+= 1
                let delta = DiagnosticReplayDelta(sequence: snapshotOrdinal, previous: previousSnapshot, current: bytes)
                let encoded = try JSONEncoder().encode(delta)
                let encrypted = try AES.GCM.seal(encoded, using: key,
                    authenticating: Data(startupID.uuidString.utf8)).combined!
                guard contentBytes + encrypted.count <= 256 * 1024 * 1024 else {
                    failure = "content-limit"
                    return
                }
                let name = String(format: "replay-%012llu.enc", snapshotOrdinal)
                try DiagnosticFiles.write(encrypted, to: session.appendingPathComponent(name))
                replayEpochs[replayEpochs.count - 1].files.append((session.appendingPathComponent(name), encrypted.count))
                contentBytes += encrypted.count
                previousSnapshot = bytes
                record(.replaySnapshot, correlation: correlation, end: true, values: [Double(snapshotOrdinal)])
            } catch { failure = "snapshot-failed" }
        }
    }

    private static func prune(excluding id: UUID) throws {
        let folders = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && $0.lastPathComponent != id.uuidString }
            .sorted {
                ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
            }
        for (index, folder) in folders.enumerated() {
            let date = try folder.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            if Date().timeIntervalSince(date) > 7 * 86400 || index < folders.count - 2 {
                try FileManager.default.removeItem(at: folder)
                KeychainStore.delete(account: "hang-diagnostic-\(folder.lastPathComponent)")
            }
        }
    }

    @MainActor
    private static func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Diagnostic recording unavailable"
        alert.informativeText = message
        alert.runModal()
    }

    func deleteRecordings() {
        writer.async { [self] in
            helper?.terminate()
            guard let folders = try? FileManager.default.contentsOfDirectory(at: Self.root,
                includingPropertiesForKeys: nil) else { return }
            for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
                do {
                    try FileManager.default.removeItem(at: folder)
                    KeychainStore.delete(account: "hang-diagnostic-\(folder.lastPathComponent)")
                } catch { failure = "delete-failed" }
            }
        }
    }
}
