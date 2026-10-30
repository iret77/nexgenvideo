import BpyRuntimeProtocol
import CryptoKit
import Darwin
import Foundation
import os

private let openDiagnostics = Logger(subsystem: "de.h5ventures.nexgenvideo.bpy-service", category: "open-diagnostic")

private enum OpenStage: String {
    case decode, contract, claim, preparation, bookmark, check, validateMount, reserve
}

private func diagnoseStorageMount(_ storage: BpyStorageLease, maximumBytes: UInt64,
                                  sessionID: UUID, owner: UUID, validate: Bool) {
    let descriptor = Darwin.open(storage.mountPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    let directOpenErrno = descriptor < 0 ? errno : 0
    let directCloseErrno = descriptor >= 0 && Darwin.close(descriptor) != 0 ? errno : 0
    var domain = "not-run"
    var code = 0
    if validate {
        do {
            let checked = try BpyStoragePaths.validateMount(storage, maximumBytes: maximumBytes)
            if Darwin.close(checked) != 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            domain = "success"
        } catch {
            let failure = error as NSError
            domain = failure.domain
            code = failure.code
        }
    }
    let started = processUsage(getpid())?.startAbsoluteTime ?? 0
    openDiagnostics.notice("open.mount-probe session=\(sessionID.uuidString, privacy: .public) owner=\(owner.uuidString, privacy: .public) pid=\(getpid(), privacy: .public) start=\(started, privacy: .public) directOpenErrno=\(directOpenErrno, privacy: .public) directCloseErrno=\(directCloseErrno, privacy: .public) validationDomain=\(domain, privacy: .public) validationCode=\(code, privacy: .public)")
}

@_silgen_name("proc_pid_rusage")
private func procPIDRusage(
    _ processIdentifier: pid_t,
    _ flavor: Int32,
    _ buffer: UnsafeMutableRawPointer
) -> Int32

private struct DarwinAttrList {
    var bitmapCount: UInt16
    var reserved: UInt16
    var commonAttributes: UInt32
    var volumeAttributes: UInt32
    var directoryAttributes: UInt32
    var fileAttributes: UInt32
    var forkAttributes: UInt32
}

private struct DarwinFSID {
    var first: Int32
    var second: Int32
}

@_silgen_name("getattrlistbulk")
private func getAttributeListBulk(
    _ descriptor: Int32,
    _ attributes: UnsafeMutablePointer<DarwinAttrList>,
    _ buffer: UnsafeMutableRawPointer,
    _ bufferSize: Int,
    _ options: UInt64
) -> Int32

@_silgen_name("fsgetpath")
private func fileSystemPath(
    _ buffer: UnsafeMutablePointer<CChar>,
    _ bufferSize: Int,
    _ fileSystem: UnsafeMutablePointer<DarwinFSID>,
    _ fileIdentifier: UInt64
) -> Int


private extension NSLock {
    func access<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private func encoded(_ response: BpyServiceResponse) -> Data {
    (try? JSONEncoder().encode(response)) ?? Data()
}

private func failure(_ message: String) -> Data {
    encoded(.init(ok: false, message: message))
}

private func isSafeName(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    func alnum(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
    return (1...128).contains(bytes.count) && bytes.first.map(alnum) == true
        && bytes.allSatisfy { alnum($0) || [45, 46, 95].contains($0) }
}

private func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func boundedLogText(_ value: String, bytes: Int) -> String {
    var data = Data(value.utf8.prefix(max(0, bytes)))
    while !data.isEmpty {
        if let text = String(data: data, encoding: .utf8) { return text }
        data.removeLast()
    }
    return ""
}

private func boundedLogTailText(_ value: String, bytes: Int) -> String {
    var data = Data(value.utf8.suffix(max(0, bytes)))
    while !data.isEmpty {
        if let text = String(data: data, encoding: .utf8) { return text }
        data.removeFirst()
    }
    return ""
}

private struct ProcessUsage {
    let physicalFootprint: UInt64
    let startAbsoluteTime: UInt64
}

private func processUsage(_ processIdentifier: pid_t) -> ProcessUsage? {
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_024, alignment: 8)
    defer { buffer.deallocate() }
    buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 1_024)
    guard procPIDRusage(processIdentifier, 4, buffer) == 0 else { return nil }
    return ProcessUsage(
        physicalFootprint: buffer.load(fromByteOffset: 72, as: UInt64.self),
        startAbsoluteTime: buffer.load(fromByteOffset: 80, as: UInt64.self)
    )
}

private func stopProcess(_ process: BpyRemoteProcess) {
    do { try process.signal(SIGTERM) }
    catch { openDiagnostics.error("runtime.stop-fail code=\((error as NSError).code, privacy: .public)") }
}

private struct DirectoryUsage {
    let bytes: UInt64
    let files: Int
    let limitReason: String?
    let resources: [VnodeIdentity: UInt64]
}

private struct VnodeIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
}

private struct DirectorySnapshot {
    var bytes: UInt64
    var resources: [VnodeIdentity: UInt64]
    var files: Int
    var limitReason: String?
}

private struct DirectoryReference {
    let path: String?
    let fileSystem: DarwinFSID?
    let identity: VnodeIdentity?
}

private enum DirectoryScanError: Error {
    case unresolvedDirectory
}

private let kernelFWrite: UInt32 = 2
private let attributeBitmapCount: UInt16 = 5
private let attributeCommonName: UInt32 = 0x0000_0001
private let attributeCommonDevice: UInt32 = 0x0000_0002
private let attributeCommonFileSystem: UInt32 = 0x0000_0004
private let attributeCommonObjectType: UInt32 = 0x0000_0008
private let attributeCommonFileID: UInt32 = 0x0200_0000
private let attributeCommonError: UInt32 = 0x2000_0000
private let attributeCommonReturned: UInt32 = 0x8000_0000
private let attributeDirectoryAllocationSize: UInt32 = 0x0000_0008
private let attributeFileTotalSize: UInt32 = 0x0000_0002
private let attributeFileAllocationSize: UInt32 = 0x0000_0004
private let attributePackInvalid: UInt64 = 0x0000_0008
private let vnodeTypeRegular: UInt32 = 1
private let vnodeTypeDirectory: UInt32 = 2
private let bulkAttributeBufferSize = 64 * 1_024
private let bulkAttributeCommonFixedSize = 60
private let bulkAttributeDirectoryFixedSize = 68
private let bulkAttributeFileFixedSize = 76

private func vnodeIdentity(_ status: stat) -> VnodeIdentity {
    .init(
        device: UInt64(UInt32(bitPattern: status.st_dev)),
        inode: UInt64(status.st_ino)
    )
}

private func vnodeBytes(logical: Int64, blocks: Int64) -> UInt64 {
    max(
        logical > 0 ? UInt64(logical) : 0,
        blocks > 0 ? UInt64(blocks) * 512 : 0
    )
}

private func directoryDescriptor(
    _ reference: DirectoryReference,
    managedRoots: [String]
) throws -> Int32? {
    for _ in 0..<4 {
        let path: String
        if let directPath = reference.path {
            path = directPath
        } else if var fileSystem = reference.fileSystem, let identity = reference.identity {
            var pathBytes = [CChar](repeating: 0, count: Int(PATH_MAX))
            errno = 0
            let length = pathBytes.withUnsafeMutableBufferPointer { buffer in
                fileSystemPath(
                    buffer.baseAddress!,
                    buffer.count,
                    &fileSystem,
                    identity.inode
                )
            }
            if length < 0 {
                if errno == ENOENT { return nil }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard length > 0, length < pathBytes.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            path = String(cString: pathBytes)
            guard isManagedPath(path, roots: managedRoots) else {
                throw CocoaError(.fileReadNoPermission)
            }
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }

        errno = 0
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0 {
            if reference.path == nil && errno == ENOENT { continue }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            let savedError = errno
            Darwin.close(descriptor)
            throw POSIXError(.init(rawValue: savedError) ?? .EIO)
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadCorruptFile)
        }
        if let identity = reference.identity, vnodeIdentity(status) != identity {
            Darwin.close(descriptor)
            continue
        }
        return descriptor
    }
    throw DirectoryScanError.unresolvedDirectory
}

