import BpyRuntimeProtocol
import Darwin
import Foundation

@_silgen_name("proc_pid_rusage")
private func monitorRusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32
@_silgen_name("proc_pidinfo")
private func monitorPIDInfo(_ pid: Int32, _ flavor: Int32, _ argument: UInt64, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32
@_silgen_name("proc_pidfdinfo")
private func monitorFDInfo(_ pid: Int32, _ descriptor: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer, _ size: Int32) -> Int32
@_silgen_name("proc_pidfileportinfo")
private func monitorFileportInfo(_ pid: Int32, _ port: UInt32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer, _ size: Int32) -> Int32
@_silgen_name("proc_pidpath")
private func monitorPIDPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32
@_silgen_name("proc_listchildpids")
private func monitorChildren(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

nonisolated enum BpyKernelInspection {
    private static func failure(_ code: POSIXError.Code, operation: String, pid: Int32,
                                result: Int64? = nil, argument: UInt64? = nil, queryErrno: Int32? = nil) -> POSIXError {
        let error = POSIXError(code)
        var context: [String: String] = [:]
        if let result { context["result"] = String(result) }
        if let argument { context["argument"] = String(argument) }
        if let queryErrno { context["queryErrno"] = String(queryErrno) }
        BpyRuntimeObservation.shared.inspectionFailure(operation: operation, pid: pid, error: error, context: context)
        return error
    }

    static func identity(_ pid: Int32) throws -> (start: UInt64, footprint: UInt64)? {
        guard pid > 1 else { throw failure(.EINVAL, operation: "identity.pid", pid: pid) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_024, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 1_024)
        errno = 0
        let result = monitorRusage(pid, 4, buffer)
        let queryError = errno
        guard result == 0 else {
            if queryError == ESRCH { return nil }
            throw failure(.init(rawValue: queryError) ?? .EIO, operation: "proc_pid_rusage", pid: pid,
                result: Int64(result), argument: 4, queryErrno: queryError)
        }
        let start = buffer.load(fromByteOffset: 80, as: UInt64.self)
        guard start > 0 else { throw failure(.EIO, operation: "rusage.start", pid: pid, argument: start) }
        return (start, buffer.load(fromByteOffset: 72, as: UInt64.self))
    }

    private static func liveIdentity(_ pid: Int32) throws -> (start: UInt64, footprint: UInt64, parent: Int32)? {
        guard let before = try identity(pid) else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        errno = 0
        let size = monitorPIDInfo(pid, 13, 1, buffer, 64)
        let queryError = errno
        guard size == 64, buffer.load(as: UInt32.self) == UInt32(pid) else {
            if queryError == ESRCH { return nil }
            if try identity(pid)?.start != before.start { return nil }
            throw failure(.init(rawValue: queryError) ?? .EIO, operation: "proc_pidinfo.shortbsd", pid: pid,
                result: Int64(size), argument: 1, queryErrno: queryError)
        }
        if buffer.load(fromByteOffset: 12, as: UInt32.self) == 5 { return nil }
        guard let after = try identity(pid), after.start == before.start else { return nil }
        return (after.start, after.footprint, buffer.load(fromByteOffset: 4, as: Int32.self))
    }

    static func process(_ pid: Int32) throws -> BpyObservedProcess? {
        guard let before = try liveIdentity(pid) else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_024, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 1_024)
        errno = 0
        let length = monitorPIDPath(pid, buffer, 1_024)
        let pathError = errno
        guard length > 0, length < 1_024 else {
            if try liveIdentity(pid)?.start != before.start { return nil }
            throw failure(.init(rawValue: pathError) ?? .EIO, operation: "proc_pidpath", pid: pid,
                result: Int64(length), queryErrno: pathError)
        }
        let path = try kernelPath(buffer, offset: 0, pid: pid, operation: "process.path")
        guard try liveIdentity(pid)?.start == before.start else { return nil }
        guard let path else { throw failure(.EIO, operation: "process.emptyPath", pid: pid) }
        let executable: String
        do { executable = try BpyRuntimePath.canonical(URL(fileURLWithPath: path)) }
        catch {
            BpyRuntimeObservation.shared.inspectionFailure(operation: "process.canonicalPath", pid: pid, error: error)
            throw error
        }
        return .init(pid: pid, start: before.start, parent: before.parent, executable: executable, footprint: before.footprint)
    }

    static func descendants(of root: BpyObservedProcess) throws -> [BpyObservedProcess] {
        var identities: [Int32: BpyObservedProcess] = [:]
        let pids = try BpyProcessTreeInspection.descendants(root: root.pid, start: root.start,
            identity: { pid in
                let value = try process(pid)
                if let value, identities[pid] == nil || identities[pid]?.start == value.start {
                    identities[pid] = value
                }
                return value?.start
            }) { parent, capacity in
                var children = [Int32](repeating: 0, count: capacity)
                errno = 0
                let count = children.withUnsafeMutableBytes { monitorChildren(parent, $0.baseAddress, Int32($0.count)) }
                let queryError = errno
                if count < 0 || count == 0 && queryError != 0 {
                    _ = failure(.init(rawValue: queryError) ?? .EIO, operation: "proc_listchildpids", pid: parent,
                        result: Int64(count), argument: UInt64(capacity), queryErrno: queryError)
                }
                return .init(count: Int(count), error: queryError, pids: children)
            }
        return try pids.compactMap { pid in
            guard let value = identities[pid] else { throw failure(.ESRCH, operation: "descendants.identity", pid: pid) }
            guard try matches(value) else { return nil }
            var parent = value.parent
            var seen: Set<Int32> = [pid]
            while parent != root.pid {
                guard seen.insert(parent).inserted, let ancestor = identities[parent] else {
                    throw failure(.EPERM, operation: "descendants.parent", pid: pid, result: Int64(parent))
                }
                parent = ancestor.parent
            }
            return value
        }
    }

    static func matches(_ process: BpyObservedProcess) throws -> Bool {
        try liveIdentity(process.pid)?.start == process.start
    }

    private static func kernelPath(_ buffer: UnsafeRawPointer, offset: Int, pid: Int32, operation: String) throws -> String? {
        let bytes = UnsafeBufferPointer(start: buffer.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: 1_024)
        guard let end = bytes.firstIndex(of: 0) else { throw failure(.EIO, operation: operation + ".unterminated", pid: pid) }
        if end == 0 { return nil }
        guard let path = String(bytes: bytes[..<end], encoding: .utf8), path.hasPrefix("/") else {
            throw failure(.EIO, operation: operation + ".encoding", pid: pid, result: Int64(end))
        }
        return path
    }

    static func descriptors(_ process: BpyObservedProcess, fileports: Bool) throws -> [BpyObservedVnode] {
        guard try matches(process) else { return [] }
        let flavor: Int32 = fileports ? 14 : 1
        let operation = fileports ? "fileports" : "descriptors"
        let maximum = 8 * 4_096
        errno = 0
        let required = Int(monitorPIDInfo(process.pid, flavor, 0, nil, 0))
        let requiredError = errno
        if required == 0 && fileports && requiredError == 0 { return [] }
        guard required > 0 else {
            if try !matches(process) { return [] }
            throw failure(.init(rawValue: requiredError) ?? .EIO, operation: operation + ".capacityQuery", pid: process.pid,
                result: Int64(required), queryErrno: requiredError)
        }
        guard required <= maximum else { throw failure(.EOVERFLOW, operation: operation + ".capacityLimit", pid: process.pid, result: Int64(required)) }
        let capacity = min(maximum, max(required + 8 * 64, 8 * 128))
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        errno = 0
        let count = Int(monitorPIDInfo(process.pid, flavor, 0, buffer, Int32(capacity)))
        let listError = errno
        if count == 0 && fileports && listError == 0 { return [] }
        guard count > 0 else {
            if try !matches(process) { return [] }
            throw failure(.init(rawValue: listError) ?? .EIO, operation: operation + ".list", pid: process.pid,
                result: Int64(count), argument: UInt64(capacity), queryErrno: listError)
        }
        guard count < capacity, count % 8 == 0 else {
            throw failure(.EOVERFLOW, operation: operation + ".listSize", pid: process.pid, result: Int64(count), argument: UInt64(capacity))
        }
        var records: [BpyObservedVnode] = []
        let vnode = UnsafeMutableRawPointer.allocate(byteCount: 1_200, alignment: 8)
        defer { vnode.deallocate() }
        for offset in stride(from: 0, to: count, by: 8) {
            let descriptor = buffer.load(fromByteOffset: offset, as: Int32.self)
            let type = buffer.load(fromByteOffset: offset + 4, as: UInt32.self)
            guard (fileports || descriptor >= 0), type == 1 else { continue }
            vnode.initializeMemory(as: UInt8.self, repeating: 0, count: 1_200)
            errno = 0
            let size = fileports
                ? monitorFileportInfo(process.pid, UInt32(bitPattern: descriptor), 2, vnode, 1_200)
                : monitorFDInfo(process.pid, descriptor, 2, vnode, 1_200)
            let vnodeError = errno
            guard size == 1_200 else {
                if try !matches(process) { return [] }
                if size == 0 && [EBADF, ENOENT, EINVAL].contains(vnodeError) { continue }
                throw failure(.init(rawValue: vnodeError) ?? .EIO, operation: operation + ".vnode", pid: process.pid,
                    result: Int64(size), argument: UInt64(UInt32(bitPattern: descriptor)), queryErrno: vnodeError)
            }
            guard vnode.load(fromByteOffset: 28, as: UInt16.self) & UInt16(S_IFMT) == UInt16(S_IFREG) else { continue }
            records.append(.init(device: UInt64(vnode.load(fromByteOffset: 24, as: UInt32.self)),
                inode: vnode.load(fromByteOffset: 32, as: UInt64.self), links: vnode.load(fromByteOffset: 30, as: UInt16.self),
                openFlags: vnode.load(as: UInt32.self), logical: vnode.load(fromByteOffset: 112, as: Int64.self),
                blocks: vnode.load(fromByteOffset: 120, as: Int64.self), path: try kernelPath(vnode, offset: 176,
                    pid: process.pid, operation: operation + ".path")))
        }
        return try matches(process) ? records : []
    }

    static func mappings(_ process: BpyObservedProcess) throws -> [BpyObservedVnode] {
        guard try matches(process) else { return [] }
        let region = UnsafeMutableRawPointer.allocate(byteCount: 1_272, alignment: 8)
        defer { region.deallocate() }
        var records: [BpyObservedVnode] = []
        var address: UInt64 = 0
        for index in 0..<65_536 {
            region.initializeMemory(as: UInt8.self, repeating: 0, count: 1_272)
            errno = 0
            let size = monitorPIDInfo(process.pid, 8, address, region, 1_272)
            let queryError = errno
            guard size == 1_272 else {
                if try !matches(process) { return [] }
                if size == 0 && queryError == EINVAL && index > 0 { return records }
                throw failure(.init(rawValue: queryError) ?? .EIO, operation: "mappings.region", pid: process.pid,
                    result: Int64(size), argument: address, queryErrno: queryError)
            }
            let begin = region.load(fromByteOffset: 80, as: UInt64.self)
            let length = region.load(fromByteOffset: 88, as: UInt64.self)
            guard length > 0, begin <= UInt64.max - length, begin + length > address else {
                throw failure(.EIO, operation: "mappings.geometry", pid: process.pid, result: Int64(index), argument: address)
            }
            if region.load(fromByteOffset: 100, as: UInt16.self) & UInt16(S_IFMT) == UInt16(S_IFREG) {
                records.append(.init(device: UInt64(region.load(fromByteOffset: 96, as: UInt32.self)),
                    inode: region.load(fromByteOffset: 104, as: UInt64.self), links: region.load(fromByteOffset: 102, as: UInt16.self),
                    openFlags: nil, logical: region.load(fromByteOffset: 184, as: Int64.self),
                    blocks: region.load(fromByteOffset: 192, as: Int64.self), path: try kernelPath(region, offset: 248,
                        pid: process.pid, operation: "mappings.path")))
            }
            address = begin + length
            if address == UInt64.max { return try matches(process) ? records : [] }
        }
        if try !matches(process) { return [] }
        throw failure(.EOVERFLOW, operation: "mappings.countLimit", pid: process.pid, argument: address)
    }
}
