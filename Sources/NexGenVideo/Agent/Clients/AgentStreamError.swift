import Foundation

/// Error surfaced in the agent panel when a stream fails.
enum AgentStreamError: LocalizedError {
    case upstream(String)
    case authenticationRequired

    var errorDescription: String? {
        switch self {
        case .upstream(let m): m
        case .authenticationRequired:
            "Claude Code sign-in expired. Sign in again to continue."
        }
    }
}
