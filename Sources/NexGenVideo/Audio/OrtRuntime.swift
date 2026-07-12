import Foundation
import OnnxRuntimeBindings

/// Shared ONNX Runtime plumbing for the on-device audio-ML providers (Demucs, Beat This!). Also the
/// linkage anchor that gets the onnxruntime framework embedded + load-tested by CI.
enum OrtRuntime {
    /// One process-wide ORT environment (creating several is wasteful and noisy in logs). ORT's env is
    /// internally thread-safe, so sharing it across the analysis task is sound — hence `nonisolated(unsafe)`.
    nonisolated(unsafe) static let env: ORTEnv = (try? ORTEnv(loggingLevel: ORTLoggingLevel.warning))
        ?? (try! ORTEnv(loggingLevel: ORTLoggingLevel.error))

    /// A CPU-execution-provider session for `modelPath`. CPU is the reference-validated path for both
    /// models; the CoreML EP is deferred until it's been verified on-device (it silently per-node falls
    /// back to CPU, which can mask correctness issues).
    static func session(modelPath: String) throws -> ORTSession {
        let options = try ORTSessionOptions()
        return try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
    }
}
