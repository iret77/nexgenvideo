import AppKit
import Darwin
import Foundation

private typealias TestingEntryPoint = @convention(thin) @Sendable (
    UnsafeRawBufferPointer?,
    @escaping @Sendable (UnsafeRawBufferPointer) -> Void
) async throws -> Bool

private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle
    private var count = 0
    private var failure: String?

    init(url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw HostError.message("The event output must be a new writable file.")
        }
        file = try FileHandle(forWritingTo: url)
    }

    func record(_ buffer: UnsafeRawBufferPointer) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        do {
            try file.write(contentsOf: Data(buffer))
            try file.write(contentsOf: Data([0x0A]))
            count += 1
        } catch {
            failure = String(describing: error)
        }
    }

    func finish() -> (count: Int, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try file.synchronize()
            try file.close()
        } catch {
            failure = failure ?? String(describing: error)
        }
        return (count, failure)
    }
}

private enum HostError: Error {
    case message(String)
}

@MainActor
private final class TestRuntimeApplication: NSApplication {
    override func reportException(_ exception: NSException) {
        let report: [String: Any] = [
            "name": exception.name.rawValue,
            "reason": exception.reason ?? "",
            "exceptionStack": exception.callStackSymbols,
            "reportStack": Thread.callStackSymbols,
            "pid": Int(getpid()),
            "parentPID": Int(getppid()),
            "sourceSHA": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "",
        ]
        let bytes = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
            ?? Data(exception.description.utf8)
        FileHandle.standardError.write(Data("NGV_APPKIT_TEST_EXCEPTION ".utf8) + bytes + Data([0x0A]))
        exit(EXIT_FAILURE)
    }
}

@MainActor
private final class TestApplication: NSObject, NSApplicationDelegate {
    private let entryPoint: TestingEntryPoint
    private let sink: EventSink
    private(set) var started = false
    private(set) var completed = false
    private(set) var succeeded = false
    private(set) var runningAtStart = false
    private(set) var failure: String?

    init(entryPoint: @escaping TestingEntryPoint, sink: EventSink) {
        self.entryPoint = entryPoint
        self.sink = sink
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !started else { return }
        started = true
        Task { [self] in
            runningAtStart = NSApplication.shared.isRunning
            do {
                succeeded = try await entryPoint(nil) { [sink] record in
                    sink.record(record)
                }
            } catch {
                failure = String(describing: error)
            }
            completed = true
            NSApplication.shared.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 0, data1: 0, data2: 0) {
                NSApplication.shared.postEvent(event, atStart: true)
            }
        }
    }
}

private struct HostReceipt: Encodable {
    let schema = 1
    let pid: Int32
    let parentPID: Int32
    let bundleBinary: String
    let hostExecutable: String
    let sourceSHA: String?
    let getterImagePath: String?
    let entryPointImagePath: String?
    let mainThread: Bool
    let applicationRunningAtStart: Bool
    let started: Bool
    let completed: Bool
    let abiSucceeded: Bool
    let eventRecordCount: Int
    let recordingError: String?
    let error: String?
    let runReturnedAfterCompletion: Bool
}

@main
private enum AppKitTestHost {
    @MainActor
    static func main() {
        do {
            let environment = ProcessInfo.processInfo.environment
            let bundle = try path("NGV_APPKIT_TEST_BUNDLE", in: environment)
            let events = try path("NGV_APPKIT_TEST_EVENTS", in: environment)
            let receiptPath = try path("NGV_APPKIT_TEST_RECEIPT", in: environment)
            guard Thread.isMainThread else {
                throw HostError.message("The AppKit test host must start on the main thread.")
            }
            guard let application = TestRuntimeApplication.shared as? TestRuntimeApplication else {
                throw HostError.message("The AppKit test host requires its exception-reporting application.")
            }
            guard !FileManager.default.fileExists(atPath: receiptPath.path) else {
                throw HostError.message("The completion receipt already exists.")
            }
            guard let handle = dlopen(bundle.path, RTLD_LAZY | RTLD_LOCAL) else {
                throw HostError.message(dlerror().map { String(cString: $0) } ?? "Cannot load the test bundle.")
            }
            guard let symbol = dlsym(handle, "swt_abiv0_getEntryPoint") else {
                throw HostError.message("The loaded test bundle has no public Swift Testing ABI entry point.")
            }
            typealias Getter = @convention(c) () -> UnsafeRawPointer
            let rawEntry = unsafeBitCast(symbol, to: Getter.self)()
            let getterImagePath = imagePath(containing: UnsafeRawPointer(symbol))
            let entryPointImagePath = imagePath(containing: rawEntry)
            let entry = unsafeBitCast(rawEntry, to: TestingEntryPoint.self)
            let sink = try EventSink(url: events)
            let delegate = TestApplication(entryPoint: entry, sink: sink)
            application.delegate = delegate
            // AppKit owns the event loop; test completion owns the process lifetime.
            application.run()
            let recorded = sink.finish()
            let receipt = HostReceipt(pid: getpid(), parentPID: getppid(),
                bundleBinary: bundle.path, hostExecutable: CommandLine.arguments[0],
                sourceSHA: environment["GITHUB_SHA"], getterImagePath: getterImagePath,
                entryPointImagePath: entryPointImagePath, mainThread: Thread.isMainThread,
                applicationRunningAtStart: delegate.runningAtStart, started: delegate.started,
                completed: delegate.completed, abiSucceeded: delegate.succeeded,
                eventRecordCount: recorded.count, recordingError: recorded.error,
                error: delegate.failure, runReturnedAfterCompletion: delegate.completed)
            try JSONEncoder().encode(receipt).write(to: receiptPath, options: .atomic)
            guard delegate.started, delegate.completed, delegate.succeeded,
                  delegate.runningAtStart, recorded.count > 0, recorded.error == nil,
                  delegate.failure == nil else {
                throw HostError.message("The hosted test run did not complete successfully; inspect its receipt and native events.")
            }
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("AppKit test host failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func imagePath(containing address: UnsafeRawPointer) -> String? {
        var info = Dl_info()
        guard dladdr(address, &info) != 0, let path = info.dli_fname else { return nil }
        return String(cString: path)
    }

    private static func path(_ key: String, in environment: [String: String]) throws -> URL {
        guard let value = environment[key], value.hasPrefix("/") else {
            throw HostError.message("\(key) must be an absolute path.")
        }
        return URL(fileURLWithPath: value).resolvingSymlinksInPath()
    }
}
