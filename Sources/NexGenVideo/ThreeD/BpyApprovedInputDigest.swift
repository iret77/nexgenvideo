import CryptoKit
import Foundation

enum BpyApprovedInputDigest {
    static func read(_ handle: FileHandle, expectedBytes: UInt64) throws -> String {
        var remaining = expectedBytes
        var digest = SHA256()
        while remaining > 0 {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: Int(min(remaining, 1_048_576))), !data.isEmpty else {
                throw BpyRuntimeError.invalidInput("Approved input changed while it was hashed.")
            }
            remaining -= UInt64(data.count)
            digest.update(data: data)
        }
        try Task.checkCancellation()
        guard try handle.read(upToCount: 1)?.isEmpty != false else {
            throw BpyRuntimeError.invalidInput("Approved input grew while it was hashed.")
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
