import CryptoKit
import Foundation

public enum BpyJobFingerprintV5 {
    public struct Input: Sendable {
        public let name: String
        public let byteCount: UInt64
        public let sha256: String

        public init(name: String, byteCount: UInt64, sha256: String) {
            self.name = name; self.byteCount = byteCount; self.sha256 = sha256
        }
    }

    public static func compute(expectedRevision: String?, source: String, requestedTimeout: Int?, effectiveTimeout: Int,
        inputs: [Input], deniedPaths: [String], autoexecControl: Bool, identityWriteFailure: Bool, identityCaptureFailure: Bool) -> String {
        var digest = SHA256()
        func add(_ value: String?) {
            digest.update(data: Data([value == nil ? 0 : 1]))
            guard let value else { return }
            let data = Data(value.utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
            digest.update(data: data)
        }
        add("nexgenvideo/bpy-job/5")
        add(expectedRevision); add(requestedTimeout.map(String.init)); add(String(effectiveTimeout)); add(source)
        add(String(inputs.count))
        for input in inputs { add(input.name); add(String(input.byteCount)); add(input.sha256) }
        add(String(deniedPaths.count))
        deniedPaths.forEach { add($0) }
        add(autoexecControl ? "1" : "0"); add(identityWriteFailure ? "1" : "0"); add(identityCaptureFailure ? "1" : "0")
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
