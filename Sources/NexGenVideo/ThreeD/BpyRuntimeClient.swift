import BpyRuntimeProtocol
import CryptoKit
import Darwin
import Foundation

enum BpyRuntimeError: LocalizedError {
    case unavailable(String)
    case invalidInput(String)
    case rejected(String)
    case timedOut
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidInput(let message),
             .rejected(let message), .invalidOutput(let message):
            message
        case .timedOut:
            "The 3D runtime did not respond in time."
        }
    }
}

struct BpyApprovedInputCopy: Sendable, Equatable {
    let approvedDirectory: URL
    let filename: String

    init(approvedDirectory: URL, filename: String) throws {
        guard approvedDirectory.isFileURL,
              filename.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                options: .regularExpression
              ) != nil else {
            throw BpyRuntimeError.invalidInput("Invalid approved input name.")
        }
        self.approvedDirectory = approvedDirectory.standardizedFileURL
        self.filename = filename
    }
}

struct BpyRuntimeJobResult: Sendable {
    let response: BpyServiceResponse
    let stagedOutputs: [String: URL]
}

private final class BpyReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var response: Data?
    private var chunk: Data?
    private var error: Error?

    func store(response: Data, chunk: Data? = nil) {
        lock.lock()
        self.response = response
        self.chunk = chunk
        lock.unlock()
    }

    func store(error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func load() -> (Data?, Data?, Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (response, chunk, error)
    }
}

final class BpyRuntimeSession: @unchecked Sendable {
    let sessionID: UUID
    let documentID: String
    let limits: BpyRuntimeLimits
    let serviceName: String

    private let connection: NSXPCConnection
    private let stagingRoot: URL
    private let lock = NSLock()
    private var opened = false
    private var closed = false
    private var validatedCandidates: [UUID: String] = [:]
    private var lastReadyResponse: BpyServiceResponse?
    private(set) var confirmedRevision: String?

