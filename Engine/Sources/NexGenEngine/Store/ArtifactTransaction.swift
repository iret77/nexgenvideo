import Foundation

public enum ArtifactTransaction {
    public static func perform(paths: [URL], dataRoot: URL, mutation: () throws -> Void) throws {
        let backups = try paths.map { path -> (URL, Data?) in
            let prefix = dataRoot.standardizedFileURL.path + "/"
            guard path.standardizedFileURL.path.hasPrefix(prefix) else {
                throw GateBlocked("Artifact transactions must remain inside the project data root.")
            }
            let relative = String(path.standardizedFileURL.path.dropFirst(prefix.count))
            guard path.resolvingSymlinksInPath() == dataRoot.resolvingSymlinksInPath().appendingPathComponent(relative) else {
                throw GateBlocked("Artifact transactions cannot write through symbolic links.")
            }
            return (path, FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : nil)
        }
        do { try mutation() }
        catch {
            let failure = error
            var failures: [String] = []
            for (path, data) in backups.reversed() {
                do {
                    if let data { try data.write(to: path, options: .atomic) }
                    else if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                } catch { failures.append(path.lastPathComponent + ": " + error.localizedDescription) }
            }
            guard failures.isEmpty else {
                throw GateBlocked("Artifact write failed: \(failure.localizedDescription). Rollback failed: \(failures.joined(separator: "; "))")
            }
            throw failure
        }
    }
}
