import Darwin
import Foundation

public enum BpyRuntimePath {
    public static func canonical(_ url: URL) throws -> String {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        guard let path = url.withUnsafeFileSystemRepresentation({ value in value.flatMap { realpath($0, nil) } }) else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { free(path) }
        return String(cString: path)
    }
}