private func directorySnapshot(
    _ roots: [URL],
    byteLimit: UInt64,
    fileLimit: Int,
    beforeResolve: ((DirectoryReference) throws -> Void)? = nil,
    missingDirectory: ((DirectoryReference) -> Void)? = nil
) throws -> DirectorySnapshot {
    var snapshot = DirectorySnapshot(bytes: 0, resources: [:], files: 0, limitReason: nil)
    let managedRoots = try managedRootPaths(roots)
    var pending = roots.map {
        DirectoryReference(path: $0.path, fileSystem: nil, identity: nil)
    }
    var traversedDirectories = Set<VnodeIdentity>()
    let requestedCommon = attributeCommonName
        | attributeCommonDevice
        | attributeCommonFileSystem
        | attributeCommonObjectType
        | attributeCommonFileID
        | attributeCommonError
        | attributeCommonReturned
    var attributes = DarwinAttrList(
        bitmapCount: attributeBitmapCount,
        reserved: 0,
        commonAttributes: requestedCommon,
        volumeAttributes: 0,
        directoryAttributes: attributeDirectoryAllocationSize,
        fileAttributes: attributeFileTotalSize | attributeFileAllocationSize,
        forkAttributes: 0
    )
    let buffer = UnsafeMutableRawPointer.allocate(
        byteCount: bulkAttributeBufferSize,
        alignment: 8
    )
    defer { buffer.deallocate() }

    func record(identity: VnodeIdentity, bytes: UInt64, countFile: Bool) -> Bool {
        if countFile {
            snapshot.files += 1
        }
        let prior = snapshot.resources[identity] ?? 0
        let observed = max(prior, bytes)
        if observed > prior {
            let increase = observed - prior
            snapshot.resources[identity] = observed
            if increase > byteLimit - min(snapshot.bytes, byteLimit) {
                snapshot.bytes = byteLimit &+ 1
                snapshot.limitReason = snapshot.files > fileLimit ? "file-count" : "disk"
                return false
            }
            snapshot.bytes += increase
        }
        if snapshot.files > fileLimit {
            snapshot.limitReason = "file-count"
            return false
        }
        return true
    }

    while let reference = pending.popLast() {
        try beforeResolve?(reference)
        guard let descriptor = try directoryDescriptor(
            reference,
            managedRoots: managedRoots
        ) else {
            missingDirectory?(reference)
            continue
        }
        do {
            var directoryStatus = stat()
            guard Darwin.fstat(descriptor, &directoryStatus) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            let directoryIdentity = vnodeIdentity(directoryStatus)
            if !traversedDirectories.insert(directoryIdentity).inserted {
                Darwin.close(descriptor)
                continue
            }
            if reference.path != nil {
                let bytes = vnodeBytes(logical: 0, blocks: Int64(directoryStatus.st_blocks))
                guard record(identity: directoryIdentity, bytes: bytes, countFile: false) else {
                    Darwin.close(descriptor)
                    return snapshot
                }
            }

            while true {
                buffer.initializeMemory(
                    as: UInt8.self,
                    repeating: 0,
                    count: bulkAttributeBufferSize
                )
                errno = 0
                let entryCount = getAttributeListBulk(
                    descriptor,
                    &attributes,
                    buffer,
                    bulkAttributeBufferSize,
                    attributePackInvalid
                )
                guard entryCount >= 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                if entryCount == 0 { break }
                var offset = 0
                for _ in 0..<entryCount {
                    guard offset <= bulkAttributeBufferSize - bulkAttributeCommonFixedSize else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let entry = UnsafeRawPointer(buffer.advanced(by: offset))
                    let length = Int(entry.loadUnaligned(as: UInt32.self))
                    guard length >= bulkAttributeCommonFixedSize,
                          length <= bulkAttributeBufferSize - offset else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let returnedCommon = entry.loadUnaligned(
                        fromByteOffset: 4,
                        as: UInt32.self
                    )
                    let returnedDirectory = entry.loadUnaligned(
                        fromByteOffset: 12,
                        as: UInt32.self
                    )
                    let returnedFile = entry.loadUnaligned(
                        fromByteOffset: 16,
                        as: UInt32.self
                    )
                    let entryError = entry.loadUnaligned(
                        fromByteOffset: 24,
                        as: UInt32.self
                    )
                    if entryError == UInt32(ENOENT) { offset += length; continue }
                    guard entryError == 0 else {
                        throw POSIXError(.init(rawValue: Int32(entryError)) ?? .EIO)
                    }
                    guard returnedCommon & requestedCommon == requestedCommon else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let objectType = entry.loadUnaligned(
                        fromByteOffset: 48,
                        as: UInt32.self
                    )
                    let fixedSize = objectType == vnodeTypeDirectory
                        ? bulkAttributeDirectoryFixedSize
                        : bulkAttributeFileFixedSize
                    guard length >= fixedSize else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let nameOffset = Int(entry.loadUnaligned(
                        fromByteOffset: 28,
                        as: Int32.self
                    )) + 28
                    let nameLength = Int(entry.loadUnaligned(
                        fromByteOffset: 32,
                        as: UInt32.self
                    ))
                    guard nameOffset >= fixedSize,
                          nameLength > 0,
                          nameOffset <= length - nameLength,
                          entry.loadUnaligned(
                            fromByteOffset: nameOffset + nameLength - 1,
                            as: UInt8.self
                          ) == 0 else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let device = entry.loadUnaligned(fromByteOffset: 36, as: Int32.self)
                    let fileSystem = DarwinFSID(
                        first: entry.loadUnaligned(fromByteOffset: 40, as: Int32.self),
                        second: entry.loadUnaligned(fromByteOffset: 44, as: Int32.self)
                    )
                    let identity = VnodeIdentity(
                        device: UInt64(UInt32(bitPattern: device)),
                        inode: entry.loadUnaligned(fromByteOffset: 52, as: UInt64.self)
                    )
                    let bytes: UInt64
                    if objectType == vnodeTypeDirectory {
                        guard returnedDirectory & attributeDirectoryAllocationSize != 0 else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        let allocated = entry.loadUnaligned(fromByteOffset: 60, as: Int64.self)
                        guard allocated >= 0 else { throw CocoaError(.fileReadCorruptFile) }
                        bytes = UInt64(allocated)
                    } else if returnedFile
                        & (attributeFileTotalSize | attributeFileAllocationSize)
                        == (attributeFileTotalSize | attributeFileAllocationSize) {
                        let logical = entry.loadUnaligned(fromByteOffset: 60, as: Int64.self)
                        let allocated = entry.loadUnaligned(fromByteOffset: 68, as: Int64.self)
                        guard logical >= 0, allocated >= 0 else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        bytes = max(UInt64(logical), UInt64(allocated))
                    } else if objectType == vnodeTypeRegular {
                        throw CocoaError(.fileReadCorruptFile)
                    } else {
                        bytes = 0
                    }
                    guard record(identity: identity, bytes: bytes, countFile: true) else {
                        Darwin.close(descriptor)
                        return snapshot
                    }
                    if objectType == vnodeTypeDirectory,
                       !traversedDirectories.contains(identity) {
                        pending.append(.init(
                            path: nil,
                            fileSystem: fileSystem,
                            identity: identity
                        ))
                    }
                    offset += length
                }
            }
            Darwin.close(descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
    return snapshot
}

private func usage(
    resources: [VnodeIdentity: UInt64],
    files: Int,
    byteLimit: UInt64,
    fileLimit: Int
) -> DirectoryUsage {
    var bytes: UInt64 = 0
    for size in resources.values {
        guard size <= byteLimit - min(bytes, byteLimit) else {
            return .init(
                bytes: byteLimit &+ 1,
                files: files,
                limitReason: files > fileLimit ? "file-count" : "disk",
                resources: resources
            )
        }
        bytes += size
    }
    return .init(bytes: bytes, files: files, limitReason: files > fileLimit ? "file-count" : nil, resources: resources)
}

private func directoryUsage(
    _ roots: [URL],
    byteLimit: UInt64,
    fileLimit: Int
) throws -> DirectoryUsage {
    var resources: [VnodeIdentity: UInt64] = [:]
    var files = 0
    var completedSnapshots = 0
    var unresolvedSnapshots = 0
    while completedSnapshots < 3 {
        do {
            let snapshot = try directorySnapshot(
                roots,
                byteLimit: byteLimit,
                fileLimit: fileLimit
            )
            let current = usage(
                resources: snapshot.resources,
                files: snapshot.files,
                byteLimit: byteLimit,
                fileLimit: fileLimit
            )
            if current.limitReason != nil { return current }
            mergeVnodes(snapshot.resources, into: &resources)
            files = max(files, snapshot.files)
            let conservative = usage(
                resources: resources,
                files: files,
                byteLimit: byteLimit,
                fileLimit: fileLimit
            )
            if conservative.limitReason != nil { return conservative }
            completedSnapshots += 1
        } catch DirectoryScanError.unresolvedDirectory {
            unresolvedSnapshots += 1
            if unresolvedSnapshots >= 3 { throw DirectoryScanError.unresolvedDirectory }
        }
    }
    return usage(
        resources: resources,
        files: files,
        byteLimit: byteLimit,
        fileLimit: fileLimit
    )
}

private func directoryDeletionProbe() throws -> [String: Any] {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bpy-directory-probe-\(UUID().uuidString)")
    let child = root.appendingPathComponent("queued")
    let nested = child.appendingPathComponent("inside.bin")
    let retained = root.appendingPathComponent("retained.bin")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try Data(repeating: 0x5a, count: 4096).write(to: nested)
    let payload = Data(repeating: 0xa5, count: 8192)
    try payload.write(to: retained)
    func status(_ url: URL) throws -> stat {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return value
    }
    let childIdentity = vnodeIdentity(try status(child))
    let nestedIdentity = vnodeIdentity(try status(nested))
    let retainedStatus = try status(retained)
    let retainedIdentity = vnodeIdentity(retainedStatus)
    let retainedBytes = vnodeBytes(logical: retainedStatus.st_size, blocks: Int64(retainedStatus.st_blocks))
    let baseline = try directorySnapshot([root], byteLimit: 1_048_576, fileLimit: 10)
    let childBytes = baseline.resources[childIdentity] ?? 0
    guard baseline.limitReason == nil, baseline.files == 3,
          let nestedBytes = baseline.resources[nestedIdentity], nestedBytes >= 4096,
          baseline.resources[retainedIdentity] == retainedBytes else {
        throw CocoaError(.fileReadCorruptFile)
    }
    var events: [String] = []
    let interrupted = try directorySnapshot([root], byteLimit: 1_048_576, fileLimit: 10,
        beforeResolve: { reference in
            guard reference.identity == childIdentity else { return }
            guard events.isEmpty, reference.path == nil, reference.fileSystem != nil,
                  vnodeIdentity(try status(child)) == childIdentity else { throw CocoaError(.fileReadCorruptFile) }
            events.append("enumerated")
            guard Darwin.unlink(nested.path) == 0, Darwin.rmdir(child.path) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            events.append("unlinked")
        }, missingDirectory: { reference in
            if reference.identity == childIdentity { events.append("missing") }
        })
    guard events == ["enumerated", "unlinked", "missing"], interrupted.limitReason == nil,
          interrupted.files == 2, interrupted.resources[retainedIdentity] == retainedBytes,
          (interrupted.resources[childIdentity] ?? 0) == childBytes, interrupted.resources[nestedIdentity] == nil,
          interrupted.bytes >= retainedBytes, try Data(contentsOf: retained) == payload else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let followup = try directoryUsage([root], byteLimit: 1_048_576, fileLimit: 10)
    guard followup.limitReason == nil, followup.files == 1,
          followup.resources[retainedIdentity] == retainedBytes,
          followup.resources[childIdentity] == nil, followup.resources[nestedIdentity] == nil else {
        throw CocoaError(.fileReadCorruptFile)
    }
    events.append("completed")
    return ["schema": "nexgenvideo/bpy-directory-deletion/1", "events": events, "processIdentifier": getpid(),
            "queuedDevice": childIdentity.device, "queuedInode": childIdentity.inode,
            "queuedDirectoryBytes": childBytes, "interruptedDirectoryBytes": interrupted.resources[childIdentity] ?? 0,
            "retainedDevice": retainedIdentity.device, "retainedInode": retainedIdentity.inode,
            "baselineFiles": baseline.files, "interruptedFiles": interrupted.files, "followupFiles": followup.files,
            "payloadBytes": payload.count, "retainedBytes": retainedBytes,
            "interruptedRetainedBytes": interrupted.resources[retainedIdentity]!,
            "followupRetainedBytes": followup.resources[retainedIdentity]!,
            "payloadSHA256": sha256(payload), "retainedSHA256": try sha256(retained)]
}

private func managedRootPaths(_ roots: [URL]) throws -> [String] {
    try roots.map { root in
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard bytes.withUnsafeMutableBufferPointer({ Darwin.fcntl(descriptor, F_GETPATH, $0.baseAddress!) }) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return String(cString: bytes)
    }
}

private func isManagedPath(_ path: String?, roots: [String]) -> Bool {
    guard let path else { return false }
    let candidate = path
    return roots.contains { candidate == $0 || candidate.hasPrefix($0 + "/") }
}

private func mergeVnodes(
    _ observations: [VnodeIdentity: UInt64],
    into resources: inout [VnodeIdentity: UInt64]
) {
    for (identity, bytes) in observations {
        resources[identity] = max(resources[identity] ?? 0, bytes)
    }
}

private func ownedRetainedVnodes(_ observations: [BpyObservedVnode], roots: [URL]) throws -> [VnodeIdentity: UInt64] {
    let paths = try managedRootPaths(roots)
    var resources: [VnodeIdentity: UInt64] = [:]
    for observation in observations {
        if observation.links != 0 && !isManagedPath(observation.path, roots: paths) {
            guard (observation.openFlags ?? 0) & kernelFWrite == 0 else { throw CocoaError(.fileWriteNoPermission) }
            continue
        }
        let key = VnodeIdentity(device: observation.device, inode: observation.inode)
        resources[key] = max(resources[key] ?? 0, vnodeBytes(logical: observation.logical, blocks: observation.blocks))
    }
    return resources
}

private func resourceUsage(
    roots: [URL],
    observedVnodes: [BpyObservedVnode],
    byteLimit: UInt64,
    fileLimit: Int
) throws -> DirectoryUsage {
    let named = try directoryUsage(roots, byteLimit: byteLimit, fileLimit: fileLimit)
    guard named.limitReason == nil else { return named }
    var resources = named.resources
    var files = named.files
    for (identity, bytes) in try ownedRetainedVnodes(observedVnodes, roots: roots) {
        if resources[identity] == nil { files += 1 }
        resources[identity] = max(resources[identity] ?? 0, bytes)
    }
    return usage(
        resources: resources,
        files: files,
        byteLimit: byteLimit,
        fileLimit: fileLimit
    )
}

private func fingerprint(
    request: BpyRunJobRequest,
    timeoutSeconds: Int,
    inputs: [String: (UInt64, String)]
) -> String {
    BpyJobFingerprintV5.compute(expectedRevision: request.expectedRevision, source: request.source,
        requestedTimeout: request.timeoutSeconds, effectiveTimeout: timeoutSeconds,
        inputs: request.inputNames.map { .init(name: $0, byteCount: inputs[$0]?.0 ?? UInt64.max, sha256: inputs[$0]?.1 ?? "") },
        deniedPaths: request.diagnosticDeniedPaths, autoexecControl: request.diagnosticAutoexecPositiveControl,
        identityWriteFailure: request.diagnosticSupervisorIdentityWriteFailure,
        identityCaptureFailure: request.diagnosticSupervisorIdentityCaptureFailure)
}

private final class ResponseCallback: @unchecked Sendable {
    let body: (Data) -> Void

    init(_ body: @escaping (Data) -> Void) {
        self.body = body
    }
}

private final class BoundedLog: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ value: Data) {
        lock.access {
            let remaining = max(0, limit - data.count)
            data.append(value.prefix(remaining))
        }
    }

    var text: String {
        lock.access { String(decoding: data, as: UTF8.self) }
    }
}

private final class UploadRecord {
    let url: URL
    let totalBytes: UInt64
    let expectedSHA256: String
    let handle: FileHandle
    var receivedBytes: UInt64 = 0
    var failed = false
    private var isOpen = true

    init(url: URL, totalBytes: UInt64, expectedSHA256: String, handle: FileHandle) {
        self.url = url
        self.totalBytes = totalBytes
        self.expectedSHA256 = expectedSHA256
        self.handle = handle
    }

    static func create(url: URL, totalBytes: UInt64, expectedSHA256: String) throws -> UploadRecord {
        let parent = try BpyStoragePaths.openDirectory(url.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        let descriptor = openat(parent, url.lastPathComponent, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return .init(url: url, totalBytes: totalBytes, expectedSHA256: expectedSHA256,
            handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }

    func remove() throws {
        failed = true
        try close()
        try FileManager.default.removeItem(at: url)
    }

    func close() throws {
        guard isOpen else { return }
        try handle.close()
        isOpen = false
    }
}

private final class JobRecord: @unchecked Sendable {
    let id: UUID
    var source: String?
    let expectedRevision: String?
    let inputNames: [String]
    let timeoutSeconds: Int
    let fingerprint: String
    let admission: UUID?
    let admissionDeadline: TimeInterval?
    var terminalProcess: BpyRemoteProcess?
    var processAuthorizations = BpyProcessAuthorizations()
    var terminalCommit: TimeInterval?
    var firstRelease: TimeInterval?
    var runningDeadline: TimeInterval?
    let diagnosticDeniedPaths: [String]
    let diagnosticAutoexecPositiveControl: Bool
    var state: BpyRuntimeJobState = .accepted
    var message: String?
    var progress: [BpyRuntimeProgress] = []
    var outputs: [BpyOutputDescriptor] = []
    var outputFiles: [String: BpyRuntimeFile] = [:]
    var outputReservation: UInt64 = 0
    var candidateScene: BpyRuntimeFile?
    var releasedOutputs: [BpyOutputDescriptor]?
    var bootstrap: BpyRuntimeFile?
    var stdout: String?
    var metrics: [String: Double] = [:]
    var terminalAt: Date?
    var resultExpired = false
    let diagnosticSupervisorIdentityWriteFailure: Bool
    let diagnosticSupervisorIdentityCaptureFailure: Bool

    init(request: BpyRunJobRequest, timeoutSeconds: Int) {
        id = request.jobID
        source = request.source
        expectedRevision = request.expectedRevision
        inputNames = request.inputNames
        self.timeoutSeconds = timeoutSeconds
        fingerprint = request.fingerprint
        admission = request.admission
        admissionDeadline = request.admissionDeadline
        diagnosticDeniedPaths = request.diagnosticDeniedPaths
        diagnosticAutoexecPositiveControl = request.diagnosticAutoexecPositiveControl
        diagnosticSupervisorIdentityWriteFailure = request.diagnosticSupervisorIdentityWriteFailure
        diagnosticSupervisorIdentityCaptureFailure = request.diagnosticSupervisorIdentityCaptureFailure
    }

    func expireResult() {
        if releasedOutputs == nil { releasedOutputs = outputs }
        outputs.removeAll()
        for file in outputFiles.values { file.release() }
        outputFiles.removeAll()
        candidateScene?.release(); candidateScene = nil
        outputReservation = 0
        progress.removeAll()
        stdout = nil
        metrics.removeAll()
        resultExpired = true
    }
}

private struct ProbeManifest: Decodable {
    let schema: String
    let pythonVersion: String
    let bpyVersion: String
    let bpyModule: String
    let executable: String
    let processIdentifier: Int32
    let startupSeconds: Double
}

private struct VerificationScene: Codable {
    let name: String
    let width: Int
    let height: Int
    let percentage: Int
    let pixels: Int
    let engine: String
    let cyclesDevice: String?
}

private struct DenialResult: Codable {
    let denied: Bool
    let errno: Int?

    var isPermissionDenial: Bool { denied && [Int(EPERM), Int(EACCES)].contains(errno ?? 0) }
}

private struct RuntimeLibraryVersion: Codable {
    let supported: Bool
    let version: [Int]
    let versionString: String
}

private struct VerificationManifest: Codable {
    let schema: String
    let jobID: String
    let fingerprint: String
    let pythonVersion: String
    let bpyVersion: String
    let executable: String
    let bpyModule: String
    let processIdentifier: Int32
    let verificationSeconds: Double
    let objects: Int
    let vertices: Int
    let polygons: Int
    let scenes: [VerificationScene]
    let objectNames: [String]
    let modifiers: [String: [String]]
    let autorunTextPresent: Bool
    let autorunMarkerAbsent: Bool
    let deniedPaths: [String: DenialResult]
    let networkDenied: DenialResult?
    let secretEnvironmentAbsent: Bool
    let blenderUserConfig: String?
    let sessionRoot: String
    let blenderBuildHash: String
    let blenderBuildBranch: String
    let blenderBuildType: String
    let blenderBuildSystem: String
    let libraryVersions: [String: RuntimeLibraryVersion]
    let spatial: BpySpatialSnapshot?
    let sceneSHA256: String
}

private struct AutoexecManifest: Decodable {
    let schema: String
    let jobID: String
    let processIdentifier: Int32
    let autorunMarkerPresent: Bool
}

private struct SupervisorChildPID: Decodable {
    let processIdentifier: Int32
}

private typealias SupervisorWorkerIdentity = BpySupervisorWorkerIdentity

private struct ManagedProcessResult {
    let workerProcessIdentifier: Int32
    let exitStatus: Int32
    let terminationSignal: Int32?
    let duration: Double
    let peakMemoryBytes: UInt64
    let peakDiskBytes: UInt64
    let peakFileCount: Int
    let peakDescendantCount: Int
    let hostMonitorSamples: Int
    let limitReason: String?
    let log: String
    let terminal: BpyRemoteProcess
}

private struct ProbeIdentityFailure: Error {
    let field: String
    let observed: String
    let expected: String
}

private func requireProbeIdentity<Value: Equatable>(_ observed: Value, _ expected: Value, field: String) throws {
    guard observed == expected else {
        throw ProbeIdentityFailure(field: field, observed: String(reflecting: observed),
            expected: String(reflecting: expected))
    }
}

private struct ProbeFailure: Error {
    let response: BpyServiceResponse

    init(stage: String, result: ManagedProcessResult, cause: Error, maximumLogBytes: Int) {
        let error = cause as NSError
        let launchStage = result.terminal.launchStage
        let identity = cause as? ProbeIdentityFailure
        let failureStage = identity.map { "identity.\($0.field)" } ?? stage
        var header = "probe stage=\(failureStage) launchStage=\(launchStage.map { String(describing: $0) } ?? "unknown") exit=\(result.exitStatus) signal=\(result.terminationSignal ?? -1) supervisorPID=\(result.terminal.supervisor.pid) stop=\(result.limitReason ?? result.terminal.stopReason ?? "none") domain=\(error.domain) code=\(error.code)"
        if let identity { header += " observed=\(identity.observed) expected=\(identity.expected)" }
        let maximum = min(maximumLogBytes, 65_536)
        let prefix = boundedLogText(header + "\n", bytes: maximum)
        let output = prefix + boundedLogTailText(result.log, bytes: maximum - prefix.utf8.count)
        response = .init(ok: false, message: "The bundled 3D worker could not start (\(failureStage)).",
            stdout: output, metrics: [
                "probe.exitStatus": Double(result.exitStatus),
                "probe.terminationSignal": Double(result.terminationSignal ?? -1),
                "probe.supervisorPID": Double(result.terminal.supervisor.pid),
                "probe.workerPID": Double(result.workerProcessIdentifier),
                "probe.servicePID": Double(getpid()),
                "probe.launchStage": Double(launchStage?.rawValue ?? -1),
                "probe.errorCode": Double(error.code),
                "probe.duration": result.duration,
                "probe.logBytes": Double(result.terminal.logByteCount),
                "probe.logTruncated": output.utf8.count < header.utf8.count + 1 + result.log.utf8.count ? 1 : 0,
            ])
    }
}

private typealias BoundaryChildReport = BpyBoundaryChildReport

private let boundaryResourceModes: Set<String> = [
    "open-unlinked-hold",
    "readonly-unlinked-hold",
    "mapped-unlinked-hold",
    "external-readonly-hold",
    "internal-linked-writable-hold",
    "fileport-unlinked-hold",
]
private let boundaryProbeResourceBytes: UInt64 = 1_024 * 1_024
private let boundaryInternalResourceBytes: UInt64 = 128 * 1_024

private struct BoundarySupervisorIdentity: Decodable {
    let supervisorProcessIdentifier: Int32
    let supervisorParentProcessIdentifier: Int32
    let supervisorStartAbsoluteTime: UInt64
    let childProcessIdentifier: Int32
}

private typealias BoundaryRun = BpyBoundaryRun

private func runBoundarySupervisor(
    request: BpyBoundaryProbeRequest, storage: BpyServiceStoragePair,
    monitor: BpyServiceMonitor
) throws -> BoundaryRun {
    let mode = request.mode.rawValue
    let writeRoot = storage.workerRoot.appendingPathComponent("boundary/" + mode)
    let configuration = storage.dataRoot.appendingPathComponent("boundary.json")
    try FileManager.default.createDirectory(at: writeRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: storage.dataRoot, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: configuration, options: .atomic)
    var readFiles: [String] = []
    if request.mode == .externalReadonly {
        let external = storage.dataRoot.appendingPathComponent("external-readonly.bin")
        try Data(repeating: 0x4e, count: 1_024 * 1_024).write(to: external, options: .atomic)
        readFiles.append(request.nonce.uuidString + "/external-readonly.bin")
    }
    guard let service = processUsage(getpid()) else { throw POSIXError(.EIO) }
    let process = try monitor.start(spec: .init(permit: request.admission, job: nil, mode: .boundary,
        workerLease: request.storagePair.worker.id, dataLease: request.storagePair.data.id,
        workerRoot: request.nonce.uuidString + "/boundary/" + mode,
        configuration: request.nonce.uuidString + "/boundary.json", configurationSHA256: try sha256(configuration),
        readFiles: readFiles, boundary: request.mode),
        execution: request.execution, serviceStart: service.startAbsoluteTime, maximumOutputBytes: 65_536,
        deadline: request.admissionDeadline, cancelled: { false })
    var detached = false
    defer {
        if !detached {
            do { _ = try process.terminateAndReap(); _ = try process.detach() }
            catch { openDiagnostics.error("boundary.cleanup-pending code=\((error as NSError).code, privacy: .public)") }
        }
    }
    let supervisorPID = process.supervisor.pid
    let supervisorStart = process.supervisor.start
    var observedChild: SupervisorWorkerIdentity?
    var report: BoundaryChildReport?
    let readyDeadline = try BpyRuntimeClock.awakeSeconds() + 5
    while try BpyRuntimeClock.awakeSeconds() < readyDeadline {
        let sample = try process.sample()
        if let child = sample.worker {
            observedChild = .init(processIdentifier: child.pid, startAbsoluteTime: child.start)
        }
        if let data = try? Data(contentsOf: writeRoot.appendingPathComponent("child.json")) {
            report = try JSONDecoder().decode(BoundaryChildReport.self, from: data)
        }
        if observedChild != nil, report != nil { break }
        if sample.status == .gone { break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard let report, let child = observedChild,
          report.schema == "nexgenvideo/bpy-boundary-child/2", report.mode == mode,
          report.processIdentifier == child.processIdentifier,
          report.parentProcessIdentifier == supervisorPID else { throw POSIXError(.EPERM) }
    if mode == "denials" {
        try Data("observed".utf8).write(to: writeRoot.appendingPathComponent("service-observed"), options: .atomic)
    }
    var observedRetainedBytes: UInt64 = 0
    var limitReason: String?
    var internalLinkedWritableDeduplicated = false
    var retentionDenied = false
    if boundaryResourceModes.contains(mode) {
        let sample = try process.sample()
        guard let worker = sample.worker, worker.pid == child.processIdentifier,
              worker.start == child.startAbsoluteTime else { throw CocoaError(.executableLoad) }
        let retainedResources = try ownedRetainedVnodes(sample.vnodes, roots: [writeRoot])
        observedRetainedBytes = retainedResources.values.reduce(0, +)
        let named = try directoryUsage(
            [writeRoot],
            byteLimit: 512 * 1_024,
            fileLimit: 64
        )
        let quota = try resourceUsage(
            roots: [writeRoot],
            observedVnodes: sample.vnodes,
            byteLimit: 512 * 1_024,
            fileLimit: 64
        )
        limitReason = quota.limitReason
        let validResourceResult: Bool
        if mode == "external-readonly-hold" {
            validResourceResult = report.resourceBytes == boundaryProbeResourceBytes
                && observedRetainedBytes < boundaryProbeResourceBytes
                && limitReason == nil
        } else if mode == "internal-linked-writable-hold" {
            let overlap = retainedResources.keys.filter { named.resources[$0] != nil }
            internalLinkedWritableDeduplicated = report.resourceBytes
                == boundaryInternalResourceBytes
                && retainedResources.count == 1
                && overlap.count == 1
                && observedRetainedBytes >= boundaryInternalResourceBytes
                && quota.files == named.files
                && limitReason == nil
            validResourceResult = internalLinkedWritableDeduplicated
        } else if mode == "fileport-unlinked-hold" {
            retentionDenied = [EPERM, EACCES].contains(report.retentionDeniedErrno)
            validResourceResult = report.resourceBytes == boundaryProbeResourceBytes
                && (retentionDenied || (observedRetainedBytes >= boundaryProbeResourceBytes && limitReason == "disk"))
        } else {
            validResourceResult = report.resourceBytes == boundaryProbeResourceBytes
                && observedRetainedBytes >= boundaryProbeResourceBytes
                && limitReason == "disk"
        }
        guard validResourceResult else { throw CocoaError(.fileReadTooLarge) }
        try process.signal(SIGTERM)
        _ = try process.waitUntilExit(timeout: 3)
    } else {
        guard try process.waitUntilExit(timeout: 5) == 0 else { throw CocoaError(.executableLoad) }
    }
    let final = try process.detach()
    detached = true
    let childGone = final.ended.contains { $0.pid == child.processIdentifier && $0.start == child.startAbsoluteTime }
    let supervisorGone = final.ended.contains { $0.pid == supervisorPID && $0.start == supervisorStart }
    guard childGone, supervisorGone else { throw CocoaError(.executableLoad) }
    return .init(
        supervisorProcessIdentifier: supervisorPID,
        supervisorParentProcessIdentifier: process.supervisor.parent,
        supervisorStartAbsoluteTime: supervisorStart,
        child: child,
        report: report,
        supervisorGone: supervisorGone,
        childGone: childGone,
        observedRetainedBytes: observedRetainedBytes,
        limitReason: limitReason,
        internalLinkedWritableDeduplicated: internalLinkedWritableDeduplicated,
        retentionDenied: retentionDenied
    )
}

private final class ServiceSession: @unchecked Sendable {
    let request: BpyOpenSessionRequest
    private let root: URL
    private let runtimeRoot: URL
    private let monitor: BpyServiceMonitor
    private let capacity: DispatchSemaphore
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var uploads: [String: UploadRecord] = [:]
    private var checkpointUpload: UploadRecord?
    private var completedInputs: [UUID: [String: (UInt64, String)]] = [:]
    private var jobs: [UUID: JobRecord] = [:]
    private var abandonedInputs = Set<UUID>()
    private var stagingCleanup = Set<UUID>()
    private var logOrder: [UUID] = []
    private var executingJob: UUID?
    private var confirmedRevision: String?
    private var confirmedSceneFile: BpyRuntimeFile?
    private var outputReaders = 0
    private let outputLedger: BpyServiceOutputLedger
    private let manifestBudget: BpyManifestReadBudget
    private struct PendingCleanup {
        let process: BpyRemoteProcess
    }
    private let cleanupLock = NSLock()
    private let closeLock = NSLock()
    private var storageCleanupDeadline: TimeInterval?
    private var pendingCleanup: PendingCleanup?
    private var activeProcess: BpyRemoteProcess?
    private var activeProcessStartAbsoluteTime: UInt64?
    private var activeProcessExecutable: String?
    private var activeProcessJobID: UUID?
    private var activeProcessAuthorizationID: UUID?
    private var activeProcessAuthorized = false
    private var activeWorkerProcessIdentifier: Int32?
    private var runtimeIdentity: BpyRuntimeIdentity?
    private var coldStartSeconds: Double?
    private var servicePeakMemoryBytes: UInt64 = 0
    private var closed = false
    private let storageAccess: BpyServiceStoragePair
    private let workerRoot: URL
    private let queueKey = DispatchSpecificKey<UInt8>()

    init(
        request: BpyOpenSessionRequest,
        root: URL,
        runtimeRoot: URL,
        monitor: BpyServiceMonitor,
        capacity: DispatchSemaphore,
        storageAccess: BpyServiceStoragePair
    ) {
        self.storageAccess = storageAccess
        outputLedger = .init(capacity: request.limits.retainedOutputBytes ?? 0)
        manifestBudget = .init(capacity: request.limits.outputBytes)
        self.workerRoot = storageAccess.workerRoot
        self.request = request
        self.root = root
        self.runtimeRoot = runtimeRoot
        self.monitor = monitor
        self.capacity = capacity
        confirmedRevision = request.confirmedRevision
        queue = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.\(request.sessionID.uuidString)")
        queue.setSpecific(key: queueKey, value: 1)
    }

    func open(reply: @escaping (Data) -> Void) {
        let callback = ResponseCallback(reply)
        queue.async { [self] in
            do {
                guard lock.access({ !closed }) else { throw CocoaError(.fileNoSuchFile) }
                if lock.access({ runtimeIdentity != nil }) {
                    callback.body(encoded(readyResponse()))
                    return
                }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: workerRoot, withIntermediateDirectories: true)
                guard !request.diagnosticOpenFailure else { throw CocoaError(.executableLoad) }
                let started = ProcessInfo.processInfo.systemUptime
                let manifest = try probeRuntime()
                coldStartSeconds = ProcessInfo.processInfo.systemUptime - started
                let installed = lock.access { () -> Bool in
                    guard !closed else { return false }
                    runtimeIdentity = .init(
                        pythonVersion: manifest.pythonVersion,
                        bpyVersion: manifest.bpyVersion,
                        executable: manifest.executable,
                        processIdentifier: manifest.processIdentifier,
                        serviceProcessIdentifier: getpid()
                    )
                    return true
                }
                guard installed else { throw CocoaError(.fileNoSuchFile) }
                callback.body(encoded(readyResponse()))
            } catch {
                stopActiveProcess()
                callback.body((error as? ProbeFailure).map { encoded($0.response) }
                    ?? failure("worker did not become ready: \(error.localizedDescription)"))
            }
        }
    }

    func matches(_ candidate: BpyOpenSessionRequest) -> Bool {
        request == candidate
    }

    func restore(_ request: BpyRestoreCheckpointRequest, chunk: Data) throws {
        guard isSafeName(request.revision),
              isSHA256(request.sha256),
              request.totalBytes <= self.request.limits.inputBytes,
              chunk.count <= 4 * 1_024 * 1_024,
              request.offset <= request.totalBytes,
              UInt64(chunk.count) <= request.totalBytes - request.offset,
              request.finalChunk == (
                  request.offset + UInt64(chunk.count) == request.totalBytes
              ) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try lock.access {
            guard !closed, confirmedRevision == request.revision else { throw CocoaError(.fileWriteNoPermission) }
            if let file = confirmedSceneFile {
                guard file.byteCount == request.totalBytes, file.sha256 == request.sha256,
                      try file.read(offset: request.offset, maximum: chunk.count) == chunk else {
                    throw CocoaError(.fileWriteFileExists)
                }
                return
            }
            let upload: UploadRecord
            if let existing = checkpointUpload {
                upload = existing
                guard upload.totalBytes == request.totalBytes,
                      upload.expectedSHA256 == request.sha256 else {
                    throw CocoaError(.fileWriteFileExists)
                }
            } else {
                guard request.offset == 0 else { throw CocoaError(.fileWriteUnknown) }
                let url = root.appendingPathComponent("host-checkpoint.part")
                upload = try UploadRecord.create(url: url, totalBytes: request.totalBytes, expectedSHA256: request.sha256)
                checkpointUpload = upload
            }
            do {
                try append(chunk, offset: request.offset, finalChunk: request.finalChunk, to: upload)
                if request.finalChunk {
                    let file = try retainFile(from: upload.url, to: root.appendingPathComponent("confirmed/" + UUID().uuidString + ".blend"),
                        maximum: self.request.limits.inputBytes, expectedSHA256: upload.expectedSHA256)
                    guard file.byteCount == upload.totalBytes,
                          BpyBlendFileFormat.accepts(try file.read(maximum: 64)) else { throw CocoaError(.fileReadCorruptFile) }
                    confirmedSceneFile = file
                    try upload.remove()
                    checkpointUpload = nil
                }
            } catch {
                if (try? upload.remove()) != nil { checkpointUpload = nil }
                throw error
            }
        }
    }

    func stage(_ request: BpyStageInputRequest, chunk: Data) throws {
        guard isSafeName(request.name), isSHA256(request.sha256),
              request.totalBytes <= self.request.limits.inputBytes,
              chunk.count <= 4 * 1_024 * 1_024,
              request.offset <= request.totalBytes,
              UInt64(chunk.count) <= request.totalBytes - request.offset,
              request.finalChunk == (
                  request.offset + UInt64(chunk.count) == request.totalBytes
              ) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try lock.access {
            guard !closed, !abandonedInputs.contains(request.jobID), executingJob == nil else { throw CocoaError(.fileWriteNoPermission) }
            retryStagingCleanup()
            guard stagingCleanup.isEmpty else { throw CocoaError(.fileWriteUnknown) }
            if let completed = completedInputs[request.jobID]?[request.name] {
                guard completed.0 == request.totalBytes, completed.1 == request.sha256 else {
                    throw CocoaError(.fileWriteFileExists)
                }
                return
            }
            guard jobs[request.jobID] == nil,
                  !jobs.values.contains(where: {
                      [.accepted, .running, .awaitingConfirmation].contains($0.state)
                  }) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let key = "\(request.jobID.uuidString)/\(request.name)"
            let upload: UploadRecord
            if let existing = uploads[key] {
                upload = existing
                guard upload.totalBytes == request.totalBytes,
                      upload.expectedSHA256 == request.sha256 else {
                    throw CocoaError(.fileWriteFileExists)
                }
            } else {
                guard request.offset == 0 else { throw CocoaError(.fileWriteUnknown) }
                let completedTotal = completedInputs.values.flatMap { $0.values }.reduce(UInt64(0)) { $0 + $1.0 }
                let uploadingTotal = uploads.values.reduce(UInt64(0)) { $0 + $1.totalBytes }
                let completedCount = completedInputs.values.reduce(0) { $0 + $1.count }
                guard completedCount + uploads.count < min(64, self.request.limits.files),
                      completedTotal <= self.request.limits.inputBytes,
                      uploadingTotal <= self.request.limits.inputBytes - completedTotal,
                      request.totalBytes <= self.request.limits.inputBytes - completedTotal - uploadingTotal else {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                let directory = inputDirectory(request.jobID)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let incoming = jobDirectory(request.jobID).appendingPathComponent(".uploads", isDirectory: true)
                try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
                let url = incoming.appendingPathComponent(UUID().uuidString + ".part")
                upload = try UploadRecord.create(url: url, totalBytes: request.totalBytes, expectedSHA256: request.sha256)
                uploads[key] = upload
            }
            do {
                try append(chunk, offset: request.offset, finalChunk: request.finalChunk, to: upload)
                if request.finalChunk {
                    let finalURL = inputDirectory(request.jobID).appendingPathComponent(request.name)
                    try FileManager.default.moveItem(at: upload.url, to: finalURL)
                    uploads.removeValue(forKey: key)
                    completedInputs[request.jobID, default: [:]][request.name] = (request.totalBytes, request.sha256)
                }
            } catch {
                if (try? upload.remove()) != nil { uploads.removeValue(forKey: key) }
                throw error
            }
        }
    }

    private func append(
        _ chunk: Data,
        offset: UInt64,
        finalChunk: Bool,
        to upload: UploadRecord
    ) throws {
        guard !upload.failed else { throw CocoaError(.fileWriteNoPermission) }
        if offset < upload.receivedBytes {
            guard offset + UInt64(chunk.count) <= upload.receivedBytes else {
                throw CocoaError(.fileWriteUnknown)
            }
            var existing = Data(count: chunk.count)
            try existing.withUnsafeMutableBytes { bytes in
                var received = 0
                while received < chunk.count {
                    let count = pread(upload.handle.fileDescriptor, bytes.baseAddress!.advanced(by: received), chunk.count - received, off_t(offset) + off_t(received))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    received += count
                }
            }
            guard existing == chunk else {
                throw CocoaError(.fileWriteFileExists)
            }
            return
        }
        guard offset == upload.receivedBytes,
              upload.receivedBytes + UInt64(chunk.count) <= upload.totalBytes else {
            throw CocoaError(.fileWriteUnknown)
        }
        try upload.handle.write(contentsOf: chunk)
        upload.receivedBytes += UInt64(chunk.count)
        if finalChunk {
            try upload.handle.synchronize()
            try upload.close()
            guard upload.receivedBytes == upload.totalBytes,
                  try sha256(upload.url) == upload.expectedSHA256 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    func submit(_ request: BpyRunJobRequest) -> BpyServiceResponse {
        let decision: (JobRecord?, BpyServiceResponse) = lock.access {
            if closed {
                return (nil, .init(ok: false, message: "session is closed"))
            }
            guard request.admission != nil, request.admissionDeadline?.isFinite == true,
                  isSHA256(request.fingerprint) else {
                return (nil, .init(ok: false, message: "invalid job fingerprint"))
            }
            if let existing = jobs[request.jobID] {
                guard existing.fingerprint == request.fingerprint else {
                    return (nil, .init(ok: false, message: "job ID payload mismatch"))
                }
                var response = response(for: existing)
                response.joinedExistingJob = true
                return (nil, response)
            }
            retryStagingCleanup()
            guard stagingCleanup.isEmpty else { return (nil, .init(ok: false, message: "3D storage cleanup is pending. Retry after cleanup finishes.")) }
            guard !abandonedInputs.contains(request.jobID), jobs.count + abandonedInputs.count < 1_024 else {
                return (nil, .init(ok: false, message: "session job limit reached; rotate the document session"))
            }
            guard !jobs.values.contains(where: {
                [.accepted, .running, .awaitingConfirmation].contains($0.state)
            }) else {
                return (nil, .init(ok: false, message: "session already has an active job"))
            }
            guard request.expectedRevision == confirmedRevision,
                  confirmedRevision == nil || confirmedSceneFile != nil else {
                return (nil, .init(ok: false, message: "confirmed checkpoint is unavailable"))
            }
            let names = Set(request.inputNames)
            let inputs = completedInputs[request.jobID, default: [:]]
            guard names.count == request.inputNames.count, names.count <= 64,
                  request.inputNames.allSatisfy(isSafeName),
                  !uploads.keys.contains(where: { $0.hasPrefix(request.jobID.uuidString + "/") }),
                  names == Set(inputs.keys) else {
                return (nil, .init(ok: false, message: "staged inputs do not match the request"))
            }
            guard request.source.utf8.count <= 4 * 1_024 * 1_024,
                  request.diagnosticDeniedPaths.count <= 8,
                  Set(request.diagnosticDeniedPaths).count == request.diagnosticDeniedPaths.count,
                  request.diagnosticDeniedPaths.allSatisfy({
                      $0.hasPrefix("/") && !$0.utf8.contains(0) && $0.utf8.count <= 4_096
                  }) else {
                return (nil, .init(ok: false, message: "job payload exceeds the runtime limit"))
            }
            let timeout = min(
                request.timeoutSeconds ?? self.request.limits.timeoutSeconds,
                self.request.limits.timeoutSeconds
            )
            guard timeout > 0,
                  fingerprint(request: request, timeoutSeconds: timeout, inputs: inputs)
                    == request.fingerprint else {
                return (nil, .init(ok: false, message: "job fingerprint mismatch"))
            }
            do { try outputLedger.reserve(request.jobID, maximum: self.request.limits.outputBytes) }
            catch { return (nil, .init(ok: false, message: "release retained results before another job")) }
            let job = JobRecord(request: request, timeoutSeconds: timeout)
            job.outputReservation = self.request.limits.outputBytes
            jobs[request.jobID] = job
            return (job, response(for: job))
        }
        if let job = decision.0 {
            queue.async { [self] in execute(job) }
        }
        return decision.1
    }

    func status(_ jobID: UUID) -> BpyServiceResponse {
        lock.access {
            guard let job = jobs[jobID] else {
                return .init(ok: false, message: "unknown job")
            }
            return response(for: job)
        }
    }

    func authorize(_ request: BpyAuthorizeProcessRequest) throws -> BpyServiceResponse {
        try lock.access {
            guard !closed,
                  let job = jobs[request.jobID] else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let active = activeProcessJobID == request.jobID ? activeProcessAuthorizationID : nil
            if try job.processAuthorizations.acknowledge(request, active: active) {
                activeProcessAuthorized = true
            }
            return response(for: job)
        }
    }

    func output(_ request: BpyReadOutputRequest) throws -> (BpyServiceResponse, Data) {
        guard isSafeName(request.name), request.maximumBytes > 0,
              request.maximumBytes <= 4 * 1_024 * 1_024 else { throw CocoaError(.fileReadInvalidFileName) }
        let read: (BpyRuntimeFile, BpyServiceResponse) = try lock.access {
            guard !closed, outputReaders < 2, let job = jobs[request.jobID], !job.resultExpired,
                  [.awaitingConfirmation, .confirmed].contains(job.state),
                  let descriptor = job.outputs.first(where: { $0.name == request.name }),
                  let file = job.outputFiles[request.name], file.byteCount == descriptor.byteCount,
                  file.sha256 == descriptor.sha256, request.offset <= file.byteCount else { throw CocoaError(.fileReadNoSuchFile) }
            let owner = try file.retained()
            outputReaders += 1
            return (owner, response(for: job))
        }
        defer { read.0.release(); lock.access { outputReaders -= 1 } }
        return (read.1, try read.0.read(offset: request.offset, maximum: request.maximumBytes))
    }

    func releaseResources(_ request: BpyReleaseResourcesRequest) throws -> BpyServiceResponse {
        try lock.access {
            guard !closed else { throw CocoaError(.fileWriteNoPermission) }
            if request.disposition == .stagedInputs {
                guard jobs[request.jobID] == nil, abandonedInputs.contains(request.jobID)
                    || jobs.count + abandonedInputs.count < 1_024 else { throw CocoaError(.fileWriteNoPermission) }
                abandonedInputs.insert(request.jobID)
                let prefix = request.jobID.uuidString + "/"
                for key in uploads.keys where key.hasPrefix(prefix) { try? uploads[key]?.handle.close() }
                do { try FileManager.default.removeItem(at: jobDirectory(request.jobID)) }
                catch let error as CocoaError where error.code == .fileNoSuchFile { }
                uploads = uploads.filter { !$0.key.hasPrefix(prefix) }
                completedInputs.removeValue(forKey: request.jobID)
                return .init(ok: true, jobID: request.jobID)
            }
            guard let job = jobs[request.jobID], request.fingerprint == job.fingerprint,
                  request.outputs == (job.releasedOutputs ?? job.outputs),
                  ![.accepted, .running].contains(job.state) else { throw CocoaError(.fileWriteNoPermission) }
            if job.releasedOutputs == nil { job.releasedOutputs = job.outputs }
            try outputLedger.updateCheckpoint(job.id, resultScene: job.outputFiles["scene.blend"],
                confirmedScene: confirmedSceneFile, change: .release)
            if request.disposition == .transferredResult {
                if job.state == .awaitingConfirmation, job.candidateScene == nil {
                    job.candidateScene = try job.outputFiles["scene.blend"]?.retained()
                }
                for file in job.outputFiles.values { file.release() }
                job.outputFiles.removeAll(); job.outputReservation = 0
            } else {
                if job.state == .awaitingConfirmation { job.state = .rejected }
                job.expireResult()
            }
            let checkpointBytes = job.candidateScene.map { outputLedger.chargedBytes(job.id, file: $0) } ?? 0
            guard outputLedger.materialized(job.id) <= checkpointBytes else {
                return .init(ok: false, jobID: job.id, message: "result release pending")
            }
            return response(for: job)
        }
    }

    func confirm(_ request: BpyConfirmJobRequest) throws -> BpyServiceResponse {
        guard isSafeName(request.revision), isSHA256(request.sceneSHA256) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return try lock.access {
            guard !closed else { throw CocoaError(.fileWriteNoPermission) }
            if let job = jobs[request.jobID], job.state == .confirmed,
               confirmedRevision == request.revision, let file = confirmedSceneFile,
               file.sha256 == request.sceneSHA256 { return response(for: job) }
            guard let job = jobs[request.jobID], job.state == .awaitingConfirmation,
                  !job.resultExpired else {
                throw CocoaError(.fileWriteNoPermission)
            }
            guard request.revision != confirmedRevision,
                  let confirmedFile = job.candidateScene ?? job.outputFiles["scene.blend"],
                  confirmedFile.byteCount <= self.request.limits.inputBytes,
                  confirmedFile.sha256 == request.sceneSHA256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let replacement = try confirmedFile.retained()
            do {
                try outputLedger.updateCheckpoint(job.id, resultScene: job.outputFiles["scene.blend"],
                    confirmedScene: replacement, change: .confirm)
            }
            catch { replacement.release(); throw error }
            confirmedSceneFile?.release()
            confirmedRevision = request.revision
            confirmedSceneFile = replacement
            job.candidateScene?.release(); job.candidateScene = nil
            job.state = .confirmed
            job.terminalAt = Date()
            return response(for: job)
        }
    }

    func cancel(_ jobID: UUID) -> BpyServiceResponse {
        let shouldStop = lock.access { () -> Bool in
            guard !closed else { return false }
            let prefix = jobID.uuidString + "/"
            func discardStaging() {
                for key in Array(uploads.keys) where key.hasPrefix(prefix) {
                    if let upload = uploads.removeValue(forKey: key) { try? upload.handle.close() }
                }
                completedInputs.removeValue(forKey: jobID)
            }
            guard let job = jobs[jobID] else {
                if completedInputs[jobID] != nil || uploads.keys.contains(where: { $0.hasPrefix(prefix) }) {
                    abandonedInputs.insert(jobID)
                    for key in uploads.keys where key.hasPrefix(prefix) { try? uploads[key]?.handle.close() }
                    do {
                        try FileManager.default.removeItem(at: jobDirectory(jobID))
                        discardStaging()
                    } catch let error as CocoaError where error.code == .fileNoSuchFile { discardStaging() }
                    catch { closed = true }
                }
                return false
            }
            switch job.state {
            case .accepted, .running:
                job.state = .cancelled
                job.message = "job cancelled"
                job.source = nil
                job.terminalAt = Date()
                discardStaging()
                return true
            case .awaitingConfirmation:
                job.state = .rejected
                job.message = "candidate rejected"
                job.terminalAt = Date()
                job.expireResult()
                discardStaging()
                try? FileManager.default.removeItem(at: jobDirectory(jobID))
                return false
            default:
                return false
            }
        }
        if shouldStop {
            if stopActiveProcess(jobID: jobID) {
                if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
                lock.access { if !closed { try? FileManager.default.removeItem(at: jobDirectory(jobID)) } }
            }
        }
        return status(jobID)
    }

    func close() -> Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        lock.access { closed = true }
        guard stopActiveProcess() else { return false }
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync { } }
        lock.access {
            for upload in uploads.values { try? upload.handle.close() }
            try? checkpointUpload?.handle.close()
            uploads.removeAll()
            checkpointUpload = nil
            for job in jobs.values { job.bootstrap?.release(); job.bootstrap = nil; job.expireResult(); outputLedger.settle(job.id) }
            confirmedSceneFile?.release(); confirmedSceneFile = nil
        }
        if storageCleanupDeadline == nil { storageCleanupDeadline = BpyRuntimeClock.read().map { $0.awake + 3 } }
        while !storageAccess.beginClose() || lock.access({ outputReaders != 0 }) {
            guard let deadline = storageCleanupDeadline, let now = BpyRuntimeClock.read()?.awake, now < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: workerRoot)
        storageAccess.release()
        return true
    }

    private func execute(_ job: JobRecord) {
        capacity.wait()
        defer {
            let stopped = stopActiveProcess(jobID: job.id)
            lock.access {
                job.source = nil
                job.terminalProcess = nil
                logOrder.removeAll { $0 == job.id }; logOrder.append(job.id)
                while logOrder.count > 16 { jobs[logOrder.removeFirst()]?.stdout = nil }
                job.bootstrap?.release(); job.bootstrap = nil
                stagingCleanup.insert(job.id)
                if stopped { try? disposeJobStaging(job.id) }
                executingJob = nil
                if ![.awaitingConfirmation, .confirmed].contains(job.state) { job.outputReservation = 0 }
            }
            outputLedger.settle(job.id)
            capacity.signal()
        }
        guard let began = try? BpyRuntimeClock.awakeSeconds() else {
            lock.access {
                job.state = .failed
                job.message = "The 3D runtime clock is unavailable. Restart NexGenVideo before retrying."
                job.terminalAt = Date()
            }
            return
        }
        guard lock.access({
            guard job.state == .accepted, !closed else { return false }
            job.state = .running
            executingJob = job.id
            job.progress = [.init(sequence: 1, stage: "worker", fraction: 0.05)]
            return true
        }) else { return }
        do {
            let directory = jobDirectory(job.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sourceURL = directory.appendingPathComponent("source.py")
            guard let source = lock.access({ job.source }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try Data(source.utf8).write(to: sourceURL, options: .atomic)
            let confirmedURL = try writeConfirmedCheckpoint(for: job)
            let writableRoot = jobWorkerDirectory(job.id)
            var jobConfiguration = baseConfiguration(
                processRoot: writableRoot,
                cpuSeconds: job.timeoutSeconds
            ).merging([
                "jobID": job.id.uuidString,
                "sessionRoot": root.path,
                "workerRoot": workerRoot.path,
                "sourcePath": sourceURL.path,
                "inputDirectory": inputDirectory(job.id).path,
                "outputDirectory": outputDirectory(job.id).path,
                "limits": geometryLimits,
            ]) { _, new in new }
            if let confirmedURL { jobConfiguration["confirmedScene"] = confirmedURL.path }
            let jobConfig = try writeConfiguration(
                jobConfiguration,
                at: directory.appendingPathComponent("job.json")
            )
            let worker = try runManagedProcess(
                mode: "job",
                configuration: jobConfig,
                processRoot: writableRoot,
                job: job,
                injectSupervisorIdentityWriteFailure: job.diagnosticSupervisorIdentityWriteFailure,
                injectSupervisorIdentityCaptureFailure: job.diagnosticSupervisorIdentityCaptureFailure
            )
            try requireSuccessful(worker, job: job)
            try enforceStoredResources(job)
            try verifyStagedInputs(job.id)
            lock.access {
                guard job.state == .running else { return }
                job.progress.append(.init(sequence: 2, stage: "verification", fraction: 0.75))
            }
            let planned = try planOutputs(job.id)
            let plannedBytes = planned.reduce(UInt64(0)) { $0 + $1.1 }
            guard let manifestMaximum = BpyOutputContract.verificationReadMaximum(workerFileCount: planned.count, workerBytes: plannedBytes,
                fileLimit: request.limits.files, byteLimit: request.limits.outputBytes) else {
                throw CocoaError(.fileReadTooLarge)
            }
            let verification = try verify(job: job, manifestMaximum: manifestMaximum)
            try enforceStoredResources(job)
            guard let terminalProcess = lock.access({ job.terminalProcess }) else { throw POSIXError(.EIO) }
            _ = try terminalProcess.beginCollection()
            let collected = try collectOutputs(job.id)
            guard collected.files["scene.blend"]?.sha256 == verification.manifest.sceneSHA256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            observeServiceMemory()
            let verificationData = try JSONEncoder().encode(verification.manifest)
            let collectedBytes = collected.descriptors.reduce(UInt64(0)) { $0 + $1.byteCount }
            guard BpyOutputContract.permitsHostManifest(workerFileCount: collected.descriptors.count,
                workerBytes: collectedBytes, manifestBytes: UInt64(verificationData.count),
                fileLimit: request.limits.files, byteLimit: request.limits.outputBytes) else {
                throw CocoaError(.fileReadTooLarge)
            }
            var descriptors = collected.descriptors
            var outputFiles = collected.files
            descriptors.append(.init(
                name: "verification.json",
                byteCount: UInt64(verificationData.count),
                sha256: sha256(verificationData),
                mediaType: "application/json"
            ))
            outputFiles["verification.json"] = try retainFile(data: verificationData,
                to: root.appendingPathComponent("results/" + job.id.uuidString + "/verification.json"), maximum: request.limits.outputBytes, jobID: job.id)
            try lock.access {
                job.bootstrap?.release(); job.bootstrap = nil
                stagingCleanup.insert(job.id)
                try disposeJobStaging(job.id)
            }
            let commit = try terminalProcess.commit()
            guard let committedAt = commit.terminalCommit, let runningDeadline = commit.runningDeadline,
                  committedAt <= runningDeadline + 15, commit.stopReason == nil else { throw POSIXError(.ETIMEDOUT) }
            let wallSeconds = try BpyRuntimeClock.awakeSeconds() - began
            lock.access {
                job.terminalCommit = committedAt
                guard job.state == .running else { return }
                job.outputs = descriptors
                job.outputFiles = outputFiles
                job.outputReservation = descriptors.reduce(0) { $0 + $1.byteCount }
                job.stdout = boundedLogText(worker.log, bytes: request.limits.stdoutBytes)
                job.metrics = [
                    "job_wall_seconds": wallSeconds,
                    "worker_wall_seconds": worker.duration,
                    "verification_seconds": verification.manifest.verificationSeconds,
                    "worker_peak_memory_bytes": Double(worker.peakMemoryBytes),
                    "verifier_peak_memory_bytes": Double(verification.process.peakMemoryBytes),
                    "worker_host_monitor_samples": Double(worker.hostMonitorSamples),
                    "verifier_host_monitor_samples": Double(verification.process.hostMonitorSamples),
                    "service_peak_memory_bytes": Double(servicePeakMemoryBytes),
                    "physical_storage_capacity_bytes": Double(request.storagePair?.worker.capacityBytes ?? 0),
                    "data_storage_capacity_bytes": Double(request.storagePair?.data.capacityBytes ?? 0),
                    "disk_peak_bytes": Double(max(worker.peakDiskBytes, verification.process.peakDiskBytes)),
                    "file_peak_count": Double(max(worker.peakFileCount, verification.process.peakFileCount)),
                    "descendant_peak_count": Double(
                        max(worker.peakDescendantCount, verification.process.peakDescendantCount)
                    ),
                    "worker_process_identifier": Double(worker.workerProcessIdentifier),
                    "verifier_process_identifier": Double(verification.process.workerProcessIdentifier),
                    "objects": Double(verification.manifest.objects),
                    "vertices": Double(verification.manifest.vertices),
                    "polygons": Double(verification.manifest.polygons),
                    "system_pressure_policy_version": 1,
                ]
                if verification.autoexecPositive {
                    job.metrics["autoexec_positive_control"] = 1
                }
                job.progress.append(.init(sequence: 3, stage: "complete", fraction: 1))
                job.source = nil
                job.state = .awaitingConfirmation
                executingJob = nil
                job.terminalAt = Date()
                }
        } catch {
            lock.access {
                if job.state == .running {
                    let code = (error as? CocoaError)?.code
                    if code == .fileReadTooLarge || code == .fileWriteOutOfSpace {
                        job.state = .resourceLimited
                        job.message = "job exceeded a stored-resource limit"
                    } else {
                        job.state = .crashed
                        job.message = "worker failed: \(error.localizedDescription)"
                    }
                    job.source = nil
                    job.terminalAt = Date()
                }
            }
        }
    }

    private func disposeJobStaging(_ id: UUID) throws {
        let prefix = id.uuidString + "/"
        for (key, upload) in uploads where key.hasPrefix(prefix) { try upload.close() }
        for directory in [jobDirectory(id), workerRoot.appendingPathComponent("jobs/" + id.uuidString)] {
            do { try FileManager.default.removeItem(at: directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        }
        uploads = uploads.filter { !$0.key.hasPrefix(prefix) }
        completedInputs.removeValue(forKey: id)
        stagingCleanup.remove(id)
    }

    private func retryStagingCleanup() {
        for id in Array(stagingCleanup) where executingJob != id && activeProcessJobID != id {
            try? disposeJobStaging(id)
        }
    }

    private func requireSuccessful(_ result: ManagedProcessResult, job: JobRecord) throws {
        if let reason = result.limitReason {
            lock.access {
                guard job.state == .running else { return }
                job.state = reason == "deadline" ? .timedOut : .resourceLimited
                job.message = reason == "deadline"
                    ? "job exceeded \(job.timeoutSeconds) seconds"
                    : "job exceeded the \(reason) limit"
                job.stdout = boundedLogText(result.log, bytes: request.limits.stdoutBytes)
                job.source = nil
                job.terminalAt = Date()
            }
            throw CocoaError(.executableLoad)
        }
        guard lock.access({ job.state == .running }) else {
            throw CocoaError(.userCancelled)
        }
        guard result.exitStatus == 0 else {
            lock.access {
                guard job.state == .running else { return }
                if [71, 72, SIGXCPU, SIGXFSZ].contains(result.exitStatus) {
                    job.state = .failed
                    job.message = "worker reported exit \(result.exitStatus) without an observed resource limit"
                } else {
                    job.state = result.exitStatus == 70 ? .failed : .crashed
                    job.message = result.exitStatus == 70
                        ? "worker rejected the job"
                        : "worker exited with status \(result.exitStatus)"
                }
                job.stdout = boundedLogText(result.log, bytes: request.limits.stdoutBytes)
                job.source = nil
                job.terminalAt = Date()
            }
            throw CocoaError(.executableLoad)
        }
    }

    private func enforceStoredResources(_ job: JobRecord) throws {
        let usage = try directoryUsage(
            workerWritableRoots(job.id),
            byteLimit: request.limits.diskBytes,
            fileLimit: request.limits.files
        )
        guard let reason = usage.limitReason else { return }
        lock.access {
            guard job.state == .running else { return }
            job.state = .resourceLimited
            job.message = reason == "disk"
                ? "job exceeded the disk limit"
                : "job exceeded the file-count limit"
            job.terminalAt = Date()
        }
        throw CocoaError(.fileWriteOutOfSpace)
    }

    private func observeServiceMemory() {
        if let footprint = processUsage(getpid())?.physicalFootprint {
            lock.access { servicePeakMemoryBytes = max(servicePeakMemoryBytes, footprint) }
        }
    }

    private func verify(
        job: JobRecord, manifestMaximum: UInt64
    ) throws -> (manifest: VerificationManifest, process: ManagedProcessResult, autoexecPositive: Bool) {
        let verificationRoot = verificationDirectory(job.id)
        try? FileManager.default.removeItem(at: verificationRoot)
        try FileManager.default.createDirectory(at: verificationRoot, withIntermediateDirectories: true)
        let manifestURL = verificationRoot.appendingPathComponent("manifest.json")
        let config = try writeConfiguration(
            baseConfiguration(processRoot: verificationRoot, cpuSeconds: job.timeoutSeconds)
                .merging([
                    "jobID": job.id.uuidString,
                    "fingerprint": job.fingerprint,
                    "scenePath": outputDirectory(job.id).appendingPathComponent("scene.blend").path,
                    "manifest": manifestURL.path,
                    "sessionRoot": root.path,
                    "diagnosticDeniedPaths": job.diagnosticDeniedPaths,
                    "limits": geometryLimits,
                ]) { _, new in new },
            at: jobDirectory(job.id).appendingPathComponent("verify.json")
        )
        let result = try runManagedProcess(
            mode: "verify",
            configuration: config,
            processRoot: verificationRoot,
            job: job
        )
        if let reason = result.limitReason {
            lock.access {
                guard job.state == .running else { return }
                job.state = reason == "deadline" ? .timedOut : .resourceLimited
                job.message = "verification exceeded the \(reason) limit"
                job.terminalAt = Date()
            }
            throw CocoaError(.fileReadCorruptFile)
        }
        if result.exitStatus != 0 {
            lock.access {
                guard job.state == .running else { return }
                switch result.exitStatus {
                case 72:
                    job.state = .resourceLimited
                    job.message = "verified scene exceeded a structural limit"
                case 71, SIGXFSZ:
                    job.state = .resourceLimited
                    job.message = "verification exceeded a memory or file-size limit"
                case SIGXCPU:
                    job.state = .timedOut
                    job.message = "verification exceeded its CPU limit"
                case 70:
                    job.state = .failed
                    job.message = "verification rejected an invalid scene"
                default:
                    job.state = .crashed
                    job.message = "verification exited with status \(result.exitStatus)"
                }
                job.terminalAt = Date()
            }
            throw CocoaError(.fileReadCorruptFile)
        }
        let manifest = try BpyRuntimeManifest.decode(VerificationManifest.self, name: manifestURL.lastPathComponent,
            in: verificationRoot, maximum: manifestMaximum, budget: manifestBudget)
        guard manifest.schema == "nexgenvideo/bpy-verification/1",
              manifest.jobID == job.id.uuidString,
              manifest.fingerprint == job.fingerprint,
              manifest.processIdentifier == result.workerProcessIdentifier,
              manifest.pythonVersion == "3.13.15",
              manifest.bpyVersion == "5.2.2",
              manifest.blenderBuildHash == "d13f752e3b9c",
              manifest.libraryVersions["alembic"]?.version == [1, 8, 3],
              manifest.libraryVersions["ocio"]?.version == [2, 5, 0],
              manifest.libraryVersions["oiio"]?.version == [3, 1, 13],
              manifest.libraryVersions["opensubdiv"]?.version == [3, 7, 0],
              manifest.libraryVersions["openvdb"]?.version == [13, 0, 0],
              manifest.libraryVersions["usd"]?.version == [0, 26, 3],
              URL(fileURLWithPath: manifest.executable).resolvingSymlinksInPath()
                == pythonURL.resolvingSymlinksInPath(),
              URL(fileURLWithPath: manifest.bpyModule).resolvingSymlinksInPath()
                == bpyEntryPointURL.resolvingSymlinksInPath(),
              manifest.autorunMarkerAbsent, manifest.secretEnvironmentAbsent,
              manifest.deniedPaths.count == job.diagnosticDeniedPaths.count,
              job.diagnosticDeniedPaths.allSatisfy({ manifest.deniedPaths[$0]?.isPermissionDenial == true }),
              job.diagnosticDeniedPaths.isEmpty || manifest.networkDenied?.isPermissionDenial == true,
              manifest.sceneSHA256 == (try sha256(outputDirectory(job.id).appendingPathComponent("scene.blend"))) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var positive = false
        if job.diagnosticAutoexecPositiveControl {
            positive = try runAutoexecPositiveControl(job: job)
        }
        return (manifest, result, positive)
    }

    private func runAutoexecPositiveControl(job: JobRecord) throws -> Bool {
        let controlRoot = autoexecDirectory(job.id)
        try FileManager.default.createDirectory(at: controlRoot, withIntermediateDirectories: true)
        let scene = controlRoot.appendingPathComponent("positive-control.blend")
        try FileManager.default.copyItem(at: outputDirectory(job.id).appendingPathComponent("scene.blend"), to: scene)
        let manifestURL = controlRoot.appendingPathComponent("manifest.json")
        let config = try writeConfiguration(
            baseConfiguration(processRoot: controlRoot, cpuSeconds: job.timeoutSeconds)
                .merging([
                    "jobID": job.id.uuidString,
                    "scenePath": scene.path,
                    "manifest": manifestURL.path,
                ]) { _, new in new },
            at: jobDirectory(job.id).appendingPathComponent("autoexec.json")
        )
        let result = try runManagedProcess(
            mode: "autoexec-positive",
            configuration: config,
            processRoot: controlRoot,
            job: job
        )
        try requireSuccessful(result, job: job)
        let manifest = try BpyRuntimeManifest.decode(AutoexecManifest.self, name: manifestURL.lastPathComponent,
            in: controlRoot, maximum: request.limits.outputBytes, budget: manifestBudget)
        guard manifest.schema == "nexgenvideo/bpy-autoexec-positive/1",
              manifest.jobID == job.id.uuidString,
              manifest.processIdentifier == result.workerProcessIdentifier,
              manifest.autorunMarkerPresent else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return true
    }

    private func recordRuntimePreflight(_ preflight: BpyRuntimePreflight, serviceStart: UInt64) {
        let session = request.sessionID.uuidString
        let resources = [
            ("pythonAlias", pythonURL.deletingLastPathComponent().appendingPathComponent("python3")),
            ("pythonTarget", pythonURL), ("supervisor", supervisorURL),
            ("worker", workerURL), ("sitePackages", sitePackagesURL),
        ]
        for (role, url) in resources {
            let fields = BpyRuntimePreflight.diagnostics(at: url, pythonAlias: role == "pythonAlias")
                .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            openDiagnostics.notice("open.runtime-resource session=\(session, privacy: .public) pid=\(getpid(), privacy: .public) start=\(serviceStart, privacy: .public) role=\(role, privacy: .public) \(fields, privacy: .public)")
        }
        openDiagnostics.notice("open.runtime-preflight session=\(session, privacy: .public) pid=\(getpid(), privacy: .public) start=\(serviceStart, privacy: .public) python=\(preflight.pythonExecutable, privacy: .public) supervisor=\(preflight.supervisorExecutable, privacy: .public) worker=\(preflight.workerExists, privacy: .public) sitePackages=\(preflight.sitePackagesExist, privacy: .public)")
    }

    private func probeRuntime() throws -> ProbeManifest {
        let probeRoot = workerRoot.appendingPathComponent("probe", isDirectory: true)
        try? FileManager.default.removeItem(at: probeRoot)
        try FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        let manifestURL = probeRoot.appendingPathComponent("manifest.json")
        let config = try writeConfiguration(
            baseConfiguration(processRoot: probeRoot, cpuSeconds: 120)
                .merging(["manifest": manifestURL.path]) { _, new in new },
            at: root.appendingPathComponent("probe.json")
        )
        let result = try runManagedProcess(
            mode: "probe",
            configuration: config,
            processRoot: probeRoot,
            job: nil
        )
        var stage = "execution"
        do {
            guard result.limitReason == nil, result.exitStatus == 0 else {
                throw CocoaError(.executableLoad)
            }
            stage = "manifest"
            let manifest = try BpyRuntimeManifest.decode(ProbeManifest.self, name: manifestURL.lastPathComponent,
                in: probeRoot, maximum: request.limits.outputBytes, budget: manifestBudget)
            stage = "identity"
            try requireProbeIdentity(manifest.processIdentifier, result.workerProcessIdentifier, field: "pid")
            try requireProbeIdentity(manifest.schema, "nexgenvideo/bpy-probe/1", field: "schema")
            try requireProbeIdentity(manifest.pythonVersion, "3.13.15", field: "python")
            try requireProbeIdentity(manifest.bpyVersion, "5.2.2", field: "bpy")
            try requireProbeIdentity(URL(fileURLWithPath: manifest.executable).resolvingSymlinksInPath(),
                pythonURL.resolvingSymlinksInPath(), field: "executable")
            try requireProbeIdentity(URL(fileURLWithPath: manifest.bpyModule).resolvingSymlinksInPath(),
                bpyEntryPointURL.resolvingSymlinksInPath(), field: "module")
            stage = "collection"
            _ = try result.terminal.beginCollection()
            let commit = try result.terminal.commit()
            guard commit.stopReason == nil, commit.terminalCommit != nil else { throw POSIXError(.EIO) }
            try? FileManager.default.removeItem(at: probeRoot)
            return manifest
        } catch {
            throw ProbeFailure(stage: stage, result: result, cause: error, maximumLogBytes: request.limits.stdoutBytes)
        }
    }

    private func runManagedProcess(
        mode: String,
        configuration: URL,
        processRoot: URL,
        job: JobRecord?,
        injectSupervisorIdentityWriteFailure: Bool = false,
        injectSupervisorIdentityCaptureFailure: Bool = false
    ) throws -> ManagedProcessResult {
        try lock.access {
            if let job, !job.processAuthorizations.canRecord { throw POSIXError(.EOVERFLOW) }
        }
        guard let launchMode = BpyLaunchMode(rawValue: mode),
              let pair = request.storagePair, let permit = job?.admission ?? request.admission,
              let launchDeadline = job?.runningDeadline ?? job?.admissionDeadline ?? request.admissionDeadline,
              let service = processUsage(getpid()) else { throw POSIXError(.EPERM) }
        let preflight = BpyRuntimePreflight(python: pythonURL, supervisor: supervisorURL,
            worker: workerURL, sitePackages: sitePackagesURL)
        if launchMode == .probe { recordRuntimePreflight(preflight, serviceStart: service.startAbsoluteTime) }
        try preflight.requireValid()
        for name in ["tmp", "home", "blender-config", "blender-scripts", "blender-data"] {
            try FileManager.default.createDirectory(at: processRoot.appendingPathComponent(name),
                withIntermediateDirectories: true)
        }
        func relative(_ url: URL, mount: String) throws -> String {
            let prefix = mount + "/"
            guard url.path.hasPrefix(prefix) else { throw POSIXError(.EPERM) }
            return String(url.path.dropFirst(prefix.count))
        }
        var reads: [String] = []
        var workerReads: [String] = []
        if let job, launchMode == .job {
            let directory = jobDirectory(job.id)
            reads.append(try relative(directory.appendingPathComponent("source.py"), mount: pair.data.mountPath))
            for name in job.inputNames {
                reads.append(try relative(inputDirectory(job.id).appendingPathComponent(name), mount: pair.data.mountPath))
            }
            if confirmedRevision != nil {
                reads.append(try relative(directory.appendingPathComponent("bootstrap/confirmed.blend"), mount: pair.data.mountPath))
            }
        } else if let job, launchMode == .verify {
            workerReads.append(try relative(outputDirectory(job.id).appendingPathComponent("scene.blend"), mount: pair.worker.mountPath))
        }
        var injections: [BpyLaunchInjection] = []
        if injectSupervisorIdentityWriteFailure { injections.append(.failAfterChildStart) }
        if injectSupervisorIdentityCaptureFailure { injections += [.failChildIdentityCapture, .childIgnoreTerm] }
        let spec = BpyHostLaunchSpec(permit: permit, job: job?.id, mode: launchMode,
            workerLease: pair.worker.id, dataLease: pair.data.id,
            workerRoot: try relative(processRoot, mount: pair.worker.mountPath),
            configuration: try relative(configuration, mount: pair.data.mountPath),
            configurationSHA256: try sha256(configuration),
            readFiles: reads, workerReadFiles: workerReads, injections: injections)
        let execution = UUID()
        let began = try BpyRuntimeClock.awakeSeconds()
        let process = try monitor.start(spec: spec, execution: execution,
            serviceStart: service.startAbsoluteTime, maximumOutputBytes: request.limits.stdoutBytes,
            deadline: launchDeadline, cancelled: { self.lock.access { self.closed || job.map { $0.state != .running } == true } })
        var detached = false
        defer {
            if !detached {
                do {
                    _ = try process.terminateAndReap(cause: lock.access({ closed || job?.state == .cancelled }) ? .cancelled : .failure)
                    _ = try process.detach()
                    detached = true
                } catch { openDiagnostics.error("runtime.cleanup-pending code=\((error as NSError).code, privacy: .public)") }
            }
            lock.access {
                guard activeProcess === process else { return }
                if detached { clearActiveProcess() }
                else { closed = true; pendingCleanup = .init(process: process) }
            }
        }
        try lock.access {
            if let job {
                try job.processAuthorizations.record(.init(sessionID: request.sessionID, jobID: job.id,
                    authorizationID: execution, processIdentifier: process.supervisor.pid,
                    processStartAbsoluteTime: process.supervisor.start, processExecutable: process.supervisor.executable))
            }
            activeProcess = process
            activeProcessJobID = job?.id
            activeProcessStartAbsoluteTime = process.supervisor.start
            activeProcessExecutable = process.supervisor.executable
            activeProcessAuthorizationID = job == nil ? nil : execution
            activeProcessAuthorized = job == nil
        }
        var peakMemory: UInt64 = 0, peakDisk: UInt64 = 0
        var peakFiles = 0, peakDescendants = 0, samples = 0
        var workerPID: Int32 = -1
        var limitReason: String?
        while true {
            let sample = try process.sample()
            if let job {
                lock.access {
                    job.firstRelease = sample.firstRelease
                    job.runningDeadline = sample.runningDeadline
                }
            }
            if sample.status == .gone { break }
            samples += 1
            let unexpected = max(0, sample.descendants.count - 1)
            peakDescendants = max(peakDescendants, unexpected)
            var footprint = sample.supervisor?.footprint ?? 0
            for child in sample.descendants {
                let sum = footprint.addingReportingOverflow(child.footprint)
                guard !sum.overflow else { throw POSIXError(.EOVERFLOW) }
                footprint = sum.partialValue
            }
            peakMemory = max(peakMemory, footprint)
            if let child = sample.worker {
                workerPID = child.pid
                lock.access { activeWorkerProcessIdentifier = child.pid }
            }
            if let usage = processUsage(getpid()) {
                lock.access { servicePeakMemoryBytes = max(servicePeakMemoryBytes, usage.physicalFootprint) }
            }
            let usage = try resourceUsage(roots: job.map { workerWritableRoots($0.id) } ?? [processRoot],
                observedVnodes: sample.vnodes, byteLimit: request.limits.diskBytes, fileLimit: request.limits.files)
            peakDisk = max(peakDisk, usage.bytes); peakFiles = max(peakFiles, usage.files)
            if let stop = sample.stopReason { limitReason = stop }
            else if let reason = usage.limitReason { limitReason = reason }
            else if unexpected > 0 { limitReason = "process-count" }
            if limitReason != nil || lock.access({ closed || job.map { $0.state != .running } == true }) {
                try process.stop(limitReason.flatMap(BpyServiceStopCause.init(rawValue:)) ?? .cancelled)
                _ = try process.waitForTermination(timeout: 3)
            } else { Thread.sleep(forTimeInterval: 0.05) }
        }
        let termination = try process.waitForTermination(timeout: 3)
        limitReason = process.stopReason ?? limitReason
        let final = try process.detach()
        detached = true
        if workerPID < 0 { workerPID = final.ended.first(where: { $0.parent == process.processIdentifier })?.pid ?? -1 }
        if let job { lock.access { job.terminalProcess = process } }
        let usage = try resourceUsage(roots: job.map { workerWritableRoots($0.id) } ?? [processRoot],
            observedVnodes: [], byteLimit: request.limits.diskBytes, fileLimit: request.limits.files)
        peakDisk = max(peakDisk, usage.bytes); peakFiles = max(peakFiles, usage.files)
        limitReason = limitReason ?? usage.limitReason
        guard termination.exitStatus != 0 || workerPID > 0 || limitReason != nil else { throw POSIXError(.EIO) }
        return .init(workerProcessIdentifier: workerPID, exitStatus: termination.exitStatus, terminationSignal: termination.signal,
            duration: try BpyRuntimeClock.awakeSeconds() - began, peakMemoryBytes: peakMemory,
            peakDiskBytes: peakDisk, peakFileCount: peakFiles, peakDescendantCount: peakDescendants,
            hostMonitorSamples: samples, limitReason: limitReason, log: process.log, terminal: process)
    }

    private func clearActiveProcess() {
        activeProcess = nil
        activeProcessStartAbsoluteTime = nil
        activeProcessExecutable = nil
        activeProcessJobID = nil
        activeProcessAuthorizationID = nil
        activeProcessAuthorized = false
        activeWorkerProcessIdentifier = nil
        pendingCleanup = nil
    }

    @discardableResult
    private func stopActiveProcess(jobID: UUID? = nil) -> Bool {
        guard let process = lock.access({ jobID == nil || activeProcessJobID == jobID ? activeProcess : nil }) else { return true }
        stopProcess(process)
        guard let deadline = try? BpyRuntimeClock.awakeSeconds() + 3 else { return false }
        while lock.access({ activeProcess === process }) {
            if retryPendingCleanup(process) { return true }
            guard DispatchQueue.getSpecific(key: queueKey) == nil,
                  let now = try? BpyRuntimeClock.awakeSeconds(), now < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    private func retryPendingCleanup(_ process: BpyRemoteProcess) -> Bool {
        cleanupLock.lock(); defer { cleanupLock.unlock() }
        guard lock.access({ pendingCleanup?.process === process }) else { return false }
        do {
            _ = try process.waitForTermination(timeout: 0)
            _ = try process.detach()
            lock.access { if activeProcess === process { clearActiveProcess() } }
            return true
        } catch { return false }
    }

    private var geometryLimits: [String: Any] {
        ["objects": request.limits.objects, "vertices": request.limits.vertices, "polygons": request.limits.polygons,
         "renderWidth": request.limits.renderWidth, "renderHeight": request.limits.renderHeight,
         "renderPixels": request.limits.renderPixels]
    }

    private func baseConfiguration(processRoot: URL, cpuSeconds: Int) -> [String: Any] {
        [
            "sitePackages": sitePackagesURL.path,
            "memoryPolicy": request.limits.memoryPolicy.rawValue,
            "outputBytes": request.limits.outputBytes,
            "cpuSeconds": max(2, cpuSeconds + 1),
        ]
    }

    private func writeConfiguration(_ value: [String: Any], at url: URL) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        return url
    }

    private func retainFile(from source: URL, to destination: URL, maximum: UInt64,
                            expectedSHA256: String? = nil, result: (UUID, UInt64)? = nil) throws -> BpyRuntimeFile {
        let pin = try storageAccess.pin()
        let ticket: UUID?
        do {
            ticket = try result.map { try outputLedger.materialize($0.0, bytes: $0.1) }
        } catch { pin.release(); throw error }
        let ledger = outputLedger
        var created: BpyRuntimeFile?
        do {
            let file = try BpyRuntimeFile.copy(from: source, to: destination, maximum: maximum,
                expectedSHA256: expectedSHA256) { removed, _ in
                    if removed {
                        if let ticket { ledger.disposed(ticket) }
                        pin.release()
                    }
                }
            created = file
            if let ticket { try ledger.bind(ticket, file: file) }
            return file
        } catch {
            if let created { created.release() }
            else if let failure = error as? BpyRuntimeFile.CreationError {
                failure.cleanup.whenComplete {
                    if let ticket { ledger.disposed(ticket) }
                    pin.release()
                }
            } else {
                if let ticket { ledger.disposed(ticket) }
                pin.release()
            }
            throw error
        }
    }

    private func retainFile(data: Data, to destination: URL, maximum: UInt64, jobID: UUID) throws -> BpyRuntimeFile {
        let pin = try storageAccess.pin()
        let ledger = outputLedger, bytes = UInt64(data.count)
        let ticket: UUID
        do { ticket = try ledger.materialize(jobID, bytes: bytes) }
        catch { pin.release(); throw error }
        var created: BpyRuntimeFile?
        do {
            let file = try BpyRuntimeFile.copy(data: data, to: destination, maximum: maximum, disposed: { removed, _ in
                if removed { ledger.disposed(ticket); pin.release() }
            })
            created = file
            try ledger.bind(ticket, file: file)
            return file
        } catch {
            if let created { created.release() }
            else if let failure = error as? BpyRuntimeFile.CreationError {
                failure.cleanup.whenComplete { ledger.disposed(ticket); pin.release() }
            } else { ledger.disposed(ticket); pin.release() }
            throw error
        }
    }

    private func writeConfirmedCheckpoint(for job: JobRecord) throws -> URL? {
        guard let file = try lock.access({ try confirmedSceneFile?.retained() }) else { return nil }
        defer { file.release() }
        let destination = jobDirectory(job.id).appendingPathComponent("bootstrap/confirmed.blend")
        let pin = try storageAccess.pin()
        do {
            let bootstrap = try file.copy(to: destination, maximum: request.limits.inputBytes, disposed: { removed, _ in
                if removed { pin.release() }
            })
            lock.access { job.bootstrap = bootstrap }
            return bootstrap.url
        } catch {
            if let failure = error as? BpyRuntimeFile.CreationError { failure.cleanup.whenComplete { pin.release() } }
            else { pin.release() }
            throw error
        }
    }

    private func verifyStagedInputs(_ jobID: UUID) throws {
        let values = lock.access { completedInputs[jobID, default: [:]] }
        for (name, expected) in values {
            let url = inputDirectory(jobID).appendingPathComponent(name)
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_nlink == 1,
                  UInt64(status.st_size) == expected.0,
                  try sha256(url) == expected.1 else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    private func planOutputs(_ jobID: UUID) throws -> [(URL, UInt64, String)] {
        let values = try FileManager.default.contentsOfDirectory(at: outputDirectory(jobID), includingPropertiesForKeys: nil)
        guard BpyOutputContract.acceptsWorkerNames(values.map(\.lastPathComponent)),
              values.count <= min(256, request.limits.files) else { throw CocoaError(.fileReadTooLarge) }
        var total: UInt64 = 0
        var planned: [(URL, UInt64, String)] = []
        for url in values.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var value = stat()
            guard isSafeName(url.lastPathComponent), url.lastPathComponent != "verification.json",
                  lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
                  value.st_uid == getuid(), value.st_nlink == 1, value.st_size >= 0,
                  let type = mediaType(url.pathExtension) else { throw CocoaError(.fileReadCorruptFile) }
            let bytes = UInt64(value.st_size)
            guard total <= request.limits.outputBytes, bytes <= request.limits.outputBytes - total else {
                throw CocoaError(.fileReadTooLarge)
            }
            total += bytes
            planned.append((url, bytes, type))
        }
        return planned
    }

    private func collectOutputs(_ jobID: UUID) throws -> (descriptors: [BpyOutputDescriptor], files: [String: BpyRuntimeFile]) {
        let planned = try planOutputs(jobID)
        var descriptors: [BpyOutputDescriptor] = []
        var files: [String: BpyRuntimeFile] = [:]
        for (url, bytes, type) in planned {
            let destination = root.appendingPathComponent("results/" + jobID.uuidString + "/" + url.lastPathComponent)
            let file = try retainFile(from: url, to: destination, maximum: request.limits.outputBytes, result: (jobID, bytes))
            guard file.byteCount == bytes else { throw CocoaError(.fileReadCorruptFile) }
            let header = try file.read(maximum: 64)
            if type == "application/json" {
                try BpyRuntimeJSONValidation.validate(file)
            } else { try validateMagic(header, mediaType: type) }
            if type == "image/png" { try validatePNGDimensions(header) }
            descriptors.append(.init(name: url.lastPathComponent, byteCount: bytes, sha256: file.sha256, mediaType: type))
            files[url.lastPathComponent] = file
        }
        guard files["scene.blend"] != nil else { throw CocoaError(.fileReadCorruptFile) }
        return (descriptors, files)
    }

    private func validateMagic(_ data: Data, mediaType: String) throws {
        let valid: Bool
        switch mediaType {
        case "application/x-blender":
            valid = BpyBlendFileFormat.accepts(data)
        case "image/png":
            valid = data.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        case "application/json":
            valid = (try? JSONSerialization.jsonObject(with: data)) != nil
        default:
            valid = false
        }
        guard valid else { throw CocoaError(.fileReadCorruptFile) }
    }

    private func validatePNGDimensions(_ data: Data) throws {
        guard data.count >= 24, data[8..<12] == Data([0, 0, 0, 13]), data[12..<16] == Data("IHDR".utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard width > 0, height > 0,
              width <= request.limits.renderWidth,
              height <= request.limits.renderHeight,
              UInt64(width) * UInt64(height) <= UInt64(request.limits.renderPixels) else {
            throw CocoaError(.fileReadTooLarge)
        }
    }

    private func response(for job: JobRecord) -> BpyServiceResponse {
        let ownsActiveProcess = activeProcessJobID == job.id
        return .init(
            ok: true,
            jobID: job.id,
            state: job.state,
            message: job.message,
            runtime: runtimeIdentity,
            progress: job.progress,
            outputs: job.outputs,
            confirmedRevision: confirmedRevision,
            stdout: job.stdout,
            metrics: job.metrics,
            jobFingerprint: job.fingerprint,
            resultExpired: job.resultExpired,
            activeProcessIdentifier: ownsActiveProcess ? activeProcess?.processIdentifier : nil,
            activeProcessStartAbsoluteTime: ownsActiveProcess ? activeProcessStartAbsoluteTime : nil,
            activeProcessExecutable: ownsActiveProcess ? activeProcessExecutable : nil,
            activeProcessAuthorizationID: ownsActiveProcess && !activeProcessAuthorized
                ? activeProcessAuthorizationID
                : nil,
            activeWorkerProcessIdentifier: ownsActiveProcess ? activeWorkerProcessIdentifier : nil,
            firstRelease: job.firstRelease, runningDeadline: job.runningDeadline, terminalCommit: job.terminalCommit
        )
    }

    private func readyResponse() -> BpyServiceResponse {
        lock.access {
            .init(
                ok: true,
                runtime: runtimeIdentity,
                confirmedRevision: confirmedRevision,
                metrics: [
                    "cold_start_seconds": coldStartSeconds ?? 0,
                    "service_peak_memory_bytes": Double(servicePeakMemoryBytes),
                ]
            )
        }
    }

    private var pythonURL: URL {
        runtimeRoot.appendingPathComponent("python/bin/python3.13")
    }

    private var workerURL: URL {
        runtimeRoot.appendingPathComponent("worker.py")
    }

    private var supervisorURL: URL {
        runtimeRoot.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacOS/NexGenVideoBpySupervisor")
    }

    private var sitePackagesURL: URL {
        runtimeRoot.appendingPathComponent("site-packages")
    }

    private var bpyEntryPointURL: URL {
        sitePackagesURL.appendingPathComponent("bpy/__init__.so")
    }

    private func jobDirectory(_ jobID: UUID) -> URL {
        root.appendingPathComponent("jobs/\(jobID.uuidString)", isDirectory: true)
    }

    private func inputDirectory(_ jobID: UUID) -> URL {
        jobDirectory(jobID).appendingPathComponent("inputs", isDirectory: true)
    }

    private func outputDirectory(_ jobID: UUID) -> URL {
        jobWorkerDirectory(jobID).appendingPathComponent("outputs", isDirectory: true)
    }

    private func jobWorkerDirectory(_ jobID: UUID) -> URL {
        workerRoot.appendingPathComponent("jobs/\(jobID.uuidString)/worker", isDirectory: true)
    }

    private func verificationDirectory(_ jobID: UUID) -> URL {
        workerRoot.appendingPathComponent("jobs/\(jobID.uuidString)/verification", isDirectory: true)
    }

    private func autoexecDirectory(_ jobID: UUID) -> URL {
        workerRoot.appendingPathComponent("jobs/\(jobID.uuidString)/autoexec-positive", isDirectory: true)
    }

    private func workerWritableRoots(_ jobID: UUID) -> [URL] {
        [jobWorkerDirectory(jobID), verificationDirectory(jobID), autoexecDirectory(jobID)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func mediaType(_ extensionName: String) -> String? {
        switch extensionName.lowercased() {
        case "blend": "application/x-blender"
        case "png": "image/png"
        case "json": "application/json"
        default: nil
        }
    }
}

private final class BpyRuntimeService: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private let capacity = DispatchSemaphore(value: 1)
    private var sessions: [UUID: ServiceSession] = [:]
    private var retiringSessions: [UUID: ServiceSession] = [:]
    private var cleanupScheduled = Set<UUID>()
    private let sessionsRoot: URL
    private let runtimeRoot: URL

    private var connectionOwners: [UUID: UUID] = [:]
    private var closedConnections = Set<UUID>()

    override init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NexGenVideoBpyService", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        sessionsRoot = root
        runtimeRoot = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent("BpyRuntime", isDirectory: true)
        super.init()
    }

    func runBoundaryProbe(_ data: Data, monitor: BpyServiceMonitor, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyBoundaryProbeRequest.self, from: data)
            let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard request.schema == "nexgenvideo/bpy-boundary-probe-request/2",
                  request.limits.isValid,
                  FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/BPY_BOUNDARY_PROBE_NONPRODUCT_CI").path) else {
                throw CocoaError(.fileReadNoPermission)
            }
            capacity.wait(); defer { capacity.signal() }
            let storage = try BpyServiceStoragePair(pair: request.storagePair, limits: request.limits, transport: request.nonce, owner: request.nonce,
                serviceStart: processUsage(getpid())?.startAbsoluteTime ?? 0)
            defer {
                try? FileManager.default.removeItem(at: storage.workerRoot)
                try? FileManager.default.removeItem(at: storage.dataRoot)
                storage.release()
            }
            reply(try JSONEncoder().encode(runBoundarySupervisor(request: request, storage: storage, monitor: monitor)))
        } catch {
            reply(failure("boundary probe failed: \(error.localizedDescription)"))
        }
    }

    func openSession(_ data: Data, owner: UUID, monitor: BpyServiceMonitor, withReply reply: @escaping (Data) -> Void) {
        var requestedID: UUID?
        var stage = OpenStage.decode
        do {
            let request = try JSONDecoder().decode(BpyOpenSessionRequest.self, from: data)
            requestedID = request.sessionID
            stage = .contract
            guard request.limits.isValid, !request.documentID.isEmpty,
                  request.documentID.count <= 256,
                  request.confirmedRevision.map(isSafeName) ?? true else {
                openDiagnostics.notice("open.fail session=\(request.sessionID.uuidString, privacy: .public) owner=\(owner.uuidString, privacy: .public) stage=contract")
                reply(failure("invalid session contract"))
                return
            }
            stage = .claim
            let claimed = lock.access { () -> Bool in
                guard !closedConnections.contains(owner), retiringSessions[request.sessionID] == nil,
                      connectionOwners[request.sessionID] == nil || connectionOwners[request.sessionID] == owner else { return false }
                connectionOwners[request.sessionID] = owner
                return true
            }
            guard claimed else { throw CocoaError(.fileWriteNoPermission) }
            guard request.schema == "nexgenvideo/bpy-open-session/2", request.storage == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard let pair = request.storagePair else {
                stage = .preparation
                guard request.admission == nil, request.admissionDeadline == nil, let identity = processUsage(getpid()) else { throw CocoaError(.executableLoad) }
                let inUse = lock.access {
                    (Array(sessions.values) + Array(retiringSessions.values)).flatMap {
                        $0.request.storagePair.map { [$0.worker.id, $0.data.id] } ?? []
                    } + BpyServiceStoragePair.inUseIDs
                }
                openDiagnostics.notice("open.prepared session=\(request.sessionID.uuidString, privacy: .public) owner=\(owner.uuidString, privacy: .public) pid=\(getpid(), privacy: .public) start=\(identity.startAbsoluteTime, privacy: .public)")
                reply(encoded(.init(ok: true, storagePreparation: .init(id: request.sessionID,
                    servicePID: getpid(), serviceStart: identity.startAbsoluteTime, inUseStorageIDs: inUse))))
                return
            }
            guard request.admission != nil, request.admissionDeadline?.isFinite == true else { throw CocoaError(.fileReadCorruptFile) }
            stage = .validateMount
            let storageAccess = try BpyServiceStoragePair(pair: pair, limits: request.limits, transport: request.sessionID, owner: owner,
                serviceStart: processUsage(getpid())?.startAbsoluteTime ?? 0)
            stage = .reserve
            try awaitRetiredConnections(owner: owner, documentID: request.documentID)
            let retired: ServiceSession? = try lock.access {
                guard !closedConnections.contains(owner), connectionOwners[request.sessionID] == owner,
                      retiringSessions.isEmpty else { throw CocoaError(.fileWriteNoPermission) }
                guard sessions[request.sessionID] == nil, let existing = sessions.values.first else { return nil }
                guard sessions.count == 1, connectionOwners[existing.request.sessionID] == owner,
                      existing.request.documentID == request.documentID else { throw CocoaError(.fileWriteNoPermission) }
                return retire(existing.request.sessionID)
            }
            if let retired {
                finishClosing(retired)
                guard lock.access({ retiringSessions[retired.request.sessionID] == nil }) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
            let session: ServiceSession = try lock.access {
                guard !closedConnections.contains(owner), connectionOwners[request.sessionID] == owner,
                      retiringSessions.isEmpty else { throw CocoaError(.fileWriteNoPermission) }
                if let existing = sessions[request.sessionID] {
                    guard existing.matches(request) else {
                        throw CocoaError(.fileWriteInvalidFileName)
                    }
                    return existing
                }
                guard sessions.isEmpty else { throw CocoaError(.fileWriteNoPermission) }
                let session = ServiceSession(
                    request: request,
                    root: storageAccess.dataRoot,
                    runtimeRoot: runtimeRoot,
                    monitor: monitor,
                    capacity: capacity,
                    storageAccess: storageAccess
                )
                sessions[request.sessionID] = session
                return session
            }
            session.open { [weak self, weak session] response in
                let opened = (try? JSONDecoder().decode(BpyServiceResponse.self, from: response).ok) == true
                openDiagnostics.notice("open.result session=\(request.sessionID.uuidString, privacy: .public) owner=\(owner.uuidString, privacy: .public) ok=\(opened, privacy: .public)")
                if !opened,
                   let self, let session {
                    let removed = self.lock.access { () -> ServiceSession? in
                        guard self.sessions[request.sessionID] === session else { return nil }
                        self.retiringSessions[request.sessionID] = session
                        return self.sessions.removeValue(forKey: request.sessionID)
                    }
                    if let removed {
                        DispatchQueue.global(qos: .utility).async { self.finishClosing(removed) }
                    }
                }
                reply(response)
            }
        } catch {
            let diagnostic = error as NSError
            let serviceStart = processUsage(getpid())?.startAbsoluteTime ?? 0
            openDiagnostics.notice("open.fail session=\(requestedID?.uuidString ?? "none", privacy: .public) owner=\(owner.uuidString, privacy: .public) pid=\(getpid(), privacy: .public) start=\(serviceStart, privacy: .public) stage=\(stage.rawValue, privacy: .public) domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code, privacy: .public)")
            lock.access {
                if let id = requestedID, connectionOwners[id] == owner, sessions[id] == nil, retiringSessions[id] == nil {
                    connectionOwners.removeValue(forKey: id)
                }
            }
            reply(failure("invalid open request"))
        }
    }

    func restoreCheckpoint(_ data: Data, owner: UUID, chunk: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyRestoreCheckpointRequest.self, from: data)
            guard let session = session(request.sessionID, owner: owner) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try session.restore(request, chunk: chunk)
            reply(encoded(.init(ok: true, confirmedRevision: request.revision)))
        } catch {
            reply(failure("checkpoint rejected: \(error.localizedDescription)"))
        }
    }

    func stageInput(_ data: Data, owner: UUID, chunk: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyStageInputRequest.self, from: data)
            guard let session = session(request.sessionID, owner: owner) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try session.stage(request, chunk: chunk)
            reply(encoded(.init(ok: true)))
        } catch {
            reply(failure("input rejected: \(error.localizedDescription)"))
        }
    }

    func runJob(_ data: Data, owner: UUID, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyRunJobRequest.self, from: data)
            guard let session = session(request.sessionID, owner: owner) else {
                throw CocoaError(.fileNoSuchFile)
            }
            reply(encoded(session.submit(request)))
        } catch {
            reply(failure("invalid job request"))
        }
    }

    func jobStatus(_ data: Data, owner: UUID, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyJobReference.self, from: data)
            guard let session = session(request.sessionID, owner: owner) else {
                throw CocoaError(.fileNoSuchFile)
            }
            reply(encoded(session.status(request.jobID)))
        } catch {
            reply(failure("invalid status request"))
        }
    }

    func authorizeProcess(_ data: Data, owner: UUID, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyAuthorizeProcessRequest.self, from: data)
            guard let session = session(request.sessionID, owner: owner) else {
                throw CocoaError(.fileNoSuchFile)
            }
            reply(encoded(try session.authorize(request)))
        } catch {
            reply(failure("process authorization rejected"))
        }
    }

    func readOutput(_ data: Data, owner: UUID, withReply reply: @escaping (Data, Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyReadOutputRequest.self, from: data)
            guard let session = session(request.sessionID, owner: owner) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let result = try session.output(request)
            reply(encoded(result.0), result.1)
        } catch {
            reply(failure("output rejected: \(error.localizedDescription)"), Data())
        }
    }

    func releaseResources(_ data: Data, owner: UUID, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyReleaseResourcesRequest.self, from: data)
            guard let session = session(request.sessionID, owner: owner) else { throw CocoaError(.fileNoSuchFile) }
            reply(encoded(try session.releaseResources(request)))
        } catch { reply(failure("resource release rejected")) }
    }

    func confirmJob(_ data: Data, owner: UUID, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyConfirmJobRequest.self, from: data)
            guard let session = session(request.sessionID, owner: owner) else {
                throw CocoaError(.fileNoSuchFile)
            }
            reply(encoded(try session.confirm(request)))
        } catch {
            reply(failure("confirmation rejected: \(error.localizedDescription)"))
        }
    }

    func cancelJob(_ data: Data, owner: UUID, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyJobReference.self, from: data)
            guard let session = session(request.sessionID, owner: owner) else {
                throw CocoaError(.fileNoSuchFile)
            }
            reply(encoded(session.cancel(request.jobID)))
        } catch {
            reply(failure("invalid cancel request"))
        }
    }

    func closeSession(_ data: Data, owner: UUID, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpySessionReference.self, from: data)
            let session: ServiceSession? = try lock.access {
                if connectionOwners[request.sessionID] == nil,
                   sessions[request.sessionID] == nil, retiringSessions[request.sessionID] == nil { return nil }
                guard connectionOwners[request.sessionID] == owner else { throw CocoaError(.fileWriteNoPermission) }
                return retire(request.sessionID)
            }
            if let session { finishClosing(session) }
            let complete = lock.access { () -> Bool in
                if connectionOwners[request.sessionID] == owner {
                    guard retiringSessions[request.sessionID] == nil else { return false }
                    connectionOwners.removeValue(forKey: request.sessionID)
                }
                return true
            }
            reply(complete ? encoded(.init(ok: true)) : failure("session cleanup is still in progress"))
        } catch {
            reply(failure("invalid close request"))
        }
    }

    func shutdown(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        let closing = lock.access { () -> [ServiceSession] in
            Array(Set(sessions.keys).union(retiringSessions.keys)).compactMap { retire($0) }
        }
        closing.forEach { finishClosing($0) }
        let complete = lock.access { retiringSessions.isEmpty }
        reply(complete ? encoded(.init(ok: true)) : failure("session cleanup is still in progress"))
    }

    private func awaitRetiredConnections(owner: UUID, documentID: String) throws {
        let deadline = try BpyRuntimeClock.awakeSeconds() + 10
        while true {
            let pending = lock.access {
                (Array(sessions.values) + Array(retiringSessions.values)).filter { session in
                    connectionOwners[session.request.sessionID] != owner
                }
            }
            if pending.isEmpty { return }
            guard pending.allSatisfy({ $0.request.documentID == documentID }) else { throw POSIXError(.EPERM) }
            guard try BpyRuntimeClock.awakeSeconds() < deadline else { throw POSIXError(.EBUSY) }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func retire(_ id: UUID) -> ServiceSession? {
        guard let session = sessions.removeValue(forKey: id) else { return retiringSessions[id] }
        retiringSessions[id] = session
        return session
    }

    private func finishClosing(_ session: ServiceSession) {
        guard session.close() else {
            let id = session.request.sessionID
            let schedule = lock.access { cleanupScheduled.insert(id).inserted }
            if schedule {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self, session] in
                    lock.access { _ = cleanupScheduled.remove(id) }
                    guard lock.access({ retiringSessions[id] === session }) else { return }
                    finishClosing(session)
                }
            }
            return
        }
        lock.access {
            let id = session.request.sessionID
            if retiringSessions[id] === session {
                retiringSessions.removeValue(forKey: id)
                connectionOwners.removeValue(forKey: id)
            }
        }
    }

    private func session(_ id: UUID, owner: UUID) -> ServiceSession? {
        lock.access {
            guard !closedConnections.contains(owner), connectionOwners[id] == owner else { return nil }
            return sessions[id]
        }
    }

    @discardableResult
    func invalidateSessions(_ identifiers: Set<UUID>, owner: UUID) -> Bool {
        let closing = lock.access { () -> [ServiceSession] in
            identifiers.compactMap { id in
                guard connectionOwners[id] == owner else { return nil }
                if let retired = retire(id) { return retired }
                if retiringSessions[id] == nil { connectionOwners.removeValue(forKey: id) }
                return nil
            }
        }
        closing.forEach { finishClosing($0) }
        return lock.access { identifiers.allSatisfy { connectionOwners[$0] != owner } }
    }

    func invalidateConnection(owner: UUID) -> Bool {
        let identifiers = lock.access { () -> Set<UUID> in
            closedConnections.insert(owner)
            return Set(connectionOwners.filter { $0.value == owner }.map(\.key))
        }
        return invalidateSessions(identifiers, owner: owner)
    }

}

