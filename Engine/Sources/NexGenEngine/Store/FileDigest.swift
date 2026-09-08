import CryptoKit
import Foundation

public enum FileDigest {
    @TaskLocal public static var readinessCache: FileDigestReadinessCache?

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func sha256(of url: URL) throws -> String {
        if let readinessCache { return try readinessCache.digest(of: url, read: digest) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try digest(handle)
    }

    private static func digest(_ handle: FileHandle) throws -> String {
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
