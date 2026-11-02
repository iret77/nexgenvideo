import BpyRuntimeProtocol
import Darwin
import Foundation
import Testing

struct BpyWorkerJobCleanupTests {
    @Test func removesUnreadableJobTreesWithoutChangingExternalTargets() throws {
        try #require(getuid() != 0)
        let root = try temporaryRoot()
        var directories = [root]
        defer { cleanup(root, directories: directories) }
        let worker = try directory(root.appendingPathComponent("worker"), record: &directories)
        let jobs = try directory(worker.appendingPathComponent("jobs"), record: &directories)
        let outside = try directory(root.appendingPathComponent("outside"), record: &directories)
        let target = outside.appendingPathComponent("target.bin"), bytes = Data([0x62, 0x70, 0x79])
        try bytes.write(to: target)
        try #require(chmod(target.path, 0o400) == 0)
        let ids = [UUID(), UUID(), UUID()]
        for id in ids {
            let job = try directory(jobs.appendingPathComponent(id.uuidString), record: &directories)
            let blocked = try directory(job.appendingPathComponent("worker"), record: &directories)
            let nested = try directory(blocked.appendingPathComponent("nested"), record: &directories)
            let readOnly = try directory(job.appendingPathComponent("read-only"), record: &directories)
            for location in [blocked, nested, readOnly] { try bytes.write(to: location.appendingPathComponent("payload")) }
            try FileManager.default.createSymbolicLink(at: job.appendingPathComponent("external-file"), withDestinationURL: target)
            try FileManager.default.createSymbolicLink(at: job.appendingPathComponent("external-directory"), withDestinationURL: outside)
            try #require(chmod(nested.path, 0) == 0)
            try #require(chmod(blocked.path, 0) == 0)
            try #require(chmod(readOnly.path, 0o500) == 0)
            try #require(chmod(job.path, 0) == 0)
        }
        try #require(chmod(outside.path, 0o500) == 0)
        let device = try self.device(of: worker)
        try BpyWorkerJobCleanup.removeJob(ids[0], in: worker, device: device)
        #expect(!FileManager.default.fileExists(atPath: jobs.appendingPathComponent(ids[0].uuidString).path))
        #expect(try mode(jobs.appendingPathComponent(ids[1].uuidString)) == 0)
        try BpyWorkerJobCleanup.removeAllJobs(in: worker, device: device)
        #expect(try FileManager.default.contentsOfDirectory(atPath: jobs.path).isEmpty)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try mode(target) == 0o400)
        #expect(try mode(outside) == 0o500)
        try BpyWorkerJobCleanup.removeAllJobs(in: worker, device: device)
    }

    @Test func rejectsWrongVolumesAndSymlinkedJobContainersBeforeRepairingPermissions() throws {
        let root = try temporaryRoot()
        var directories = [root]
        defer { cleanup(root, directories: directories) }
        let worker = try directory(root.appendingPathComponent("worker"), record: &directories)
        let jobs = try directory(worker.appendingPathComponent("jobs"), record: &directories)
        let id = UUID(), device = try self.device(of: worker)
        let job = try directory(jobs.appendingPathComponent(id.uuidString), record: &directories)
        try #require(chmod(job.path, 0) == 0)
        #expect(throws: (any Error).self) { try BpyWorkerJobCleanup.removeJob(id, in: worker, device: device ^ 1) }
        #expect(try mode(job) == 0)
        let foreign = try directory(root.appendingPathComponent("foreign"), record: &directories)
        let foreignID = UUID()
        let target = try directory(foreign.appendingPathComponent(foreignID.uuidString), record: &directories)
        let payload = target.appendingPathComponent("payload"), bytes = Data("unchanged".utf8)
        try bytes.write(to: payload)
        try #require(chmod(target.path, 0o500) == 0)
        let redirected = try directory(root.appendingPathComponent("redirected"), record: &directories)
        try FileManager.default.createSymbolicLink(at: redirected.appendingPathComponent("jobs"), withDestinationURL: foreign)
        #expect(throws: (any Error).self) { try BpyWorkerJobCleanup.removeJob(foreignID, in: redirected, device: device) }
        #expect(try Data(contentsOf: payload) == bytes)
        #expect(try mode(target) == 0o500)
        let alias = UUID()
        let link = jobs.appendingPathComponent(alias.uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try BpyWorkerJobCleanup.removeJob(alias, in: worker, device: device)
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(try Data(contentsOf: payload) == bytes)
        #expect(try mode(target) == 0o500)
        #expect(try mode(job) == 0)
    }

    @Test func removesDeepUnreadableJobTreesWithoutRetainingAncestorDescriptors() throws {
        try #require(getuid() != 0)
        var limit = rlimit()
        try #require(getrlimit(RLIMIT_NOFILE, &limit) == 0)
        print("BPY_CLEANUP_RLIMIT_NOFILE soft=\(limit.rlim_cur) hard=\(limit.rlim_max) depth=400")
        let root = try temporaryRoot()
        var directories = [root]
        defer { cleanup(root, directories: directories) }
        let worker = try directory(root.appendingPathComponent("worker"), record: &directories)
        let jobs = try directory(worker.appendingPathComponent("jobs"), record: &directories)
        let id = UUID()
        var leaf = try directory(jobs.appendingPathComponent(id.uuidString), record: &directories)
        for _ in 0..<400 { leaf = try directory(leaf.appendingPathComponent("d"), record: &directories) }
        let outside = root.appendingPathComponent("outside.bin"), bytes = Data("unchanged".utf8)
        try bytes.write(to: outside)
        try #require(chmod(outside.path, 0o400) == 0)
        try bytes.write(to: leaf.appendingPathComponent("payload"))
        try FileManager.default.createSymbolicLink(at: leaf.appendingPathComponent("external"), withDestinationURL: outside)
        try #require(chmod(leaf.path, 0) == 0)
        let device = try self.device(of: worker)
        let outcome = CleanupOutcome(), finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            defer { finished.signal() }
            outcome.store(Result { try BpyWorkerJobCleanup.removeJob(id, in: worker, device: device) })
        }
        thread.stackSize = 128 * 1_024
        thread.start()
        finished.wait()
        try outcome.get()
        #expect(try FileManager.default.contentsOfDirectory(atPath: jobs.path).isEmpty)
        #expect(try Data(contentsOf: outside) == bytes)
        #expect(try mode(outside) == 0o400)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        guard let canonical = realpath(root.path, nil) else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical))
    }

    private func directory(_ url: URL, record: inout [URL]) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        record.append(url)
        return url
    }

    private func device(of url: URL) throws -> UInt64 {
        let descriptor = try BpyStoragePaths.openDirectory(url)
        defer { Darwin.close(descriptor) }
        return try BpyStoragePaths.identity(descriptor).device
    }

    private func mode(_ url: URL) throws -> mode_t {
        var value = stat()
        try #require(lstat(url.path, &value) == 0)
        return value.st_mode & 0o777
    }

    private func cleanup(_ root: URL, directories: [URL]) {
        for directory in directories.sorted(by: { $0.path.count < $1.path.count }) { _ = chmod(directory.path, 0o700) }
        try? FileManager.default.removeItem(at: root)
    }
}

private final class CleanupOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    func store(_ result: Result<Void, any Error>) { lock.withLock { self.result = result } }
    func get() throws {
        let result = try lock.withLock { try #require(self.result) }
        try result.get()
    }
}