private final class BpyRuntimeConnection: NSObject, BpyRuntimeServiceProtocol, @unchecked Sendable {
    private let service: BpyRuntimeService
    private let lock = NSLock()
    private var sessionIDs = Set<UUID>()
    private var invalidated = false
    private let ownerID = UUID()
    private weak var connection: NSXPCConnection?

    init(service: BpyRuntimeService, connection: NSXPCConnection) {
        self.service = service
        self.connection = connection
    }

    func runBoundaryProbe(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard lock.access({ !invalidated }) else {
            reply(failure("XPC connection is unavailable"))
            return
        }
        guard let connection, let decoded = try? JSONDecoder().decode(BpyBoundaryProbeRequest.self, from: request) else {
            reply(failure("XPC connection is unavailable"))
            return
        }
        let monitor = BpyServiceMonitor(connection: connection, transport: decoded.nonce)
        let callback = ResponseCallback(reply)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            service.runBoundaryProbe(request, monitor: monitor, withReply: callback.body)
        }
    }

    private func owns<T: Decodable>(
        _ type: T.Type,
        request: Data,
        sessionID: (T) -> UUID
    ) -> Bool {
        guard let value = try? JSONDecoder().decode(type, from: request) else { return false }
        return lock.access { !invalidated && sessionIDs.contains(sessionID(value)) }
    }

    func openSession(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard let value = try? JSONDecoder().decode(BpyOpenSessionRequest.self, from: request),
              lock.access({ !invalidated }) else {
            reply(failure("XPC connection is unavailable"))
            return
        }
        guard let connection else { reply(failure("XPC connection is unavailable")); return }
        let monitor = BpyServiceMonitor(connection: connection, transport: value.sessionID)
        let callback = ResponseCallback(reply)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard lock.access({ !invalidated }) else { callback.body(failure("XPC connection is unavailable")); return }
            service.openSession(request, owner: ownerID, monitor: monitor) { [self] response in
                guard (try? JSONDecoder().decode(BpyServiceResponse.self, from: response).ok) == true else {
                    callback.body(response)
                    return
                }
                let accepted = lock.access { () -> Bool in
                    guard !invalidated else { return false }
                    sessionIDs.insert(value.sessionID)
                    return true
                }
                guard accepted else {
                    service.invalidateSessions([value.sessionID], owner: ownerID)
                    callback.body(failure("XPC connection is unavailable"))
                    return
                }
                callback.body(response)
            }
        }
    }

    func restoreCheckpoint(_ request: Data, chunk: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyRestoreCheckpointRequest.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.restoreCheckpoint(request, owner: ownerID, chunk: chunk, withReply: reply)
    }

    func stageInput(_ request: Data, chunk: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyStageInputRequest.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.stageInput(request, owner: ownerID, chunk: chunk, withReply: reply)
    }

    func runJob(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyRunJobRequest.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.runJob(request, owner: ownerID, withReply: reply)
    }

    func jobStatus(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyJobReference.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.jobStatus(request, owner: ownerID, withReply: reply)
    }

    func authorizeProcess(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyAuthorizeProcessRequest.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.authorizeProcess(request, owner: ownerID, withReply: reply)
    }

    func readOutput(_ request: Data, withReply reply: @escaping (Data, Data) -> Void) {
        guard owns(BpyReadOutputRequest.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"), Data())
            return
        }
        service.readOutput(request, owner: ownerID, withReply: reply)
    }

    func releaseResources(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyReleaseResourcesRequest.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable")); return
        }
        service.releaseResources(request, owner: ownerID, withReply: reply)
    }

    func confirmJob(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyConfirmJobRequest.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.confirmJob(request, owner: ownerID, withReply: reply)
    }

    func cancelJob(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyJobReference.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        let callback = ResponseCallback(reply)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            service.cancelJob(request, owner: ownerID, withReply: callback.body)
        }
    }

    func closeSession(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard let value = try? JSONDecoder().decode(BpySessionReference.self, from: request),
              lock.access({ !invalidated && sessionIDs.contains(value.sessionID) }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        let callback = ResponseCallback(reply)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            service.closeSession(request, owner: ownerID) { [self] response in
                if (try? JSONDecoder().decode(BpyServiceResponse.self, from: response).ok) == true {
                    lock.access { _ = sessionIDs.remove(value.sessionID) }
                }
                callback.body(response)
            }
        }
    }

    func shutdown(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        let identifiers = lock.access { () -> Set<UUID> in
            invalidated = true
            return sessionIDs
        }
        let callback = ResponseCallback(reply)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let complete = service.invalidateConnection(owner: ownerID)
            if complete { lock.access { sessionIDs.subtract(identifiers) } }
            callback.body(complete ? encoded(.init(ok: true)) : failure("session cleanup is still in progress"))
        }
    }

    func invalidate() {
        lock.access {
            invalidated = true
            sessionIDs.removeAll()
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            _ = service.invalidateConnection(owner: ownerID)
        }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = BpyRuntimeService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let exported = BpyRuntimeConnection(service: service, connection: connection)
        connection.remoteObjectInterface = NSXPCInterface(with: BpyHostMonitorProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: BpyRuntimeServiceProtocol.self)
        connection.exportedObject = exported
        connection.interruptionHandler = { [weak exported] in exported?.invalidate() }
        connection.invalidationHandler = { [weak exported] in exported?.invalidate() }
        connection.resume()
        return true
    }
}

if CommandLine.arguments == [CommandLine.arguments[0], "--selftest-directory-deletion"] {
    do {
        let evidence = try JSONSerialization.data(withJSONObject: directoryDeletionProbe(), options: [.sortedKeys])
        FileHandle.standardOutput.write(evidence)
        Darwin.exit(0)
    } catch {
        FileHandle.standardError.write(Data("Directory deletion probe failed: \(error.localizedDescription)\n".utf8))
        Darwin.exit(1)
    }
}

let listener = NSXPCListener.service()
private let listenerDelegate = ListenerDelegate()
listener.delegate = listenerDelegate
listener.resume()
