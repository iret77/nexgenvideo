import Foundation

/// Error surfaced in the agent panel when a stream fails.
enum AgentStreamError: LocalizedError {
    case unauthenticated
    case insufficientCredits(String)
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .unauthenticated: "Sign in to use the AI agent."
        case .insufficientCredits(let m): m
        case .upstream(let m): m
        }
    }
}
