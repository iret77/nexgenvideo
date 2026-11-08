import ApplicationServices
import CryptoKit
import Darwin
import Foundation
import Synchronization

@_silgen_name("proc_pid_rusage")
private func readerProcessUsage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

@_silgen_name("proc_pidpath")
private func readerProcessPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

enum NativeAXPeer {
    typealias Query = NativeButtonAccessibility
    static let flag = "--ngv-native-ax-reader"
    private static let schema = "nexgenvideo/native-ax-peer/1"

    struct Identity: Codable, Sendable, Equatable {
        let pid: Int32
        let start: UInt64
        let executable: String

        static func read(_ pid: Int32) throws -> Identity {
            let memory = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 8)
            defer { memory.deallocate() }
            memory.initializeMemory(as: UInt8.self, repeating: 0, count: 1024)
            try require(pid > 1 && readerProcessUsage(pid, 4, memory) == 0, "peer-process-identity")
            let start = memory.load(fromByteOffset: 80, as: UInt64.self)
            var path = [UInt8](repeating: 0, count: 4096)
            try require(start > 0 && readerProcessPath(pid, &path, UInt32(path.count)) > 0, "peer-process-path")
            guard let end = path.firstIndex(of: 0), let name = String(bytes: path[..<end], encoding: .utf8) else {
                throw Failure("peer-process-path-encoding")
            }
            return Identity(pid: pid, start: start,
                executable: URL(fileURLWithPath: name).resolvingSymlinksInPath().path)
        }
    }

    struct Image: Codable, Sendable, Equatable {
        let path: String
        let uuid: String
        let SHA256: String

        static func current(address: UnsafeRawPointer? = nil) throws -> Image {
            var info = Dl_info()
            try require(dladdr(address ?? #dsohandle, &info) != 0, "peer-image-address")
            guard let filename = info.dli_fname, let base = info.dli_fbase else { throw Failure("peer-image-path") }
            let path = URL(fileURLWithPath: String(cString: filename)).resolvingSymlinksInPath().path
            let raw = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            let bytes = [UInt8](raw)
            func word(_ offset: Int) throws -> UInt32 {
                try require(offset >= 0 && offset + 4 <= bytes.count, "peer-image-header-bounds")
                return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
            }
            try require(try word(0) == 0xfeedfacf && word(4) == 0x0100000c, "peer-image-arm64")
            let count = Int(try word(16)), size = Int(try word(20))
            try require(count > 0 && count <= 4096 && size <= 16 * 1024 * 1024 && 32 + size <= bytes.count,
                "peer-image-load-commands")
            var offset = 32, identities: [String] = []
            for _ in 0..<count {
                let command = try word(offset), length = Int(try word(offset + 4))
                try require(length >= 8 && offset + length <= 32 + size, "peer-image-command-bounds")
                if command == 0x1b {
                    try require(length == 24, "peer-image-uuid-size")
                    let value = bytes[(offset + 8)..<(offset + 24)].map { String(format: "%02x", $0) }.joined()
                    identities.append(value)
                    let memory = UnsafeRawBufferPointer(start: base.advanced(by: offset + 8), count: 16)
                    try require(Array(memory) == Array(bytes[(offset + 8)..<(offset + 24)]), "peer-image-loaded-uuid")
                }
                offset += length
            }
            try require(offset == 32 + size && identities.count == 1 && identities[0] != String(repeating: "0", count: 32),
                "peer-image-uuid")
            return Image(path: path, uuid: identities[0], SHA256: SHA256Digest(raw))
        }
    }

    struct Evidence: Codable, Sendable {
        let owner: Identity
        let reader: Identity
        let image: Image
        let session: String
        let query: String
        let trusted: Bool
        let startupStarted: Double
        let readyAt: Double
        let sentAt: Double
        let deadline: Double
        let receivedAt: Double
        let stderr: String

        var evidence: [String: Any] {
            ["ownerPID": owner.pid, "ownerStart": owner.start, "readerPID": reader.pid,
                "readerStart": reader.start, "image": image.path, "imageUUID": image.uuid,
                "imageSHA256": image.SHA256, "session": session, "query": query, "AXTrusted": trusted,
                "startupStarted": startupStarted, "readyAt": readyAt, "sentAt": sentAt,
                "deadline": deadline, "receivedAt": receivedAt, "stderr": stderr]
        }
    }

    struct Failure: Error, Sendable { let message: String; init(_ message: String) { self.message = message } }
    struct Lifecycle: Codable, Sendable {
        let pid: Int32
        let reaped: Bool
        let exitStatus: Int32?
        let stdoutClosed: Bool
        let stderrClosed: Bool
        let forced: Bool
        let protocolClean: Bool
        let stderr: String
        let finishedAt: Double

        var clean: Bool { reaped && exitStatus == 0 && stdoutClosed && stderrClosed && !forced && protocolClean }
        var evidence: [String: Any] {
            ["pid": pid, "processReaped": reaped, "exitStatus": exitStatus as Any? ?? NSNull(),
                "stdoutClosed": stdoutClosed, "stderrClosed": stderrClosed, "forced": forced,
                "protocolClean": protocolClean, "stderr": stderr, "finishedAt": finishedAt]
        }
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }
    private static func SHA256Digest(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static var now: Double { ProcessInfo.processInfo.systemUptime }
    private static func nonce() -> String { UUID().uuidString.lowercased() }

    private struct Hello: Codable {
        let schema: String; let kind: String; let nonce: String; let owner: Identity; let image: Image
    }
    private struct Ready: Codable {
        let schema: String; let kind: String; let nonce: String
        let owner: Identity; let reader: Identity; let image: Image; let trusted: Bool; let offMain: Bool
    }
    private struct Read: Codable {
        let schema: String; let kind: String; let nonce: String
        let request: Query.Request; let nodeLimit: Int; let deadline: Double
    }
    private struct Reply: Codable {
        let schema: String; let kind: String; let nonce: String
        let owner: Identity; let reader: Identity; let image: Image; let snapshot: Query.Snapshot
    }
    private struct Command: Codable { let schema: String; let kind: String; let nonce: String }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        try require(data.count <= 2 * 1024 * 1024, "peer-frame-budget")
        data.append(10); return data
    }
    private static func decode<T: Decodable>(_ type: T.Type, data: Data, keys: Set<String>) throws -> T {
        try require(data.count <= 2 * 1024 * 1024, "peer-frame-budget")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == keys,
              object["schema"] as? String == schema else { throw Failure("peer-frame-schema") }
        try validateWireShape(object)
        return try JSONDecoder().decode(type, from: data)
    }
    static func validateWireShape(_ object: [String: Any]) throws {
        func shape(_ value: Any?, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
            guard let value = value as? [String: Any] else { throw Failure("peer-nested-object") }
            try require(required.isSubset(of: Set(value.keys)) && Set(value.keys).isSubset(of: required.union(optional)),
                "peer-nested-keys")
            return value
        }
        func frame(_ value: Any?) throws { _ = try shape(value, required: ["x", "y", "width", "height"]) }
        func request(_ value: Any?) throws {
            let value = try shape(value, required: ["pid", "windowNumber", "windowFrame", "contentFrame"])
            try frame(value["windowFrame"]); try frame(value["contentFrame"])
        }
        func node(_ value: Any?) throws {
            let value = try shape(value, required: ["pid", "statuses", "childTypes"],
                optional: ["parent", "role", "title", "label", "enabled", "frame", "scopeExclusion"])
            if let value = value["frame"] { try frame(value) }
        }
        func nodes(_ value: Any?, limit: Int) throws {
            guard let values = value as? [Any] else { throw Failure("peer-nested-array") }
            try require(values.count <= limit, "peer-nested-array-budget")
            for value in values { try node(value) }
        }
        for key in ["owner", "reader"] where object[key] != nil {
            _ = try shape(object[key], required: ["pid", "start", "executable"])
        }
        if let image = object["image"] { _ = try shape(image, required: ["path", "uuid", "SHA256"]) }
        if let value = object["request"] { try request(value) }
        if let value = object["snapshot"] {
            let value = try shape(value, required: ["request", "nodes", "windows", "cgWindows", "reportedWindowCount",
                "applicationStatuses", "windowCandidates", "complete", "started", "finished", "readOnMainThread",
                "contentRoots", "contentCandidates", "rootRivals", "reportedRootCount", "rootInventoryComplete", "chromeExclusions",
                "windowAttributes", "windowAttributeStatuses"],
                optional: ["failure"])
            try request(value["request"])
            try nodes(value["nodes"], limit: 2048); try nodes(value["windows"], limit: 128)
            try nodes(value["contentRoots"], limit: 256); try nodes(value["rootRivals"], limit: 256)
            guard let windows = value["cgWindows"] as? [Any], windows.count <= 4096,
                  let chrome = value["chromeExclusions"] as? [String: Any], chrome.count <= 7,
                  let attributes = value["windowAttributes"] as? [String], attributes.count <= 256,
                  Set(attributes).count == attributes.count,
                  attributes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
                  let attributeStatuses = value["windowAttributeStatuses"] as? [String: Any],
                  attributeStatuses.count <= 16 else {
                throw Failure("peer-nested-window-budget")
            }
            for window in windows {
                let window = try shape(window, required: [], optional: ["pid", "number", "frame", "onscreen"])
                if let value = window["frame"] { try frame(value) }
            }
            for value in chrome.values { try node(value) }
        }
    }

    static func delivery(_ snapshot: Query.Snapshot, cancelled: Bool) -> Query.Snapshot {
        guard cancelled && snapshot.complete else { return snapshot }
        var result = snapshot
        result.complete = false; result.failure = "peer-delivery-cancelled"
        return result
    }
    private static func pause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.005) { continuation.resume() }
        }
    }

    final class Pump: Sendable {
        private struct State { var data = Data(); var total = 0; var done = false; var failure: String? }
        private let state = Mutex(State())
        let limit: Int
        init(limit: Int) { self.limit = limit }

        func receive(_ bytes: Data) {
            state.withLock { value in
                value.total += bytes.count
                if value.total <= limit { value.data.append(bytes) } else { value.failure = "peer-output-budget" }
            }
        }
        func finish(_ failure: String? = nil) { state.withLock { $0.done = true; $0.failure = $0.failure ?? failure } }
        func line() throws -> Data? {
            try state.withLock { value in
                if let error = value.failure { throw Failure(error) }
                guard let end = value.data.firstIndex(of: 10) else { return nil }
                let result = value.data.prefix(upTo: end); value.data.removeSubrange(...end)
                return Data(result)
            }
        }
        var done: Bool { state.withLock { $0.done } }
        var text: String { state.withLock { String(decoding: $0.data, as: UTF8.self) } }
        var successful: Bool { state.withLock { $0.done && $0.failure == nil } }
        var consumed: Bool { state.withLock { $0.data.isEmpty } }

        func drain(_ fd: Int32) -> Task<Void, Never> {
            let completion = AsyncStream<Void> { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    defer { Darwin.close(fd); continuation.finish() }
                    var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                    let capacity = bytes.count
                    while true {
                        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, capacity) }
                        if count > 0 { receive(Data(bytes.prefix(count))) }
                        else if count == 0 { finish(); return }
                        else if errno != EINTR { finish("peer-output-read"); return }
                    }
                }
            }
            return Task { for await _ in completion {} }
        }
    }

    private final class Cancellation: Sendable {
        private struct State {
            var fd: Int32?; var active: String?; var cancelled: Set<String> = []
            var sent: Set<String> = []; var failure: String?
        }
        private let state = Mutex(State())
        func activate(_ nonce: String, fd: Int32) {
            state.withLock { $0.fd = fd; $0.active = nonce }
            if state.withLock({ $0.cancelled.contains(nonce) }) { cancel(nonce) }
        }
        func cancel(_ nonce: String) {
            state.withLock { value in
                value.cancelled.insert(nonce)
                guard value.active == nonce, let fd = value.fd, value.sent.insert(nonce).inserted else { return }
                do {
                    let data = try encode(Command(schema: schema, kind: "cancel", nonce: nonce))
                    let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
                    if count != data.count { value.failure = "peer-cancel-write" }
                } catch { value.failure = "peer-cancel-encoding" }
            }
        }
        func clear(_ nonce: String) {
            state.withLock { if $0.active == nonce { $0.active = nil }; $0.cancelled.remove(nonce); $0.sent.remove(nonce) }
        }
        func detach() { state.withLock { $0.fd = nil; $0.active = nil } }
        var failure: String? { state.withLock { $0.failure } }
        func contains(_ nonce: String) -> Bool { state.withLock { $0.cancelled.contains(nonce) } }
    }

    actor Session {
        private let owner: Identity
        private let image: Image
        private let session = nonce()
        private let startupStarted: Double
        private let output = Pump(limit: 64 * 1024 * 1024)
        private let errors = Pump(limit: 64 * 1024)
        private let cancellation = Cancellation()
        private var process: Process?
        private var input: FileHandle?
        private var drains: [Task<Void, Never>] = []
        private var ready: Ready?
        private var readyAt: Double = 0
        private var busy = false
        private var closed = false
        private var requests = 0
        private var lifecycle: Lifecycle?

        private init(owner: Identity, image: Image, started: Double) {
            self.owner = owner; self.image = image; startupStarted = started
        }

        static func prepare() async throws -> Session {
            let started = now
            let value = try Session(owner: Identity.read(getpid()), image: Image.current(), started: started)
            do { try await value.start(); return value }
            catch { _ = await value.close(); throw error }
        }

        private func start() async throws {
            let child = Process(), incoming = Pipe(), outgoing = Pipe(), diagnostics = Pipe()
            child.executableURL = URL(fileURLWithPath: owner.executable)
            child.arguments = [flag]; child.standardInput = incoming
            child.standardOutput = outgoing; child.standardError = diagnostics
            process = child
            try child.run()
            try? incoming.fileHandleForReading.close()
            try? outgoing.fileHandleForWriting.close()
            try? diagnostics.fileHandleForWriting.close()
            let stdout = dup(outgoing.fileHandleForReading.fileDescriptor)
            let stderr = dup(diagnostics.fileHandleForReading.fileDescriptor)
            guard stdout >= 0 && stderr >= 0 else {
                if stdout >= 0 { Darwin.close(stdout) }; if stderr >= 0 { Darwin.close(stderr) }
                throw Failure("peer-output-descriptors")
            }
            drains = [output.drain(stdout), errors.drain(stderr)]
            try outgoing.fileHandleForReading.close(); try diagnostics.fileHandleForReading.close()
            input = incoming.fileHandleForWriting
            let fd = incoming.fileHandleForWriting.fileDescriptor
            try require(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0
                && fcntl(fd, F_SETNOSIGPIPE, 1) == 0, "peer-input-descriptor")
            let deadline = startupStarted + 5
            try await write(encode(Hello(schema: schema, kind: "hello", nonce: session, owner: owner, image: image)), until: deadline)
            let frame = try await line(until: deadline)
            let response = try decode(Ready.self, data: frame,
                keys: ["schema", "kind", "nonce", "owner", "reader", "image", "trusted", "offMain"])
            try require(response.kind == "ready" && response.nonce == session && response.owner == owner
                && response.image == image && response.trusted && response.offMain,
                "peer-handshake")
            try require(response.reader.pid == child.processIdentifier && response.reader == Identity.read(child.processIdentifier)
                && response.reader.executable == owner.executable && owner == Identity.read(getpid()), "peer-handshake-identity")
            ready = response; readyAt = now
        }

        func read(_ request: Query.Request, nodeLimit: Int, seconds: Double) async -> Query.Snapshot {
            var failure = Query.Snapshot(request: request)
            guard !closed, !busy, let ready, let input, requests < 128, now - readyAt < 15,
                  request.pid == getpid(), request.windowFrame.valid, request.contentFrame.valid,
                  (1...2048).contains(nodeLimit), seconds.isFinite, seconds > 0, seconds <= 2 else {
                failure.failure = "invalid-reader-session-request"; return failure
            }
            busy = true; requests += 1
            let identity = nonce(), sent = now, deadline = sent + seconds
            defer { cancellation.clear(identity); busy = false }
            return await withTaskCancellationHandler {
                do {
                    try require(owner == Identity.read(getpid()) && ready.reader == Identity.read(ready.reader.pid), "peer-request-identity")
                    try await write(encode(Read(schema: schema, kind: "read", nonce: identity,
                        request: request, nodeLimit: nodeLimit, deadline: deadline)), until: deadline)
                    cancellation.activate(identity, fd: input.fileDescriptor)
                    if Task.isCancelled { cancellation.cancel(identity) }
                    let frame = try await line(until: deadline + 0.25)
                    let response = try decode(Reply.self, data: frame,
                        keys: ["schema", "kind", "nonce", "owner", "reader", "image", "snapshot"])
                    try require(response.kind == "snapshot" && response.nonce == identity && response.owner == owner
                        && response.reader == ready.reader && response.image == image && response.snapshot.request == request,
                        "peer-response-identity")
                    try require(owner == Identity.read(getpid()) && cancellation.failure == nil, "peer-response-owner")
                    var result = response.snapshot
                    try require(result.started.isFinite && result.finished.isFinite && result.started >= sent
                        && result.finished >= result.started && result.finished <= now && !result.readOnMainThread
                        && result.nodes.count <= nodeLimit && result.windows.count <= 128
                        && result.rootRivals.count <= 256, "peer-response-bounds")
                    for (index, node) in result.nodes.enumerated() {
                        try require(node.pid == owner.pid && (index == 0 ? node.parent == nil
                            : node.parent.map { $0 >= 0 && $0 < index } == true), "peer-response-node-lineage")
                    }
                    if result.complete {
                        try require(result.failure == nil && result.windowCandidates == 1 && result.contentCandidates == 1
                            && result.contentRoots.count == 1 && !result.nodes.isEmpty, "peer-response-completeness")
                    }
                    result.readerEvidence = Evidence(owner: owner, reader: ready.reader, image: image, session: session,
                        query: identity, trusted: ready.trusted, startupStarted: startupStarted, readyAt: readyAt,
                        sentAt: sent, deadline: deadline, receivedAt: now, stderr: errors.text)
                    return delivery(result, cancelled: Task.isCancelled || cancellation.contains(identity))
                } catch {
                    failure.failure = "peer-transport:" + String(describing: error)
                    failure.finished = now
                    _ = await close()
                    return failure
                }
            } onCancel: { [cancellation] in cancellation.cancel(identity) }
        }

        private func write(_ bytes: Data, until deadline: Double) async throws {
            guard let input else { throw Failure("peer-input-closed") }
            var offset = 0
            while offset < bytes.count {
                try require(now < deadline && process?.isRunning == true, "peer-write-deadline")
                let count = bytes.withUnsafeBytes {
                    Darwin.write(input.fileDescriptor, $0.baseAddress?.advanced(by: offset), bytes.count - offset)
                }
                if count > 0 { offset += count }
                else if errno == EAGAIN || errno == EINTR { await pause() }
                else { throw Failure("peer-input-write") }
            }
        }

        private func line(until deadline: Double) async throws -> Data {
            while now < deadline {
                if let frame = try output.line() { return frame }
                try require(!output.done, "peer-unexpected-eof")
                await pause()
            }
            throw Failure("peer-response-deadline")
        }

        func close() async -> Lifecycle {
            if let lifecycle { return lifecycle }
            if closed {
                while lifecycle == nil { await pause() }
                return lifecycle!
            }
            closed = true
            cancellation.detach()
            if let input {
                if let command = try? encode(Command(schema: schema, kind: "close", nonce: session)) {
                    _ = command.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress, command.count) }
                }
                try? input.close(); self.input = nil
            }
            guard let process, process.processIdentifier > 1 else {
                let result = Lifecycle(pid: 0, reaped: true, exitStatus: nil, stdoutClosed: true,
                    stderrClosed: true, forced: false, protocolClean: false, stderr: errors.text, finishedAt: now)
                lifecycle = result; return result
            }
            var forced = false
            let graceful = now + 0.5
            while process.isRunning && now < graceful { await pause() }
            if process.isRunning { forced = true; process.terminate() }
            let terminate = now + 0.5
            while process.isRunning && now < terminate { await pause() }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            let reaping = now + 2
            while process.isRunning && now < reaping { await pause() }
            if !process.isRunning { process.waitUntilExit() }
            let draining = now + 0.5
            while (!output.done || !errors.done) && now < draining { await pause() }
            if output.done && errors.done { for drain in drains { await drain.value } }
            let result = Lifecycle(pid: process.processIdentifier, reaped: !process.isRunning,
                exitStatus: process.isRunning ? nil : process.terminationStatus, stdoutClosed: output.done,
                stderrClosed: errors.done, forced: forced,
                protocolClean: output.successful && output.consumed && errors.successful,
                stderr: errors.text, finishedAt: now)
            lifecycle = result; return result
        }
    }

    @MainActor
    static func withSession<T>(_ operation: @MainActor (Session) async throws -> T) async throws -> (T, Lifecycle) {
        let session = try await Session.prepare()
        do {
            let value = try await operation(session), lifecycle = await session.close()
            try require(lifecycle.clean, "peer-scope-cleanup")
            return (value, lifecycle)
        } catch { _ = await session.close(); throw error }
    }

    private struct Input {
        var data = Data()
        var eof = false
        var failure: String?

        mutating func receive() throws {
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            let capacity = bytes.count
            let count = bytes.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, capacity) }
            if count > 0 { data.append(contentsOf: bytes.prefix(count)); try require(data.count <= 64 * 1024, "peer-input-budget") }
            else if count == 0 { eof = true }
            else if errno != EAGAIN && errno != EINTR { throw Failure("peer-input-read") }
        }
        mutating func line(until deadline: Double) throws -> Data {
            while now < deadline {
                if let end = data.firstIndex(of: 10) {
                    let value = Data(data.prefix(upTo: end)); data.removeSubrange(...end); return value
                }
                try require(!eof, "peer-parent-eof")
                try receive()
                if !data.contains(10) { usleep(1000) }
            }
            throw Failure("peer-input-deadline")
        }
        mutating func cancelled(_ nonce: String) -> Bool {
            do {
                try receive()
                if eof { failure = "peer-parent-eof"; return true }
                guard let end = data.firstIndex(of: 10) else { return false }
                let line = Data(data.prefix(upTo: end)); data.removeSubrange(...end)
                let command = try decode(Command.self, data: line, keys: ["schema", "kind", "nonce"])
                try require(command.kind == "cancel" && command.nonce == nonce, "peer-cancel-identity")
                return true
            } catch { failure = String(describing: error); return true }
        }
    }

    static func runIfRequested(exportAddress: UnsafeRawPointer? = nil) -> Int32? {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains(where: { $0.hasPrefix(flag) }) else { return nil }
        guard arguments == [flag] else { return EXIT_FAILURE }
        do {
            let image = try Image.current()
            if let exportAddress { try require(try Image.current(address: exportAddress) == image, "peer-export-image") }
            let own = try Identity.read(getpid()), parent = try Identity.read(getppid())
            try require(own.executable == parent.executable, "peer-parent-executable")
            try require(fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK) == 0, "peer-input-mode")
            DispatchQueue.global(qos: .userInitiated).async {
                do { try serve(owner: parent, own: own, image: image); Darwin.exit(EXIT_SUCCESS) }
                catch {
                    FileHandle.standardError.write(Data(("AX reader failed: " + String(describing: error) + "\n").utf8))
                    Darwin.exit(EXIT_FAILURE)
                }
            }
            dispatchMain()
        } catch { return EXIT_FAILURE }
    }

    private static func emit<T: Encodable>(_ value: T) throws {
        try FileHandle.standardOutput.write(contentsOf: encode(value))
    }

    private static func serve(owner: Identity, own: Identity, image: Image) throws {
        var input = Input()
        let hello = try decode(Hello.self, data: input.line(until: now + 5), keys: ["schema", "kind", "nonce", "owner", "image"])
        try require(hello.kind == "hello" && UUID(uuidString: hello.nonce) != nil && hello.owner == owner
            && hello.image == image && Identity.read(getppid()) == owner && !Thread.isMainThread, "peer-hello-identity")
        let trusted = AXIsProcessTrusted()
        try emit(Ready(schema: schema, kind: "ready", nonce: hello.nonce, owner: owner,
            reader: own, image: image, trusted: trusted, offMain: !Thread.isMainThread))
        try require(trusted, "peer-accessibility-untrusted")
        let lifetime = now + 15
        var used: Set<String> = [], previous: String?
        while now < lifetime, used.count < 128 {
            let line = try input.line(until: lifetime)
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any], let kind = object["kind"] as? String else {
                throw Failure("peer-request-kind")
            }
            if kind == "close" || kind == "cancel" {
                let command = try decode(Command.self, data: line, keys: ["schema", "kind", "nonce"])
                if kind == "close" { try require(command.nonce == hello.nonce, "peer-close-identity"); return }
                try require(command.nonce == previous, "peer-stale-cancel"); continue
            }
            let message = try decode(Read.self, data: line,
                keys: ["schema", "kind", "nonce", "request", "nodeLimit", "deadline"])
            try require(message.kind == "read" && UUID(uuidString: message.nonce) != nil
                && used.insert(message.nonce).inserted && message.request.pid == owner.pid
                && Identity.read(getppid()) == owner && Identity.read(getpid()) == own
                && message.deadline.isFinite && message.deadline > now && message.deadline - now <= 2,
                "peer-request-owner-or-deadline")
            var cancelled = false
            var result = Query.captureForParent(message.request, nodeLimit: message.nodeLimit, deadline: message.deadline) {
                cancelled = cancelled || input.cancelled(message.nonce)
                return cancelled
            }
            if let failure = input.failure { result.complete = false; result.failure = failure }
            try require(Identity.read(getppid()) == owner, "peer-parent-changed")
            try emit(Reply(schema: schema, kind: "snapshot", nonce: message.nonce,
                owner: owner, reader: own, image: image, snapshot: result))
            previous = message.nonce
        }
        throw Failure("peer-session-budget")
    }
}

@_cdecl("NGVRunNativeAXReaderIfRequested")
func NGVRunNativeAXReaderIfRequested(_ address: UnsafeRawPointer?) -> Int32 {
    NativeAXPeer.runIfRequested(exportAddress: address) ?? -1
}