    init(
        documentID: String,
        limits: BpyRuntimeLimits = .init(),
        serviceName: String = bpyRuntimeServiceNames[0]
    ) {
        let identifier = UUID()
        sessionID = identifier
        self.documentID = documentID
        self.confirmedRevision = nil
        self.limits = limits
        self.serviceName = serviceName
        stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NexGenVideo/BpyHost/\(identifier.uuidString)", isDirectory: true)
        connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BpyRuntimeServiceProtocol.self)
        connection.resume()
    }

    deinit {
        close()
    }

    func ready() throws -> BpyServiceResponse {
        try ensureOpen(force: true)
    }

    func runJob(
        id: UUID,
        expectedRevision: String?,
        source: String,
        inputs: [BpyApprovedInputCopy] = [],
        timeoutSeconds: Int? = nil
    ) throws -> BpyRuntimeJobResult {
        _ = try ensureOpen()
        if !inputs.isEmpty {
            var existing = try status(jobID: id)
            if existing.ok, existing.state != nil {
                existing.joinedExistingJob = true
                return try finish(jobID: id, response: existing, timeoutSeconds: timeoutSeconds)
            }
        }
        for input in inputs {
            try upload(input, jobID: id)
        }
        let request = BpyRunJobRequest(
            sessionID: sessionID,
            jobID: id,
            expectedRevision: expectedRevision,
            source: source,
            inputNames: inputs.map(\.filename),
            timeoutSeconds: timeoutSeconds
        )
        let response = try call { service, reply in
            service.runJob(try Self.encode(request), withReply: reply)
        }
        guard response.ok else {
            throw BpyRuntimeError.rejected(response.message ?? "The 3D job was rejected.")
        }
        return try finish(jobID: id, response: response, timeoutSeconds: timeoutSeconds)
    }

    private func finish(
        jobID: UUID,
        response initialResponse: BpyServiceResponse,
        timeoutSeconds: Int?
    ) throws -> BpyRuntimeJobResult {
        var response = initialResponse
        let joinedExistingJob = response.joinedExistingJob
        let deadline = Date().addingTimeInterval(TimeInterval((timeoutSeconds ?? limits.timeoutSeconds) + 15))
        while response.state == .accepted || response.state == .running {
            guard Date() < deadline else { throw BpyRuntimeError.timedOut }
            Thread.sleep(forTimeInterval: 0.05)
            response = try status(jobID: jobID)
            guard response.ok else {
                throw BpyRuntimeError.rejected(response.message ?? "The 3D job disappeared.")
            }
        }
        response.joinedExistingJob = joinedExistingJob
        if response.runtime != nil {
            lock.lock()
            lastReadyResponse = response
            lock.unlock()
        }
        var outputs: [String: URL] = [:]
        if response.state == .awaitingConfirmation || response.state == .confirmed {
            outputs = try downloadOutputs(response.outputs, jobID: jobID)
            if response.state == .awaitingConfirmation,
               let scene = response.outputs.first(where: { $0.name == "scene.blend" }) {
                lock.lock()
                validatedCandidates[jobID] = scene.sha256
                lock.unlock()
            }
        }
        return .init(response: response, stagedOutputs: outputs)
    }

    func status(jobID: UUID) throws -> BpyServiceResponse {
        let request = BpyJobReference(sessionID: sessionID, jobID: jobID)
        return try call { service, reply in
            service.jobStatus(try Self.encode(request), withReply: reply)
        }
    }

    func confirm(jobID: UUID, revision: String) throws -> BpyServiceResponse {
        lock.lock()
        let sceneSHA256 = validatedCandidates[jobID]
        lock.unlock()
        guard let sceneSHA256 else {
            throw BpyRuntimeError.invalidOutput("Validate the staged 3D candidate before confirmation.")
        }
        let request = BpyConfirmJobRequest(
            sessionID: sessionID,
            jobID: jobID,
            revision: revision,
            sceneSHA256: sceneSHA256
        )
        let response = try call(timeout: 180) { service, reply in
            service.confirmJob(try Self.encode(request), withReply: reply)
        }
        guard response.ok, response.state == .confirmed else {
            throw BpyRuntimeError.rejected(response.message ?? "The 3D candidate was not confirmed.")
        }
        lock.lock()
        confirmedRevision = revision
        validatedCandidates.removeValue(forKey: jobID)
        lastReadyResponse?.confirmedRevision = revision
        lock.unlock()
        return response
    }

    func cancel(jobID: UUID) throws -> BpyServiceResponse {
        let request = BpyJobReference(sessionID: sessionID, jobID: jobID)
        let response = try call { service, reply in
            service.cancelJob(try Self.encode(request), withReply: reply)
        }
        guard response.ok else {
            throw BpyRuntimeError.rejected(response.message ?? "The 3D job could not be cancelled.")
        }
        lock.lock()
        validatedCandidates.removeValue(forKey: jobID)
        lock.unlock()
        return response
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let wasOpened = opened
        lock.unlock()
        if wasOpened {
            let request = BpySessionReference(sessionID: sessionID)
            _ = try? call(timeout: 10) { service, reply in
                service.closeSession(try Self.encode(request), withReply: reply)
            }
        }
        connection.invalidate()
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    private func ensureOpen(force: Bool = false) throws -> BpyServiceResponse {
        lock.lock()
        if closed {
            lock.unlock()
            throw BpyRuntimeError.unavailable("The 3D document session is closed.")
        }
        if opened, !force {
            let response = lastReadyResponse
            lock.unlock()
            return response ?? .init(ok: true, confirmedRevision: confirmedRevision)
        }
        lock.unlock()
        let request = BpyOpenSessionRequest(
            sessionID: sessionID,
            documentID: documentID,
            confirmedRevision: nil,
            limits: limits
        )
        let response = try call(timeout: 180) { service, reply in
            service.openSession(try Self.encode(request), withReply: reply)
        }
        guard response.ok, let runtime = response.runtime,
              runtime.pythonVersion == "3.13.15", runtime.bpyVersion == "5.2.2" else {
            throw BpyRuntimeError.unavailable(
                response.message ?? "The bundled 3D runtime has the wrong identity."
            )
        }
        lock.lock()
        opened = true
        lastReadyResponse = response
        lock.unlock()
        return response
    }

    private func upload(_ input: BpyApprovedInputCopy, jobID: UUID) throws {
        let directoryFD = Darwin.open(
            input.approvedDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryFD >= 0 else {
            throw BpyRuntimeError.invalidInput("Approved input directory is unavailable.")
        }
        defer { Darwin.close(directoryFD) }
        var resolvedDirectory = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let directoryPathResult = resolvedDirectory.withUnsafeMutableBufferPointer {
            fcntl(directoryFD, F_GETPATH, $0.baseAddress)
        }
        guard directoryPathResult == 0,
              String(cString: resolvedDirectory) == input.approvedDirectory.path else {
            throw BpyRuntimeError.invalidInput("Approved input directory crosses a symbolic link.")
        }
        var directoryStat = stat()
        guard fstat(directoryFD, &directoryStat) == 0,
              (directoryStat.st_mode & S_IFMT) == S_IFDIR else {
            throw BpyRuntimeError.invalidInput("Approved input root is not a directory.")
        }
        let fileFD = Darwin.openat(
            directoryFD,
            input.filename,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileFD >= 0 else {
            throw BpyRuntimeError.invalidInput("Approved input is unavailable.")
        }
        let handle = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
        var resolvedFile = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let expectedFile = input.approvedDirectory.appendingPathComponent(input.filename).path
        let filePathResult = resolvedFile.withUnsafeMutableBufferPointer {
            fcntl(fileFD, F_GETPATH, $0.baseAddress)
        }
        guard filePathResult == 0,
              String(cString: resolvedFile) == expectedFile else {
            throw BpyRuntimeError.invalidInput("Approved input crosses a symbolic link.")
        }
        var before = stat()
        guard fstat(fileFD, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              UInt64(before.st_size) <= limits.inputBytes else {
            throw BpyRuntimeError.invalidInput("Approved input must be a bounded single-link file.")
        }

        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            digest.update(data: data)
        }
        let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
        try handle.seek(toOffset: 0)
        let total = UInt64(before.st_size)
        var offset: UInt64 = 0
        if total == 0 {
            try stageChunk(
                jobID: jobID, name: input.filename, offset: 0, total: 0,
                sha256: checksum, final: true, data: Data()
            )
        } else {
            while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
                let final = offset + UInt64(data.count) == total
                try stageChunk(
                    jobID: jobID, name: input.filename, offset: offset, total: total,
                    sha256: checksum, final: final, data: data
                )
                offset += UInt64(data.count)
            }
        }
        var after = stat()
        guard offset == total, fstat(fileFD, &after) == 0,
              (after.st_mode & S_IFMT) == S_IFREG, after.st_nlink == 1,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw BpyRuntimeError.invalidInput("Approved input changed while it was copied.")
        }
    }

    private func stageChunk(
        jobID: UUID,
        name: String,
        offset: UInt64,
        total: UInt64,
        sha256: String,
        final: Bool,
        data: Data
    ) throws {
        let request = BpyStageInputRequest(
            sessionID: sessionID,
            jobID: jobID,
            name: name,
            offset: offset,
            totalBytes: total,
            sha256: sha256,
            finalChunk: final
        )
        let response = try call { service, reply in
            service.stageInput(try Self.encode(request), chunk: data, withReply: reply)
        }
        guard response.ok else {
            throw BpyRuntimeError.rejected(response.message ?? "The 3D input was rejected.")
        }
    }

    private func downloadOutputs(
        _ descriptors: [BpyOutputDescriptor],
        jobID: UUID
    ) throws -> [String: URL] {
        let root = stagingRoot.appendingPathComponent(jobID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var result: [String: URL] = [:]
        for descriptor in descriptors {
            guard descriptor.name.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                options: .regularExpression
            ) != nil else {
                throw BpyRuntimeError.invalidOutput("The worker returned an invalid output name.")
            }
            let partial = root.appendingPathComponent(descriptor.name + ".part")
            let destination = root.appendingPathComponent(descriptor.name)
            if FileManager.default.fileExists(atPath: partial.path) {
                try FileManager.default.removeItem(at: partial)
            }
            guard FileManager.default.createFile(
                atPath: partial.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw BpyRuntimeError.invalidOutput("The host output staging file could not be created.")
            }
            let handle = try FileHandle(forWritingTo: partial)
            var digest = SHA256()
            var offset: UInt64 = 0
            do {
                while offset < descriptor.byteCount {
                    let count = min(4 * 1_024 * 1_024, Int(descriptor.byteCount - offset))
                    let request = BpyReadOutputRequest(
                        sessionID: sessionID,
                        jobID: jobID,
                        name: descriptor.name,
                        offset: offset,
                        maximumBytes: count
                    )
                    let chunk = try callChunk { service, reply in
                        service.readOutput(try Self.encode(request), withReply: reply)
                    }
                    guard !chunk.isEmpty, chunk.count <= count else {
                        throw BpyRuntimeError.invalidOutput("The worker returned a truncated output.")
                    }
                    try handle.write(contentsOf: chunk)
                    digest.update(data: chunk)
                    offset += UInt64(chunk.count)
                }
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: partial)
                throw error
            }
            let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard offset == descriptor.byteCount, checksum == descriptor.sha256 else {
                try? FileManager.default.removeItem(at: partial)
                throw BpyRuntimeError.invalidOutput("The worker output checksum does not match.")
            }
            try validateMagic(partial, mediaType: descriptor.mediaType)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            result[descriptor.name] = destination
        }
        return result
    }

    private func validateMagic(_ url: URL, mediaType: String) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 16) ?? Data()
        let valid: Bool
        switch mediaType {
        case "application/x-blender":
            valid = prefix.starts(with: Data("BLENDER".utf8))
        case "image/png":
            valid = prefix.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        case "application/json":
            valid = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) != nil
        default:
            valid = false
        }
        guard valid else { throw BpyRuntimeError.invalidOutput("The worker output type is invalid.") }
    }

    private func call(
        timeout: TimeInterval = 30,
        _ invoke: (BpyRuntimeServiceProtocol, @escaping (Data) -> Void) throws -> Void
    ) throws -> BpyServiceResponse {
        let box = BpyReplyBox()
        let semaphore = DispatchSemaphore(value: 0)
        guard let service = connection.remoteObjectProxyWithErrorHandler({ error in
            box.store(error: error)
            semaphore.signal()
        }) as? BpyRuntimeServiceProtocol else {
            throw BpyRuntimeError.unavailable("The 3D XPC service is unavailable.")
        }
        try invoke(service) { data in
            box.store(response: data)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw BpyRuntimeError.timedOut
        }
        let value = box.load()
        if let error = value.2 { throw error }
        guard let data = value.0 else { throw BpyRuntimeError.unavailable("Empty 3D service reply.") }
        return try Self.decode(data)
    }

    private func callChunk(
        timeout: TimeInterval = 30,
        _ invoke: (BpyRuntimeServiceProtocol, @escaping (Data, Data) -> Void) throws -> Void
    ) throws -> Data {
        let box = BpyReplyBox()
        let semaphore = DispatchSemaphore(value: 0)
        guard let service = connection.remoteObjectProxyWithErrorHandler({ error in
            box.store(error: error)
            semaphore.signal()
        }) as? BpyRuntimeServiceProtocol else {
            throw BpyRuntimeError.unavailable("The 3D XPC service is unavailable.")
        }
        try invoke(service) { response, chunk in
            box.store(response: response, chunk: chunk)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw BpyRuntimeError.timedOut
        }
        let value = box.load()
        if let error = value.2 { throw error }
        guard let responseData = value.0, let chunk = value.1 else {
            throw BpyRuntimeError.unavailable("Empty 3D service reply.")
        }
        let response = try Self.decode(responseData)
        guard response.ok else {
            throw BpyRuntimeError.rejected(response.message ?? "The 3D output was rejected.")
        }
        return chunk
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private static func decode(_ data: Data) throws -> BpyServiceResponse {
        try JSONDecoder().decode(BpyServiceResponse.self, from: data)
    }
}

