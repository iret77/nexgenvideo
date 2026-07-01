import Foundation

/// Error surfaced in the agent panel when a stream fails.
enum AgentStreamError: LocalizedError {
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .upstream(let m): m
        }
    }
}
