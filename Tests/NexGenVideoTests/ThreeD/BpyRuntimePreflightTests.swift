import BpyRuntimeProtocol
import Darwin
import Foundation
import Testing

@Suite("Managed bpy executable preflight")
struct BpyRuntimePreflightTests {
    @Test func nonExecutablePythonKeepsTheOriginalFailureAndRecordsKernelEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let python = root.appendingPathComponent("python3.13")
        let alias = root.appendingPathComponent("python3")
        let supervisor = root.appendingPathComponent("supervisor")
        let worker = root.appendingPathComponent("worker.py")
        for file in [python, supervisor, worker] { try Data("fixture".utf8).write(to: file) }
        try #require(chmod(python.path, 0o644) == 0)
        try #require(chmod(supervisor.path, 0o755) == 0)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "python3.13")
        let checks = BpyRuntimePreflight(python: python, supervisor: supervisor, worker: worker, sitePackages: root)
        #expect(!checks.pythonExecutable)
        #expect(checks.supervisorExecutable && checks.workerExists && checks.sitePackagesExist)
        #expect(throws: CocoaError(.executableNotLoadable)) { try checks.requireValid() }
        let target = BpyRuntimePreflight.diagnostics(at: python)
        #expect(target["executeErrno"] == Int(EACCES))
        #expect(target["readErrno"] == 0 && target["openErrno"] == 0 && target["closeErrno"] == 0)
        #expect(target["statType"] == Int(S_IFREG) && target["statMode"] == 0o644)
        #expect(target["foundationExecutable"] == 0)
        let link = BpyRuntimePreflight.diagnostics(at: alias, pythonAlias: true)
        #expect(link["lstatType"] == Int(S_IFLNK) && link["statType"] == Int(S_IFREG))
        #expect(link["readlinkErrno"] == 0 && link["targetMatches"] == 1)
        try #require(chmod(python.path, 0o755) == 0)
        try BpyRuntimePreflight(python: python, supervisor: supervisor, worker: worker, sitePackages: root).requireValid()
        #expect(BpyRuntimePreflight.diagnostics(at: python)["executeErrno"] == 0)
    }

    @Test(arguments: ["supervisor", "worker", "sitePackages"])
    func everyResourceStillGatesStartup(role: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("executable")
        try Data("fixture".utf8).write(to: executable)
        try #require(chmod(executable.path, 0o755) == 0)
        let absent = root.appendingPathComponent("absent")
        let checks = BpyRuntimePreflight(python: executable,
            supervisor: role == "supervisor" ? absent : executable,
            worker: role == "worker" ? absent : executable,
            sitePackages: role == "sitePackages" ? absent : root)
        #expect(checks.pythonExecutable)
        #expect(throws: CocoaError(.executableNotLoadable)) { try checks.requireValid() }
        let evidence = BpyRuntimePreflight.diagnostics(at: absent)
        #expect(evidence["lstatErrno"] == Int(ENOENT) && evidence["statErrno"] == Int(ENOENT))
        #expect(evidence["openErrno"] == Int(ENOENT) && evidence["executeErrno"] == Int(ENOENT))
    }
}
