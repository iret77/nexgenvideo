import BpyRuntimeProtocol
import CryptoKit
import Darwin
import Foundation

@_silgen_name("proc_listchildpids")
private func procListChildPIDs(
    _ processIdentifier: pid_t,
    _ buffer: UnsafeMutableRawPointer?,
    _ bufferSize: Int32
) -> Int32

@_silgen_name("proc_pid_rusage")
private func procPIDRusage(
    _ processIdentifier: pid_t,
    _ flavor: Int32,
    _ buffer: UnsafeMutableRawPointer
) -> Int32

@_silgen_name("proc_pidinfo")
private func procPIDInfo(
    _ processIdentifier: pid_t,
    _ flavor: Int32,
    _ argument: UInt64,
    _ buffer: UnsafeMutableRawPointer?,
    _ bufferSize: Int32
) -> Int32

@_silgen_name("proc_pidfdinfo")
private func procPIDFDInfo(
    _ processIdentifier: pid_t,
    _ descriptor: Int32,
    _ flavor: Int32,
    _ buffer: UnsafeMutableRawPointer,
    _ bufferSize: Int32
) -> Int32

@_silgen_name("proc_pidfileportinfo")
private func procPIDFileportInfo(
    _ processIdentifier: pid_t,
    _ fileport: UInt32,
    _ flavor: Int32,
    _ buffer: UnsafeMutableRawPointer,
    _ bufferSize: Int32
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

private let resultRetentionSeconds: TimeInterval = 15 * 60

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

private func processTree(root: pid_t, start: UInt64) throws -> [pid_t] {
    try BpyProcessTreeInspection.descendants(root: root, start: start,
        identity: { processUsage($0)?.startAbsoluteTime }) { parent, capacity in
        var children = [pid_t](repeating: 0, count: capacity)
        errno = 0
        let count = children.withUnsafeMutableBytes {
            procListChildPIDs(parent, $0.baseAddress, Int32($0.count))
        }
        let failure = errno
        return .init(count: Int(count), error: failure, pids: children)
    }
}

private func kernelParent(_ processIdentifier: pid_t, start: UInt64) -> pid_t? {
    guard processUsage(processIdentifier)?.startAbsoluteTime == start else { return nil }
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
    defer { buffer.deallocate() }
    guard procPIDInfo(processIdentifier, 13, 0, buffer, 64) == 64,
          buffer.load(as: UInt32.self) == UInt32(processIdentifier),
          processUsage(processIdentifier)?.startAbsoluteTime == start else { return nil }
    return pid_t(buffer.load(fromByteOffset: 4, as: UInt32.self))
}

private func stopProcess(_ process: Process) {
    guard process.processIdentifier > 1, process.isRunning else { return }
    process.terminate()
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

private let procPIDListFDs: Int32 = 1
private let procFDTypeVnode: UInt32 = 1
private let procPIDFDVnodePathInfo: Int32 = 2
private let procPIDRegionPathInfo: Int32 = 8
private let procFDInfoSize = 8
private let vnodeFDInfoWithPathSize = 1_200
private let procRegionWithPathInfoSize = 1_272
private let vnodePathLength = 1_024
private let kernelFRead: UInt32 = 1
private let kernelFWrite: UInt32 = 2
private let maximumMappedRegionCount = 65_536
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
    fileLimit: Int
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
        guard let descriptor = try directoryDescriptor(
            reference,
            managedRoots: managedRoots
        ) else { continue }
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

private func processMatches(_ identity: SupervisorWorkerIdentity) -> Bool {
    processUsage(identity.processIdentifier)?.startAbsoluteTime == identity.startAbsoluteTime
}

private func kernelPath(
    _ buffer: UnsafeRawPointer,
    offset: Int
) throws -> String? {
    let bytes = UnsafeBufferPointer(
        start: buffer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: vnodePathLength
    )
    guard let end = bytes.firstIndex(of: 0) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    guard end > 0 else { return nil }
    guard let path = String(bytes: bytes[..<end], encoding: .utf8), path.hasPrefix("/") else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return path
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

private func ownedOpenVnodes(
    _ identity: SupervisorWorkerIdentity,
    roots: [URL],
    fileports: Bool = false
) throws -> [VnodeIdentity: UInt64] {
    guard processMatches(identity) else { return [:] }
    let listFlavor: Int32 = fileports ? 14 : procPIDListFDs
    let rootPaths = try managedRootPaths(roots)
    let maximumBytes = procFDInfoSize * 4_096
    errno = 0
    let required = Int(procPIDInfo(
        identity.processIdentifier,
        listFlavor,
        0,
        nil,
        0
    ))
    let requiredError = errno
    if required == 0 && fileports && requiredError == 0 { return [:] }
    if required <= 0 {
        if !processMatches(identity) {
            return [:]
        }
        throw POSIXError(.init(rawValue: requiredError) ?? .EIO)
    }
    guard required <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
    let capacity = min(maximumBytes, max(required + procFDInfoSize * 64, procFDInfoSize * 128))
    let descriptors = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
    defer { descriptors.deallocate() }
    descriptors.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
    errno = 0
    let returned = Int(procPIDInfo(
        identity.processIdentifier,
        listFlavor,
        0,
        descriptors,
        Int32(capacity)
    ))
    let returnedError = errno
    if returned == 0 && fileports && returnedError == 0 { return [:] }
    if returned <= 0 {
        if !processMatches(identity) {
            return [:]
        }
        throw POSIXError(.init(rawValue: returnedError) ?? .EIO)
    }
    guard returned < capacity, returned % procFDInfoSize == 0 else {
        throw CocoaError(.fileReadTooLarge)
    }
    var resources: [VnodeIdentity: UInt64] = [:]
    for offset in stride(from: 0, to: returned, by: procFDInfoSize) {
        let descriptor = descriptors.load(fromByteOffset: offset, as: Int32.self)
        let type = descriptors.load(fromByteOffset: offset + 4, as: UInt32.self)
        guard (fileports || descriptor >= 0), type == procFDTypeVnode else { continue }
        let vnode = UnsafeMutableRawPointer.allocate(byteCount: vnodeFDInfoWithPathSize, alignment: 8)
        defer { vnode.deallocate() }
        vnode.initializeMemory(as: UInt8.self, repeating: 0, count: vnodeFDInfoWithPathSize)
        errno = 0
        let result = fileports
            ? procPIDFileportInfo(identity.processIdentifier, UInt32(bitPattern: descriptor),
                                  2, vnode, Int32(vnodeFDInfoWithPathSize))
            : procPIDFDInfo(identity.processIdentifier, descriptor, procPIDFDVnodePathInfo,
                            vnode, Int32(vnodeFDInfoWithPathSize))
        let vnodeError = errno
        guard Int(result) == vnodeFDInfoWithPathSize else {
            if !processMatches(identity) {
                return [:]
            }
            if result == 0 && [EBADF, ENOENT, EINVAL].contains(vnodeError) { continue }
            throw POSIXError(.init(rawValue: vnodeError) ?? .EIO)
        }
        let openFlags = vnode.load(fromByteOffset: 0, as: UInt32.self)
        let mode = vnode.load(fromByteOffset: 28, as: UInt16.self)
        guard mode & UInt16(S_IFMT) == UInt16(S_IFREG) else { continue }
        let device = vnode.load(fromByteOffset: 24, as: UInt32.self)
        let linkCount = vnode.load(fromByteOffset: 30, as: UInt16.self)
        let inode = vnode.load(fromByteOffset: 32, as: UInt64.self)
        let logical = vnode.load(fromByteOffset: 112, as: Int64.self)
        let blocks = vnode.load(fromByteOffset: 120, as: Int64.self)
        let path = try kernelPath(vnode, offset: 176)
        let belongsToJob = linkCount == 0 || isManagedPath(path, roots: rootPaths)
        if !belongsToJob {
            let accessFlags = openFlags & (kernelFRead | kernelFWrite)
            guard accessFlags & kernelFWrite == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            continue
        }
        let key = VnodeIdentity(
            device: UInt64(device),
            inode: inode
        )
        resources[key] = max(
            resources[key] ?? 0,
            vnodeBytes(logical: logical, blocks: blocks)
        )
    }
    guard processMatches(identity) else {
        return [:]
    }
    return resources
}

private func ownedMappedVnodes(
    _ identity: SupervisorWorkerIdentity,
    roots: [URL]
) throws -> [VnodeIdentity: UInt64] {
    guard processMatches(identity) else { return [:] }
    let rootPaths = try managedRootPaths(roots)
    let region = UnsafeMutableRawPointer.allocate(
        byteCount: procRegionWithPathInfoSize,
        alignment: 8
    )
    defer { region.deallocate() }
    var resources: [VnodeIdentity: UInt64] = [:]
    var address: UInt64 = 0
    var traversedRegions = 0
    for _ in 0..<maximumMappedRegionCount {
        region.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: procRegionWithPathInfoSize
        )
        errno = 0
        let result = procPIDInfo(
            identity.processIdentifier,
            procPIDRegionPathInfo,
            address,
            region,
            Int32(procRegionWithPathInfoSize)
        )
        let regionError = errno
        guard Int(result) == procRegionWithPathInfoSize else {
            if !processMatches(identity) { return [:] }
            if result == 0 && regionError == EINVAL && traversedRegions > 0 { return resources }
            throw POSIXError(.init(rawValue: regionError) ?? .EIO)
        }
        traversedRegions += 1
        let regionAddress = region.load(fromByteOffset: 80, as: UInt64.self)
        let regionSize = region.load(fromByteOffset: 88, as: UInt64.self)
        guard regionAddress >= address,
              regionSize > 0,
              regionAddress <= UInt64.max - regionSize else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let nextAddress = regionAddress + regionSize
        let mode = region.load(fromByteOffset: 100, as: UInt16.self)
        if mode & UInt16(S_IFMT) == UInt16(S_IFREG) {
            let linkCount = region.load(fromByteOffset: 102, as: UInt16.self)
            let path = try kernelPath(region, offset: 248)
            if linkCount == 0 || isManagedPath(path, roots: rootPaths) {
                let device = region.load(fromByteOffset: 96, as: UInt32.self)
                let inode = region.load(fromByteOffset: 104, as: UInt64.self)
                let logical = region.load(fromByteOffset: 184, as: Int64.self)
                let blocks = region.load(fromByteOffset: 192, as: Int64.self)
                let key = VnodeIdentity(device: UInt64(device), inode: inode)
                resources[key] = max(
                    resources[key] ?? 0,
                    vnodeBytes(logical: logical, blocks: blocks)
                )
            }
        }
        if nextAddress == UInt64.max {
            guard processMatches(identity) else { return [:] }
            return resources
        }
        address = nextAddress
    }
    guard processMatches(identity) else { return [:] }
    throw CocoaError(.fileReadTooLarge)
}

private func ownedRetainedVnodes(
    _ identity: SupervisorWorkerIdentity,
    roots: [URL]
) throws -> [VnodeIdentity: UInt64] {
    var resources = try ownedOpenVnodes(identity, roots: roots)
    mergeVnodes(try ownedOpenVnodes(identity, roots: roots, fileports: true), into: &resources)
    mergeVnodes(try ownedMappedVnodes(identity, roots: roots), into: &resources)
    guard processMatches(identity) else { return [:] }
    return resources
}

private func resourceUsage(
    roots: [URL],
    worker: SupervisorWorkerIdentity?,
    byteLimit: UInt64,
    fileLimit: Int
) throws -> DirectoryUsage {
    let named = try directoryUsage(roots, byteLimit: byteLimit, fileLimit: fileLimit)
    guard named.limitReason == nil, let worker else { return named }
    var resources = named.resources
    var files = named.files
    for (identity, bytes) in try ownedRetainedVnodes(worker, roots: roots) {
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

    init(url: URL, totalBytes: UInt64, expectedSHA256: String, handle: FileHandle) {
        self.url = url
        self.totalBytes = totalBytes
        self.expectedSHA256 = expectedSHA256
        self.handle = handle
    }
}

private final class JobRecord: @unchecked Sendable {
    let id: UUID
    var source: String?
    let expectedRevision: String?
    let inputNames: [String]
    let timeoutSeconds: Int
    let fingerprint: String
    let diagnosticDeniedPaths: [String]
    let diagnosticAutoexecPositiveControl: Bool
    var state: BpyRuntimeJobState = .accepted
    var message: String?
    var progress: [BpyRuntimeProgress] = []
    var outputs: [BpyOutputDescriptor] = []
    var outputData: [String: Data] = [:]
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
        diagnosticDeniedPaths = request.diagnosticDeniedPaths
        diagnosticAutoexecPositiveControl = request.diagnosticAutoexecPositiveControl
        diagnosticSupervisorIdentityWriteFailure = request.diagnosticSupervisorIdentityWriteFailure
        diagnosticSupervisorIdentityCaptureFailure = request.diagnosticSupervisorIdentityCaptureFailure
    }

    func expireResult() {
        outputs.removeAll()
        outputData.removeAll()
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

private struct SupervisorWorkerIdentity: Decodable {
    let processIdentifier: Int32
    let startAbsoluteTime: UInt64
}

private struct ManagedProcessResult {
    let workerProcessIdentifier: Int32
    let exitStatus: Int32
    let duration: Double
    let peakMemoryBytes: UInt64
    let peakDiskBytes: UInt64
    let peakFileCount: Int
    let peakDescendantCount: Int
    let limitReason: String?
    let log: String
}

private struct BoundaryChildReport: Decodable {
    let schema: String
    let mode: String
    let processIdentifier: Int32
    let parentProcessIdentifier: Int32
    let allowedWriteSucceeded: Bool
    let outsideWriteDeniedErrno: Int32
    let forkDeniedErrno: Int32
    let networkDeniedErrno: Int32
    let signalDeniedErrnos: [Int32]
    let resourceBytes: UInt64
    let retentionDeniedErrno: Int32
}

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
    let childStartAbsoluteTime: UInt64
}

private struct BoundaryRun {
    let supervisorProcessIdentifier: Int32
    let supervisorParentProcessIdentifier: Int32
    let supervisorStartAbsoluteTime: UInt64
    let child: SupervisorWorkerIdentity
    let report: BoundaryChildReport
    let supervisorGone: Bool
    let childGone: Bool
    let observedRetainedBytes: UInt64
    let limitReason: String?
    let internalLinkedWritableDeduplicated: Bool
    let retentionDenied: Bool
}

private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while process.isRunning {
        if ProcessInfo.processInfo.systemUptime >= deadline { return false }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return true
}

private func terminateBoundaryProcess(
    _ process: Process,
    startAbsoluteTime: UInt64
) -> Bool {
    guard process.isRunning else { return true }
    process.terminate()
    if waitForExit(process, timeout: 3) { return true }
    if let current = processUsage(process.processIdentifier), current.startAbsoluteTime != startAbsoluteTime {
        return !process.isRunning
    }
    guard process.isRunning else { return true }
    let stopped = Darwin.kill(process.processIdentifier, SIGSTOP) == 0
    let stoppedIdentity = processUsage(process.processIdentifier)
    if stoppedIdentity?.startAbsoluteTime == startAbsoluteTime
        || (stopped && stoppedIdentity == nil && process.isRunning) {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
    return waitForExit(process, timeout: 2)
}

private func boundaryIdentityGone(_ identity: SupervisorWorkerIdentity) -> Bool {
    if let current = processUsage(identity.processIdentifier) { return current.startAbsoluteTime != identity.startAbsoluteTime }
    errno = 0
    let result = Darwin.kill(identity.processIdentifier, 0)
    let failure = errno
    return result != 0 && failure == ESRCH
}

private func terminateBoundaryChild(_ identity: SupervisorWorkerIdentity) -> Bool {
    if boundaryIdentityGone(identity) { return true }
    guard identity.processIdentifier > 1,
          processUsage(identity.processIdentifier)?.startAbsoluteTime == identity.startAbsoluteTime else { return false }
    _ = Darwin.kill(identity.processIdentifier, SIGKILL)
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !boundaryIdentityGone(identity) {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return true
}

private func runBoundarySupervisor(
    supervisorURL: URL,
    root: URL,
    mode: String
) throws -> BoundaryRun {
    let writeRoot = root.appendingPathComponent("write", isDirectory: true)
    let outsideRoot = root.appendingPathComponent("outside", isDirectory: true)
    let outsidePath = outsideRoot.appendingPathComponent("denied-write")
    let identityURL = root.appendingPathComponent("child.json")
    let reportURL = writeRoot.appendingPathComponent("report.json")
    try FileManager.default.createDirectory(at: writeRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
    if mode == "external-readonly-hold" {
        try Data(repeating: 0x4e, count: 1_024 * 1_024).write(to: outsidePath, options: .atomic)
    }
    guard let service = processUsage(getpid()) else { throw CocoaError(.executableLoad) }

    let process = Process()
    process.executableURL = supervisorURL
    process.arguments = [
        "boundary-supervise",
        String(getpid()),
        String(service.startAbsoluteTime),
        identityURL.path,
        writeRoot.path,
        outsidePath.path,
        reportURL.path,
        mode,
    ]
    process.currentDirectoryURL = writeRoot
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let supervisorPID = process.processIdentifier
    var supervisorStart: UInt64?
    for _ in 0..<40 where supervisorStart == nil && process.isRunning {
        supervisorStart = processUsage(supervisorPID)?.startAbsoluteTime
        if supervisorStart == nil { Thread.sleep(forTimeInterval: 0.005) }
    }
    guard let supervisorStart else {
        process.terminate()
        _ = waitForExit(process, timeout: 1)
        throw CocoaError(.executableLoad)
    }
    var observedChild: SupervisorWorkerIdentity?
    defer {
        if process.isRunning {
            _ = terminateBoundaryProcess(process, startAbsoluteTime: supervisorStart)
        }
        if let observedChild { _ = terminateBoundaryChild(observedChild) }
    }
    var boundaryIdentity: BoundarySupervisorIdentity?
    var report: BoundaryChildReport?
    let readyDeadline = ProcessInfo.processInfo.systemUptime + 5
    while ProcessInfo.processInfo.systemUptime < readyDeadline {
        if boundaryIdentity == nil,
           let data = try? Data(contentsOf: identityURL),
           let value = try? JSONDecoder().decode(BoundarySupervisorIdentity.self, from: data),
           processUsage(value.childProcessIdentifier)?.startAbsoluteTime == value.childStartAbsoluteTime,
           kernelParent(supervisorPID, start: supervisorStart) == getpid(),
           kernelParent(value.childProcessIdentifier, start: value.childStartAbsoluteTime) == supervisorPID {
            boundaryIdentity = value
            observedChild = .init(processIdentifier: value.childProcessIdentifier, startAbsoluteTime: value.childStartAbsoluteTime)
        }
        if report == nil,
           let data = try? Data(contentsOf: reportURL),
           let value = try? JSONDecoder().decode(BoundaryChildReport.self, from: data) {
            report = value
        }
        if boundaryIdentity != nil, report != nil { break }
        if !process.isRunning && boundaryResourceModes.contains(mode) { break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard let boundaryIdentity, let report,
          boundaryIdentity.supervisorProcessIdentifier == supervisorPID,
          boundaryIdentity.supervisorParentProcessIdentifier == getpid(),
          boundaryIdentity.supervisorStartAbsoluteTime == supervisorStart,
          kernelParent(supervisorPID, start: supervisorStart) == getpid(),
          kernelParent(boundaryIdentity.childProcessIdentifier, start: boundaryIdentity.childStartAbsoluteTime) == supervisorPID,
          report.schema == "nexgenvideo/bpy-boundary-child/2",
          report.mode == mode,
          report.processIdentifier == boundaryIdentity.childProcessIdentifier,
          report.parentProcessIdentifier == supervisorPID else {
        _ = terminateBoundaryProcess(process, startAbsoluteTime: supervisorStart)
        throw CocoaError(.executableLoad)
    }
    if mode == "denials" {
        try Data("observed".utf8).write(to: writeRoot.appendingPathComponent("service-observed"), options: .atomic)
    }
    let child = SupervisorWorkerIdentity(
        processIdentifier: boundaryIdentity.childProcessIdentifier,
        startAbsoluteTime: boundaryIdentity.childStartAbsoluteTime
    )

    var observedRetainedBytes: UInt64 = 0
    var limitReason: String?
    var internalLinkedWritableDeduplicated = false
    var retentionDenied = false
    if boundaryResourceModes.contains(mode) {
        let retainedResources = try ownedRetainedVnodes(child, roots: [writeRoot])
        observedRetainedBytes = retainedResources.values.reduce(0, +)
        let named = try directoryUsage(
            [writeRoot],
            byteLimit: 512 * 1_024,
            fileLimit: 64
        )
        let quota = try resourceUsage(
            roots: [writeRoot],
            worker: child,
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
        guard validResourceResult else {
            _ = terminateBoundaryProcess(process, startAbsoluteTime: supervisorStart)
            throw CocoaError(.fileReadTooLarge)
        }
        guard terminateBoundaryProcess(process, startAbsoluteTime: supervisorStart) else {
            throw CocoaError(.executableLoad)
        }
    } else {
        guard waitForExit(process, timeout: 5) else {
            _ = terminateBoundaryProcess(process, startAbsoluteTime: supervisorStart)
            throw CocoaError(.executableLoad)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }
    guard terminateBoundaryChild(child) else { throw CocoaError(.executableLoad) }
    let childGone = boundaryIdentityGone(child)
    let supervisorGone = boundaryIdentityGone(.init(processIdentifier: supervisorPID, startAbsoluteTime: supervisorStart))
    return .init(
        supervisorProcessIdentifier: supervisorPID,
        supervisorParentProcessIdentifier: boundaryIdentity.supervisorParentProcessIdentifier,
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
    private let capacity: DispatchSemaphore
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var uploads: [String: UploadRecord] = [:]
    private var checkpointUpload: UploadRecord?
    private var completedInputs: [UUID: [String: (UInt64, String)]] = [:]
    private var jobs: [UUID: JobRecord] = [:]
    private var confirmedRevision: String?
    private var confirmedSceneData: Data?
    private var activeProcess: Process?
    private var activeProcessStartAbsoluteTime: UInt64?
    private var activeProcessExecutable: String?
    private var activeProcessJobID: UUID?
    private var activeProcessAuthorizationID: UUID?
    private var activeProcessAuthorizationURL: URL?
    private var activeProcessAuthorizationToken: String?
    private var activeProcessAuthorized = false
    private var activeWorkerProcessIdentifier: Int32?
    private var runtimeIdentity: BpyRuntimeIdentity?
    private var coldStartSeconds: Double?
    private var servicePeakMemoryBytes: UInt64 = 0
    private var closed = false
    private var storageDescriptor: Int32?
    private let storageScope: URL
    private let queueKey = DispatchSpecificKey<UInt8>()

    init(
        request: BpyOpenSessionRequest,
        root: URL,
        runtimeRoot: URL,
        capacity: DispatchSemaphore,
        storageDescriptor: Int32,
        storageScope: URL
    ) {
        self.storageDescriptor = storageDescriptor
        self.storageScope = storageScope
        self.request = request
        self.root = root
        self.runtimeRoot = runtimeRoot
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
                guard !request.diagnosticOpenFailure else { throw CocoaError(.executableLoad) }
                let started = ProcessInfo.processInfo.systemUptime
                let manifest = try probeRuntime()
                coldStartSeconds = ProcessInfo.processInfo.systemUptime - started
                guard manifest.schema == "nexgenvideo/bpy-probe/1",
                      manifest.pythonVersion == "3.13.15",
                      manifest.bpyVersion == "5.2.2",
                      URL(fileURLWithPath: manifest.executable).resolvingSymlinksInPath()
                        == pythonURL.resolvingSymlinksInPath(),
                      URL(fileURLWithPath: manifest.bpyModule).resolvingSymlinksInPath()
                        == bpyEntryPointURL.resolvingSymlinksInPath() else {
                    throw CocoaError(.executableLoad)
                }
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
                callback.body(failure("worker did not become ready: \(error.localizedDescription)"))
            }
        }
    }

    func matches(_ candidate: BpyOpenSessionRequest) -> Bool {
        request == candidate
    }

    func restore(_ request: BpyRestoreCheckpointRequest, chunk: Data) throws {
        guard isSafeName(request.revision),
              isSHA256(request.sha256),
              request.totalBytes <= self.request.limits.outputBytes,
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
            if let data = confirmedSceneData {
                guard UInt64(data.count) == request.totalBytes, sha256(data) == request.sha256,
                      data.subdata(in: Int(request.offset)..<Int(request.offset) + chunk.count) == chunk else {
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
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                upload = UploadRecord(
                    url: url,
                    totalBytes: request.totalBytes,
                    expectedSHA256: request.sha256,
                    handle: try FileHandle(forWritingTo: url)
                )
                checkpointUpload = upload
            }
            do {
                try append(chunk, offset: request.offset, finalChunk: request.finalChunk, to: upload)
                if request.finalChunk {
                    let data = try Data(contentsOf: upload.url)
                    guard UInt64(data.count) == upload.totalBytes,
                          sha256(data) == upload.expectedSHA256,
                          BpyBlendFileFormat.accepts(data) else { throw CocoaError(.fileReadCorruptFile) }
                    confirmedSceneData = data
                    checkpointUpload = nil
                    try? FileManager.default.removeItem(at: upload.url)
                }
            } catch {
                try? upload.handle.close()
                try? FileManager.default.removeItem(at: upload.url)
                checkpointUpload = nil
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
            guard !closed else { throw CocoaError(.fileWriteNoPermission) }
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
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                do {
                    upload = UploadRecord(url: url, totalBytes: request.totalBytes,
                        expectedSHA256: request.sha256, handle: try FileHandle(forWritingTo: url))
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
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
                try? upload.handle.close()
                try? FileManager.default.removeItem(at: upload.url)
                uploads.removeValue(forKey: key)
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
        if offset < upload.receivedBytes {
            guard offset + UInt64(chunk.count) <= upload.receivedBytes else {
                throw CocoaError(.fileWriteUnknown)
            }
            var existing = Data(count: chunk.count)
            let count = existing.withUnsafeMutableBytes {
                pread(upload.handle.fileDescriptor, $0.baseAddress, chunk.count, off_t(offset))
            }
            guard count == chunk.count, existing == chunk else {
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
            try upload.handle.close()
            guard upload.receivedBytes == upload.totalBytes,
                  try sha256(upload.url) == upload.expectedSHA256 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    func submit(_ request: BpyRunJobRequest) -> BpyServiceResponse {
        let decision: (JobRecord?, BpyServiceResponse) = lock.access {
            purgeExpiredResults()
            if closed {
                return (nil, .init(ok: false, message: "session is closed"))
            }
            guard isSHA256(request.fingerprint) else {
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
            guard jobs.count < 1_024 else {
                return (nil, .init(ok: false, message: "session job limit reached; rotate the document session"))
            }
            guard !jobs.values.contains(where: {
                [.accepted, .running, .awaitingConfirmation].contains($0.state)
            }) else {
                return (nil, .init(ok: false, message: "session already has an active job"))
            }
            guard request.expectedRevision == confirmedRevision,
                  confirmedRevision == nil || confirmedSceneData != nil else {
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
            let job = JobRecord(request: request, timeoutSeconds: timeout)
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
            purgeExpiredResults()
            guard let job = jobs[jobID] else {
                return .init(ok: false, message: "unknown job")
            }
            return response(for: job)
        }
    }

    func authorize(_ request: BpyAuthorizeProcessRequest) throws -> BpyServiceResponse {
        try lock.access {
            guard !closed,
                  let job = jobs[request.jobID],
                  job.state == .running,
                  activeProcessJobID == request.jobID,
                  activeProcessAuthorizationID == request.authorizationID,
                  activeProcess?.processIdentifier == request.processIdentifier,
                  activeProcess?.isRunning == true,
                  activeProcessStartAbsoluteTime == request.processStartAbsoluteTime,
                  processUsage(request.processIdentifier)?.startAbsoluteTime
                    == request.processStartAbsoluteTime,
                  activeProcessExecutable == request.processExecutable,
                  let authorizationURL = activeProcessAuthorizationURL,
                  let authorizationToken = activeProcessAuthorizationToken else {
                throw CocoaError(.fileWriteNoPermission)
            }
            if !activeProcessAuthorized {
                try Data(authorizationToken.utf8).write(to: authorizationURL, options: .atomic)
                activeProcessAuthorized = true
            }
            return response(for: job)
        }
    }

    func output(_ request: BpyReadOutputRequest) throws -> (BpyServiceResponse, Data) {
        guard isSafeName(request.name), request.maximumBytes > 0,
              request.maximumBytes <= 4 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return try lock.access {
            purgeExpiredResults()
            guard let job = jobs[request.jobID], !job.resultExpired,
                  [.awaitingConfirmation, .confirmed].contains(job.state),
                  let output = job.outputs.first(where: { $0.name == request.name }),
                  let data = job.outputData[request.name] else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            guard request.offset <= output.byteCount else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let end = min(output.byteCount, request.offset + UInt64(request.maximumBytes))
            return (
                response(for: job),
                data.subdata(in: Int(request.offset)..<Int(end))
            )
        }
    }

    func confirm(_ request: BpyConfirmJobRequest) throws -> BpyServiceResponse {
        guard isSafeName(request.revision), isSHA256(request.sceneSHA256) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return try lock.access {
            guard !closed else { throw CocoaError(.fileWriteNoPermission) }
            purgeExpiredResults()
            if let job = jobs[request.jobID], job.state == .confirmed,
               confirmedRevision == request.revision, let data = confirmedSceneData,
               sha256(data) == request.sceneSHA256 { return response(for: job) }
            guard let job = jobs[request.jobID], job.state == .awaitingConfirmation,
                  !job.resultExpired else {
                throw CocoaError(.fileWriteNoPermission)
            }
            guard request.revision != confirmedRevision,
                  let confirmedData = job.outputData["scene.blend"],
                  sha256(confirmedData) == request.sceneSHA256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            confirmedRevision = request.revision
            confirmedSceneData = confirmedData
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
                    discardStaging()
                    try? FileManager.default.removeItem(at: jobDirectory(jobID))
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
            stopActiveProcess(jobID: jobID)
            lock.access { if !closed { try? FileManager.default.removeItem(at: jobDirectory(jobID)) } }
        }
        return status(jobID)
    }

    func close() {
        lock.access { closed = true }
        stopActiveProcess()
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync { } }
        lock.access {
            for upload in uploads.values { try? upload.handle.close() }
            try? checkpointUpload?.handle.close()
            uploads.removeAll()
            checkpointUpload = nil
        }
        try? FileManager.default.removeItem(at: root)
        let descriptor = lock.access { () -> Int32? in
            defer { storageDescriptor = nil }
            return storageDescriptor
        }
        if let descriptor {
            Darwin.close(descriptor)
            storageScope.stopAccessingSecurityScopedResource()
        }
    }

    private func execute(_ job: JobRecord) {
        capacity.wait()
        defer {
            lock.access {
                completedInputs.removeValue(forKey: job.id)
                job.source = nil
            }
            capacity.signal()
        }
        let began = ProcessInfo.processInfo.systemUptime
        let deadline = began + Double(job.timeoutSeconds)
        guard lock.access({
            guard job.state == .accepted, !closed else { return false }
            job.state = .running
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
                deadline: deadline,
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
            let verification = try verify(job: job, deadline: deadline)
            try enforceStoredResources(job)
            let collected = try collectOutputs(job.id)
            guard collected.data["scene.blend"].map(sha256) == verification.manifest.sceneSHA256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try enforceServiceMemory(job)
            let verificationData = try JSONEncoder().encode(verification.manifest)
            let collectedBytes = collected.descriptors.reduce(UInt64(0)) { $0 + $1.byteCount }
            guard BpyOutputContract.permitsHostManifest(workerFileCount: collected.descriptors.count,
                workerBytes: collectedBytes, manifestBytes: UInt64(verificationData.count),
                fileLimit: request.limits.files, byteLimit: request.limits.outputBytes) else {
                throw CocoaError(.fileReadTooLarge)
            }
            var descriptors = collected.descriptors
            var outputData = collected.data
            descriptors.append(.init(
                name: "verification.json",
                byteCount: UInt64(verificationData.count),
                sha256: sha256(verificationData),
                mediaType: "application/json"
            ))
            outputData["verification.json"] = verificationData
            let wallSeconds = ProcessInfo.processInfo.systemUptime - began
            lock.access {
                guard job.state == .running else { return }
                job.outputs = descriptors
                job.outputData = outputData
                job.stdout = boundedLogText(worker.log, bytes: request.limits.stdoutBytes)
                job.metrics = [
                    "job_wall_seconds": wallSeconds,
                    "worker_wall_seconds": worker.duration,
                    "verification_seconds": verification.manifest.verificationSeconds,
                    "worker_peak_memory_bytes": Double(worker.peakMemoryBytes),
                    "verifier_peak_memory_bytes": Double(verification.process.peakMemoryBytes),
                    "service_peak_memory_bytes": Double(servicePeakMemoryBytes),
                    "physical_storage_capacity_bytes": Double(request.storage?.capacityBytes ?? 0),
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
                    "rlimit_as_bytes": Double(request.limits.memoryBytes),
                ]
                if verification.autoexecPositive {
                    job.metrics["autoexec_positive_control"] = 1
                }
                job.progress.append(.init(sequence: 3, stage: "complete", fraction: 1))
                job.source = nil
                job.state = .awaitingConfirmation
                completedInputs.removeValue(forKey: job.id)
                job.terminalAt = Date()
                enforceResultRetentionBudget(retaining: job.id)
            }
            try? FileManager.default.removeItem(at: directory)
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
            stopActiveProcess()
            try? FileManager.default.removeItem(at: jobDirectory(job.id))
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

    private func enforceServiceMemory(_ job: JobRecord) throws {
        let footprint = processUsage(getpid())?.physicalFootprint ?? 0
        lock.access { servicePeakMemoryBytes = max(servicePeakMemoryBytes, footprint) }
        guard footprint <= request.limits.memoryBytes else {
            lock.access {
                guard job.state == .running else { return }
                job.state = .resourceLimited
                job.message = "job exceeded the service-memory limit"
                job.terminalAt = Date()
            }
            throw CocoaError(.fileReadTooLarge)
        }
    }

    private func verify(
        job: JobRecord,
        deadline: Double
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
            at: verificationRoot.appendingPathComponent("verify.json")
        )
        let result = try runManagedProcess(
            mode: "verify",
            configuration: config,
            processRoot: verificationRoot,
            deadline: deadline,
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
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(VerificationManifest.self, from: data)
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
            positive = try runAutoexecPositiveControl(job: job, deadline: deadline)
        }
        return (manifest, result, positive)
    }

    private func runAutoexecPositiveControl(job: JobRecord, deadline: Double) throws -> Bool {
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
            at: controlRoot.appendingPathComponent("autoexec.json")
        )
        let result = try runManagedProcess(
            mode: "autoexec-positive",
            configuration: config,
            processRoot: controlRoot,
            deadline: deadline,
            job: job
        )
        try requireSuccessful(result, job: job)
        let manifest = try JSONDecoder().decode(
            AutoexecManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schema == "nexgenvideo/bpy-autoexec-positive/1",
              manifest.jobID == job.id.uuidString,
              manifest.processIdentifier == result.workerProcessIdentifier,
              manifest.autorunMarkerPresent else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return true
    }

    private func probeRuntime() throws -> ProbeManifest {
        let probeRoot = root.appendingPathComponent("probe-worker", isDirectory: true)
        try? FileManager.default.removeItem(at: probeRoot)
        try FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        let manifestURL = probeRoot.appendingPathComponent("manifest.json")
        let config = try writeConfiguration(
            baseConfiguration(processRoot: probeRoot, cpuSeconds: 120)
                .merging(["manifest": manifestURL.path]) { _, new in new },
            at: probeRoot.appendingPathComponent("probe.json")
        )
        let result = try runManagedProcess(
            mode: "probe",
            configuration: config,
            processRoot: probeRoot,
            deadline: ProcessInfo.processInfo.systemUptime + 120,
            job: nil
        )
        guard result.limitReason == nil, result.exitStatus == 0 else {
            throw CocoaError(.executableLoad)
        }
        let manifest = try JSONDecoder().decode(
            ProbeManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.processIdentifier == result.workerProcessIdentifier else {
            throw CocoaError(.executableLoad)
        }
        try? FileManager.default.removeItem(at: probeRoot)
        return manifest
    }

    private func runManagedProcess(
        mode: String,
        configuration: URL,
        processRoot: URL,
        deadline: Double,
        job: JobRecord?,
        injectSupervisorIdentityWriteFailure: Bool = false,
        injectSupervisorIdentityCaptureFailure: Bool = false
    ) throws -> ManagedProcessResult {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path),
              FileManager.default.isExecutableFile(atPath: supervisorURL.path),
              FileManager.default.fileExists(atPath: workerURL.path),
              FileManager.default.fileExists(atPath: sitePackagesURL.path) else {
            throw CocoaError(.executableNotLoadable)
        }
        for name in ["tmp", "home", "blender-config", "blender-scripts", "blender-data"] {
            try FileManager.default.createDirectory(
                at: processRoot.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let output = Pipe()
        let errors = Pipe()
        let log = BoundedLog(limit: request.limits.stdoutBytes)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { log.append(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { log.append(data) }
        }
        let controlRoot = root.appendingPathComponent(
            "process-control/\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: controlRoot, withIntermediateDirectories: true)
        let authorizationURL = controlRoot.appendingPathComponent("authorized")
        let identityURL = controlRoot.appendingPathComponent("worker.json")
        let authorizationID = UUID()
        let authorizationToken = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
        guard let serviceUsage = processUsage(getpid()) else {
            throw CocoaError(.executableLoad)
        }
        if job == nil {
            try Data(authorizationToken.utf8).write(to: authorizationURL, options: .atomic)
        }
        let process = Process()
        process.executableURL = supervisorURL
        process.arguments = [
            "supervise",
            String(getpid()),
            String(serviceUsage.startAbsoluteTime),
            authorizationURL.path,
            authorizationToken,
            identityURL.path,
            processRoot.path,
            pythonURL.path,
            workerURL.path,
            mode,
            configuration.path,
        ]
        process.currentDirectoryURL = processRoot
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        var environment = [
            "HOME": processRoot.appendingPathComponent("home").path,
            "TMPDIR": processRoot.appendingPathComponent("tmp").path,
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "",
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "BLENDER_USER_CONFIG": processRoot.appendingPathComponent("blender-config").path,
            "BLENDER_USER_SCRIPTS": processRoot.appendingPathComponent("blender-scripts").path,
            "BLENDER_USER_DATAFILES": processRoot.appendingPathComponent("blender-data").path,
        ]
        if injectSupervisorIdentityWriteFailure {
            environment["NGV_BPY_SUPERVISOR_FAIL_AFTER_CHILD_START"] = "1"
        }
        if injectSupervisorIdentityCaptureFailure {
            environment["NGV_BPY_SUPERVISOR_FAIL_CHILD_IDENTITY_CAPTURE"] = "1"
            environment["NGV_BPY_SUPERVISOR_CHILD_IGNORE_TERM"] = "1"
        }
        process.environment = environment
        let began = ProcessInfo.processInfo.systemUptime
        try lock.access {
            guard !closed, job == nil || job?.state == .running else { throw CocoaError(.userCancelled) }
            try process.run()
            activeProcess = process
            activeProcessJobID = job?.id
        }
        let supervisorProcessIdentifier = process.processIdentifier
        defer {
            if process.isRunning {
                stopProcess(process)
                process.waitUntilExit()
            }
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            lock.access {
                if activeProcess === process {
                    activeProcess = nil
                    activeProcessStartAbsoluteTime = nil
                    activeProcessExecutable = nil
                    activeProcessJobID = nil
                    activeProcessAuthorizationID = nil
                    activeProcessAuthorizationURL = nil
                    activeProcessAuthorizationToken = nil
                    activeProcessAuthorized = false
                    activeWorkerProcessIdentifier = nil
                }
            }
            try? FileManager.default.removeItem(at: controlRoot)
        }
        var initialUsage: ProcessUsage?
        for _ in 0..<20 where initialUsage == nil && process.isRunning {
            initialUsage = processUsage(supervisorProcessIdentifier)
            if initialUsage == nil { Thread.sleep(forTimeInterval: 0.005) }
        }
        guard let initialUsage else {
            stopProcess(process)
            process.waitUntilExit()
            throw CocoaError(.executableLoad)
        }
        lock.access {
            guard activeProcess === process else { return }
            activeProcessStartAbsoluteTime = initialUsage.startAbsoluteTime
            activeProcessExecutable = supervisorURL.resolvingSymlinksInPath().path
            activeProcessJobID = job?.id
            activeProcessAuthorizationID = job == nil ? nil : authorizationID
            activeProcessAuthorizationURL = job == nil ? nil : authorizationURL
            activeProcessAuthorizationToken = job == nil ? nil : authorizationToken
            activeProcessAuthorized = job == nil
        }
        var peakMemory = initialUsage.physicalFootprint
        var peakDisk: UInt64 = 0
        var peakFiles = 0
        var peakDescendants = 0
        var limitReason: String?
        var workerIdentity: SupervisorWorkerIdentity?
        while process.isRunning {
            let now = ProcessInfo.processInfo.systemUptime
            let descendants = try processTree(root: supervisorProcessIdentifier, start: initialUsage.startAbsoluteTime)
            let unexpectedDescendants = max(0, descendants.count - 1)
            peakDescendants = max(peakDescendants, unexpectedDescendants)
            let processFootprint = ([supervisorProcessIdentifier] + descendants)
                .compactMap { processUsage($0)?.physicalFootprint }
                .reduce(UInt64(0), +)
            peakMemory = max(peakMemory, processFootprint)
            if workerIdentity == nil,
               let data = try? Data(contentsOf: identityURL),
               let decoded = try? JSONDecoder().decode(SupervisorWorkerIdentity.self, from: data),
               processUsage(decoded.processIdentifier)?.startAbsoluteTime == decoded.startAbsoluteTime {
                workerIdentity = decoded
                lock.access {
                    if activeProcess === process {
                        activeWorkerProcessIdentifier = decoded.processIdentifier
                    }
                }
            }
            let serviceFootprint = processUsage(getpid())?.physicalFootprint ?? 0
            lock.access {
                servicePeakMemoryBytes = max(servicePeakMemoryBytes, serviceFootprint)
            }
            let resourceRoots = job.map { workerWritableRoots($0.id) } ?? [processRoot]
            let accountingWorker = workerIdentity ?? descendants.first.flatMap { pid in
                processUsage(pid).map { SupervisorWorkerIdentity(processIdentifier: pid, startAbsoluteTime: $0.startAbsoluteTime) }
            }
            let disk = try resourceUsage(
                roots: resourceRoots,
                worker: accountingWorker,
                byteLimit: request.limits.diskBytes,
                fileLimit: request.limits.files
            )
            peakDisk = max(peakDisk, disk.bytes)
            peakFiles = max(peakFiles, disk.files)
            if lock.access({ closed || activeProcess !== process }) {
                stopProcess(process)
            } else if let job, lock.access({ job.state != .running }) {
                stopProcess(process)
            } else if now >= deadline {
                limitReason = "deadline"
                stopProcess(process)
            } else if peakMemory > request.limits.memoryBytes {
                limitReason = "memory"
                stopProcess(process)
            } else if serviceFootprint > request.limits.memoryBytes {
                limitReason = "service-memory"
                stopProcess(process)
            } else if let resourceReason = disk.limitReason {
                limitReason = resourceReason
                stopProcess(process)
            } else if unexpectedDescendants > 0 {
                limitReason = "process-count"
                stopProcess(process)
            }
            if process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
        }
        process.waitUntilExit()
        do { let finalUsage = try resourceUsage(roots: job.map { workerWritableRoots($0.id) } ?? [processRoot], worker: nil,
                byteLimit: request.limits.diskBytes, fileLimit: request.limits.files)
            peakDisk = max(peakDisk, finalUsage.bytes); peakFiles = max(peakFiles, finalUsage.files)
            if limitReason == nil { limitReason = finalUsage.limitReason }
        } catch { if limitReason == nil { throw error } }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        let remainingOutput = output.fileHandleForReading.readDataToEndOfFile()
        let remainingErrors = errors.fileHandleForReading.readDataToEndOfFile()
        log.append(remainingOutput)
        log.append(remainingErrors)
        if workerIdentity == nil,
           let data = try? Data(contentsOf: identityURL) {
            workerIdentity = try? JSONDecoder().decode(SupervisorWorkerIdentity.self, from: data)
        }
        guard process.terminationStatus != 0 || workerIdentity != nil || limitReason != nil else {
            throw CocoaError(.executableLoad)
        }
        return ManagedProcessResult(
            workerProcessIdentifier: workerIdentity?.processIdentifier ?? -1,
            exitStatus: process.terminationStatus,
            duration: ProcessInfo.processInfo.systemUptime - began,
            peakMemoryBytes: peakMemory,
            peakDiskBytes: peakDisk,
            peakFileCount: peakFiles,
            peakDescendantCount: peakDescendants,
            limitReason: limitReason,
            log: log.text
        )
    }

    private func stopActiveProcess(jobID: UUID? = nil) {
        guard let process = lock.access({
            jobID == nil || activeProcessJobID == jobID ? activeProcess : nil
        }) else { return }
        stopProcess(process)
        while lock.access({ activeProcess === process }) {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private var geometryLimits: [String: Any] {
        ["objects": request.limits.objects, "vertices": request.limits.vertices, "polygons": request.limits.polygons,
         "renderWidth": request.limits.renderWidth, "renderHeight": request.limits.renderHeight,
         "renderPixels": request.limits.renderPixels]
    }

    private func baseConfiguration(processRoot: URL, cpuSeconds: Int) -> [String: Any] {
        [
            "sitePackages": sitePackagesURL.path,
            "memoryBytes": request.limits.memoryBytes,
            "outputBytes": request.limits.outputBytes,
            "cpuSeconds": max(2, cpuSeconds + 1),
        ]
    }

    private func writeConfiguration(_ value: [String: Any], at url: URL) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        return url
    }

    private func writeConfirmedCheckpoint(for job: JobRecord) throws -> URL? {
        guard let data = lock.access({ confirmedSceneData }) else { return nil }
        let directory = jobDirectory(job.id).appendingPathComponent("bootstrap", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("confirmed.blend")
        try data.write(to: url, options: .atomic)
        return url
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

    private func collectOutputs(
        _ jobID: UUID
    ) throws -> (descriptors: [BpyOutputDescriptor], data: [String: Data]) {
        let directory = outputDirectory(jobID)
        let values = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard BpyOutputContract.acceptsWorkerNames(values.map(\.lastPathComponent)) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        guard values.count <= min(256, request.limits.files) else {
            throw CocoaError(.fileReadTooLarge)
        }
        var total: UInt64 = 0
        var result: [BpyOutputDescriptor] = []
        var outputData: [String: Data] = [:]
        for url in values.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard isSafeName(url.lastPathComponent),
                  url.lastPathComponent != "verification.json" else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_nlink == 1,
                  status.st_size >= 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            total += UInt64(status.st_size)
            guard total <= request.limits.outputBytes else { throw CocoaError(.fileReadTooLarge) }
            guard let mediaType = mediaType(url.pathExtension) else { throw CocoaError(.fileReadInvalidFileName) }
            let data = try Data(contentsOf: url)
            guard Int64(data.count) == Int64(status.st_size) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try validateMagic(data, mediaType: mediaType)
            if mediaType == "image/png" { try validatePNGDimensions(data) }
            let digest = sha256(data)
            result.append(.init(
                name: url.lastPathComponent,
                byteCount: UInt64(data.count),
                sha256: digest,
                mediaType: mediaType
            ))
            outputData[url.lastPathComponent] = data
        }
        guard result.contains(where: { $0.name == "scene.blend" }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (result, outputData)
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

    private func purgeExpiredResults() {
        let cutoff = Date().addingTimeInterval(-resultRetentionSeconds)
        for job in jobs.values where job.terminalAt.map({ $0 < cutoff }) == true {
            if job.state == .awaitingConfirmation {
                job.state = .rejected
                job.message = "candidate result expired"
            }
            job.expireResult()
            completedInputs.removeValue(forKey: job.id)
        }
    }

    private func enforceResultRetentionBudget(retaining retainedID: UUID) {
        let budget = min(
            request.limits.diskBytes,
            min(request.limits.memoryBytes / 2, request.limits.outputBytes * 4)
        )
        var retainedBytes = jobs.values.reduce(UInt64(0)) { partial, job in
            partial + job.outputs.reduce(UInt64(0)) { $0 + $1.byteCount }
        }
        let candidates = jobs.values
            .filter { $0.id != retainedID && !$0.resultExpired && $0.terminalAt != nil }
            .sorted { ($0.terminalAt ?? .distantFuture) < ($1.terminalAt ?? .distantFuture) }
        for candidate in candidates where retainedBytes > budget {
            let bytes = candidate.outputs.reduce(UInt64(0)) { $0 + $1.byteCount }
            if candidate.state == .awaitingConfirmation {
                candidate.state = .rejected
                candidate.message = "candidate result expired under the session retention budget"
            }
            candidate.expireResult()
            completedInputs.removeValue(forKey: candidate.id)
            retainedBytes = retainedBytes > bytes ? retainedBytes - bytes : 0
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
            activeWorkerProcessIdentifier: ownsActiveProcess ? activeWorkerProcessIdentifier : nil
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
        runtimeRoot.appendingPathComponent("python/bin/python3")
    }

    private var workerURL: URL {
        runtimeRoot.appendingPathComponent("worker.py")
    }

    private var supervisorURL: URL {
        runtimeRoot.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers/NexGenVideoBpySupervisor")
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
        jobDirectory(jobID).appendingPathComponent("worker", isDirectory: true)
    }

    private func verificationDirectory(_ jobID: UUID) -> URL {
        jobDirectory(jobID).appendingPathComponent("verification", isDirectory: true)
    }

    private func autoexecDirectory(_ jobID: UUID) -> URL {
        jobDirectory(jobID).appendingPathComponent("autoexec-positive", isDirectory: true)
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
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("BpyRuntime", isDirectory: true)
        super.init()
    }

    func runBoundaryProbe(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyBoundaryProbeRequest.self, from: data)
            guard request.schema == "nexgenvideo/bpy-boundary-probe-request/1" else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let app = Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let marker = app.appendingPathComponent(
                "Contents/Resources/BPY_BOUNDARY_PROBE_NONPRODUCT_CI"
            )
            let supervisor = app.appendingPathComponent(
                "Contents/Helpers/NexGenVideoBpySupervisor"
            )
            guard FileManager.default.fileExists(atPath: marker.path),
                  FileManager.default.isExecutableFile(atPath: supervisor.path),
                  let service = processUsage(getpid()) else {
                throw CocoaError(.fileReadNoPermission)
            }
            capacity.wait()
            defer { capacity.signal() }
            let probeRoot = sessionsRoot.appendingPathComponent(
                "boundary-\(request.nonce.uuidString)",
                isDirectory: true
            )
            try? FileManager.default.removeItem(at: probeRoot)
            try FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: probeRoot) }
            let first = try runBoundarySupervisor(
                supervisorURL: supervisor,
                root: probeRoot.appendingPathComponent("denials", isDirectory: true),
                mode: "denials"
            )
            let openUnlinked = try runBoundarySupervisor(
                supervisorURL: supervisor,
                root: probeRoot.appendingPathComponent("open-unlinked", isDirectory: true),
                mode: "open-unlinked-hold"
            )
            let readOnlyUnlinked = try runBoundarySupervisor(
                supervisorURL: supervisor,
                root: probeRoot.appendingPathComponent("readonly-unlinked", isDirectory: true),
                mode: "readonly-unlinked-hold"
            )
            let mappedUnlinked = try runBoundarySupervisor(
                supervisorURL: supervisor,
                root: probeRoot.appendingPathComponent("mapped-unlinked", isDirectory: true),
                mode: "mapped-unlinked-hold"
            )
            let externalReadOnly = try runBoundarySupervisor(
                supervisorURL: supervisor,
                root: probeRoot.appendingPathComponent("external-readonly", isDirectory: true),
                mode: "external-readonly-hold"
            )
            let internalLinkedWritable = try runBoundarySupervisor(
                supervisorURL: supervisor,
                root: probeRoot.appendingPathComponent("internal-linked", isDirectory: true),
                mode: "internal-linked-writable-hold"
            )
            let fileportRetention = try runBoundarySupervisor(
                supervisorURL: supervisor,
                root: probeRoot.appendingPathComponent("fileport-retention", isDirectory: true),
                mode: "fileport-unlinked-hold"
            )
            let followup = try runBoundarySupervisor(
                supervisorURL: supervisor,
                root: probeRoot.appendingPathComponent("followup", isDirectory: true),
                mode: "denials"
            )
            guard first.supervisorGone,
                  first.childGone,
                  openUnlinked.supervisorGone,
                  openUnlinked.childGone,
                  readOnlyUnlinked.supervisorGone,
                  readOnlyUnlinked.childGone,
                  mappedUnlinked.supervisorGone,
                  mappedUnlinked.childGone,
                  externalReadOnly.supervisorGone,
                  externalReadOnly.childGone,
                  internalLinkedWritable.supervisorGone,
                  internalLinkedWritable.childGone,
                  fileportRetention.supervisorGone,
                  fileportRetention.childGone,
                  followup.supervisorGone,
                  followup.childGone else {
                throw CocoaError(.executableLoad)
            }
            let retainedRuns = [openUnlinked, readOnlyUnlinked, mappedUnlinked]
            let result = BpyBoundaryProbeResult(
                nonce: request.nonce,
                serviceProcessIdentifier: getpid(),
                serviceStartAbsoluteTime: service.startAbsoluteTime,
                supervisorProcessIdentifier: first.supervisorProcessIdentifier,
                supervisorParentProcessIdentifier: first.supervisorParentProcessIdentifier,
                supervisorStartAbsoluteTime: first.supervisorStartAbsoluteTime,
                childProcessIdentifier: first.child.processIdentifier,
                childStartAbsoluteTime: first.child.startAbsoluteTime,
                childParentProcessIdentifier: first.report.parentProcessIdentifier,
                allowedWriteSucceeded: first.report.allowedWriteSucceeded,
                outsideWriteDeniedErrno: first.report.outsideWriteDeniedErrno,
                forkDeniedErrno: first.report.forkDeniedErrno,
                networkDeniedErrno: first.report.networkDeniedErrno,
                signalDeniedErrnos: first.report.signalDeniedErrnos,
                unlinkedBytesObserved: retainedRuns
                    .map(\.observedRetainedBytes)
                    .min() ?? 0,
                unlinkedLimitReason: retainedRuns.allSatisfy({ $0.limitReason == "disk" })
                    ? "disk"
                    : "",
                cleanupSupervisorGone: retainedRuns.allSatisfy(\.supervisorGone),
                cleanupChildGone: retainedRuns.allSatisfy(\.childGone),
                internalLinkedWritableDeduplicated: internalLinkedWritable
                    .internalLinkedWritableDeduplicated,
                fileportRetentionDeniedErrno: fileportRetention.report.retentionDeniedErrno,
                fileportRetentionDenied: fileportRetention.retentionDenied,
                fileportBytesObserved: fileportRetention.observedRetainedBytes,
                fileportLimitReason: fileportRetention.limitReason ?? "",
                healthyFollowupSucceeded: externalReadOnly.limitReason == nil
                    && externalReadOnly.observedRetainedBytes < boundaryProbeResourceBytes
                    && followup.supervisorGone
                    && followup.childGone
                    && followup.report.allowedWriteSucceeded
            )
            reply(try JSONEncoder().encode(result))
        } catch {
            reply(failure("boundary probe failed: \(error.localizedDescription)"))
        }
    }

    func openSession(_ data: Data, owner: UUID, withReply reply: @escaping (Data) -> Void) {
        var requestedID: UUID?
        do {
            let request = try JSONDecoder().decode(BpyOpenSessionRequest.self, from: data)
            guard request.limits.isValid, !request.documentID.isEmpty,
                  request.documentID.count <= 256,
                  request.confirmedRevision.map(isSafeName) ?? true else {
                reply(failure("invalid session contract"))
                return
            }
            requestedID = request.sessionID
            let claimed = lock.access { () -> Bool in
                guard !closedConnections.contains(owner), retiringSessions[request.sessionID] == nil,
                      connectionOwners[request.sessionID] == nil || connectionOwners[request.sessionID] == owner else { return false }
                connectionOwners[request.sessionID] = owner
                return true
            }
            guard claimed else { throw CocoaError(.fileWriteNoPermission) }
            guard let storage = request.storage else {
                guard let identity = processUsage(getpid()) else { throw CocoaError(.executableLoad) }
                let inUse = lock.access {
                    (Array(sessions.values) + Array(retiringSessions.values)).compactMap { $0.request.storage?.id }
                }
                reply(encoded(.init(ok: true, storagePreparation: .init(
                    id: request.sessionID, servicePID: getpid(),
                    serviceStart: identity.startAbsoluteTime, inUseStorageIDs: inUse
                ))))
                return
            }
            var stale = false
            let scope = try URL(resolvingBookmarkData: storage.bookmark, options: .withoutUI,
                                relativeTo: nil, bookmarkDataIsStale: &stale)
            var ownsScope = true
            defer { if ownsScope { scope.stopAccessingSecurityScopedResource() } }
            guard !stale, scope.path == storage.mountPath else { throw CocoaError(.fileReadNoPermission) }
            var descriptor: Int32? = try BpyStoragePaths.validateMount(storage, maximumBytes: request.limits.physicalStorageBytes)
            defer { if let descriptor { Darwin.close(descriptor) } }
            var retired: ServiceSession?
            let session: ServiceSession = try lock.access {
                guard !closedConnections.contains(owner), connectionOwners[request.sessionID] == owner,
                      retiringSessions.isEmpty else { throw CocoaError(.fileWriteNoPermission) }
                if let existing = sessions[request.sessionID] {
                    guard existing.matches(request) else {
                        throw CocoaError(.fileWriteInvalidFileName)
                    }
                    return existing
                }
                if let existing = sessions.values.first {
                    guard sessions.count == 1,
                          connectionOwners[existing.request.sessionID] == owner,
                          existing.request.documentID == request.documentID else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    retired = existing
                    retiringSessions[existing.request.sessionID] = existing
                    sessions.removeAll()
                }
                let session = ServiceSession(
                    request: request,
                    root: URL(fileURLWithPath: storage.mountPath).appendingPathComponent(request.sessionID.uuidString),
                    runtimeRoot: runtimeRoot,
                    capacity: capacity,
                    storageDescriptor: descriptor!, storageScope: scope
                )
                descriptor = nil
                ownsScope = false
                sessions[request.sessionID] = session
                return session
            }
            if let retired { finishClosing(retired) }
            session.open { [weak self, weak session] response in
                if (try? JSONDecoder().decode(BpyServiceResponse.self, from: response).ok) != true,
                   let self, let session {
                    let removed = self.lock.access { () -> ServiceSession? in
                        guard self.sessions[request.sessionID] === session else { return nil }
                        self.retiringSessions[request.sessionID] = session
                        return self.sessions.removeValue(forKey: request.sessionID)
                    }
                    if let removed { self.finishClosing(removed) }
                }
                reply(response)
            }
        } catch {
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
            Array(sessions.keys).compactMap { retire($0) }
        }
        closing.forEach { finishClosing($0) }
        let complete = lock.access { retiringSessions.isEmpty }
        reply(complete ? encoded(.init(ok: true)) : failure("session cleanup is still in progress"))
    }

    private func retire(_ id: UUID) -> ServiceSession? {
        guard let session = sessions.removeValue(forKey: id) else { return nil }
        retiringSessions[id] = session
        return session
    }

    private func finishClosing(_ session: ServiceSession) {
        session.close()
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

    init(service: BpyRuntimeService) {
        self.service = service
    }

    func runBoundaryProbe(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard lock.access({ !invalidated }) else {
            reply(failure("XPC connection is unavailable"))
            return
        }
        service.runBoundaryProbe(request, withReply: reply)
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
        service.openSession(request, owner: ownerID) { [self] response in
            guard (try? JSONDecoder().decode(BpyServiceResponse.self, from: response).ok) == true else {
                reply(response)
                return
            }
            let accepted = lock.access { () -> Bool in
                guard !invalidated else { return false }
                sessionIDs.insert(value.sessionID)
                return true
            }
            guard accepted else {
                service.invalidateSessions([value.sessionID], owner: ownerID)
                reply(failure("XPC connection is unavailable"))
                return
            }
            reply(response)
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
        service.cancelJob(request, owner: ownerID, withReply: reply)
    }

    func closeSession(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard let value = try? JSONDecoder().decode(BpySessionReference.self, from: request),
              lock.access({ !invalidated && sessionIDs.contains(value.sessionID) }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.closeSession(request, owner: ownerID) { [self] response in
            if (try? JSONDecoder().decode(BpyServiceResponse.self, from: response).ok) == true {
                lock.access { _ = sessionIDs.remove(value.sessionID) }
            }
            reply(response)
        }
    }

    func shutdown(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        let identifiers = lock.access { () -> Set<UUID> in
            invalidated = true
            return sessionIDs
        }
        let complete = service.invalidateConnection(owner: ownerID)
        if complete { lock.access { sessionIDs.subtract(identifiers) } }
        reply(complete ? encoded(.init(ok: true)) : failure("session cleanup is still in progress"))
    }

    func invalidate() {
        lock.access {
            invalidated = true
            sessionIDs.removeAll()
        }
        _ = service.invalidateConnection(owner: ownerID)
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = BpyRuntimeService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let exported = BpyRuntimeConnection(service: service)
        connection.exportedInterface = NSXPCInterface(with: BpyRuntimeServiceProtocol.self)
        connection.exportedObject = exported
        connection.interruptionHandler = { [weak exported] in exported?.invalidate() }
        connection.invalidationHandler = { [weak exported] in exported?.invalidate() }
        connection.resume()
        return true
    }
}

let listener = NSXPCListener.service()
private let listenerDelegate = ListenerDelegate()
listener.delegate = listenerDelegate
listener.resume()