@MainActor
final class BpyRuntimeHost {
    static let shared = BpyRuntimeHost()

    private struct Entry {
        weak var document: VideoProject?
        let documentID: String
        var session: BpyRuntimeSession?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    private init() {}

    func register(document: VideoProject, documentID: String) {
        let key = ObjectIdentifier(document)
        guard entries[key] == nil else { return }
        entries[key] = Entry(
            document: document,
            documentID: documentID,
            session: nil
        )
        entries = entries.filter { $0.value.document != nil }
    }

    func session(for document: VideoProject) -> BpyRuntimeSession? {
        let key = ObjectIdentifier(document)
        guard var entry = entries[key] else { return nil }
        if let session = entry.session { return session }
        let used = Set(entries.values.compactMap { $0.session?.serviceName })
        guard let serviceName = bpyRuntimeServiceNames.first(where: { !used.contains($0) }) else {
            return nil
        }
        let session = BpyRuntimeSession(
            documentID: entry.documentID,
            serviceName: serviceName
        )
        entry.session = session
        entries[key] = entry
        return session
    }

    func unregister(document: VideoProject) {
        entries.removeValue(forKey: ObjectIdentifier(document))?.session?.close()
    }

    func shutdown() {
        let sessions = entries.values.compactMap(\.session)
        entries.removeAll()
        sessions.forEach { $0.close() }
    }
}
