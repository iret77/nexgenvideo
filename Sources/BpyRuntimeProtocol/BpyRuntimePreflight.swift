import Darwin
import Foundation

public struct BpyRuntimePreflight: Sendable {
    public let pythonExecutable: Bool
    public let supervisorExecutable: Bool
    public let workerExists: Bool
    public let sitePackagesExist: Bool

    public init(python: URL, supervisor: URL, worker: URL, sitePackages: URL) {
        pythonExecutable = FileManager.default.isExecutableFile(atPath: python.path)
        supervisorExecutable = FileManager.default.isExecutableFile(atPath: supervisor.path)
        workerExists = FileManager.default.fileExists(atPath: worker.path)
        sitePackagesExist = FileManager.default.fileExists(atPath: sitePackages.path)
    }

    public func requireValid() throws {
        guard pythonExecutable, supervisorExecutable, workerExists, sitePackagesExist else {
            throw CocoaError(.executableNotLoadable)
        }
    }

    public static func diagnostics(at url: URL, pythonAlias: Bool = false) -> [String: Int] {
        var fields: [String: Int] = [:]
        var link = stat()
        let linkStatus = lstat(url.path, &link)
        let linkError = linkStatus == 0 ? 0 : Int(errno)
        fields["lstatErrno"] = linkError
        fields["lstatType"] = linkStatus == 0 ? Int(link.st_mode & mode_t(S_IFMT)) : 0
        fields["lstatMode"] = linkStatus == 0 ? Int(link.st_mode & 0o7777) : 0
        fields["lstatFlags"] = linkStatus == 0 ? Int(link.st_flags) : 0
        var target = stat()
        let targetStatus = stat(url.path, &target)
        let targetError = targetStatus == 0 ? 0 : Int(errno)
        fields["statErrno"] = targetError
        fields["statType"] = targetStatus == 0 ? Int(target.st_mode & mode_t(S_IFMT)) : 0
        fields["statMode"] = targetStatus == 0 ? Int(target.st_mode & 0o7777) : 0
        fields["statFlags"] = targetStatus == 0 ? Int(target.st_flags) : 0
        for (name, mode) in [("existsErrno", F_OK), ("readErrno", R_OK), ("executeErrno", X_OK)] {
            let status = access(url.path, mode)
            let accessError = status == 0 ? 0 : Int(errno)
            fields[name] = accessError
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        let openError = descriptor >= 0 ? 0 : Int(errno)
        fields["openErrno"] = openError
        fields["closeErrno"] = descriptor >= 0 && Darwin.close(descriptor) != 0 ? Int(errno) : 0
        fields["foundationExecutable"] = FileManager.default.isExecutableFile(atPath: url.path) ? 1 : 0
        for (name, attribute) in [("quarantine", "com.apple.quarantine"), ("provenance", "com.apple.provenance")] {
            let size = getxattr(url.path, attribute, nil, 0, 0, pythonAlias ? XATTR_NOFOLLOW : 0)
            let attributeError = size >= 0 ? 0 : Int(errno)
            fields[name + "Errno"] = attributeError
            fields[name + "Present"] = size >= 0 ? 1 : 0
        }
        if pythonAlias {
            let capacity = Int(PATH_MAX)
            var bytes = [CChar](repeating: 0, count: capacity)
            let length = readlink(url.path, &bytes, capacity)
            let readlinkError = length >= 0 ? 0 : Int(errno)
            fields["readlinkErrno"] = readlinkError
            fields["targetMatches"] = length == 10
                && bytes.prefix(10).map({ UInt8(bitPattern: $0) }) == Array("python3.13".utf8) ? 1 : 0
        }
        return fields
    }
}
