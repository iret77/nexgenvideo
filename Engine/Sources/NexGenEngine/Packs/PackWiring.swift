import Foundation

/// Deterministic proof that the pack a project DECLARES is actually wired into the running session —
/// not silently resolved to nil (the class of bug where a pack's bundle loads fine but the runtime
/// resolves the active pack to nil, so its phases/gates/runners are never installed and the agent is
/// left to improvise). Unlike `PackSelfTest` (which only proves the bundle *loads*), this proves the
/// agent→plugin wiring is FACTUALLY live for a given project.
///
/// Mechanism: the pack registers a probe that emits `token(pack:nonce:)`. The formula is shared, but
/// only the pack's registered closure can EMIT it through the registry the runtime built — so a token
/// that matches proves the pack's code is reachable in this session. The host also cross-checks that the
/// runtime resolution agrees with the pack the project's package declares.
public enum PackWiring {
    /// The liveness token a loaded pack produces for a nonce. Deterministic + process-stable (FNV-1a);
    /// not a secret — the guarantee is that only the registered pack closure can produce it in-registry.
    public static func token(pack: String, nonce: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(pack)::\(nonce)".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "wired:\(pack):" + String(h, radix: 16)
    }

    public enum Result: Equatable, Sendable {
        case ok
        /// A generic project — no pack to wire.
        case noPack
        /// The project's package declares `expected`, but the runtime resolution didn't return it —
        /// the pack isn't visible where the session actually looks. This is the P0-class break.
        case unresolved(expected: String, resolved: String?)
        /// Resolution agrees, but the pack's code isn't in the built registry (no probe / wrong token).
        case runtimeAbsent(pack: String)

        public var isWired: Bool { self == .ok || self == .noPack }
    }

    /// Deterministic, LLM-free. `expected` = the pack the project's package declares (ground truth);
    /// `resolved` = what the runtime's own resolution returned; `registry` = what it built from that.
    public static func verify(expected: String?, resolved: String?, registry: EngineRegistry,
                              nonce: String = UUID().uuidString) -> Result {
        guard let expected, !expected.isEmpty else { return .noPack }
        guard resolved == expected else { return .unresolved(expected: expected, resolved: resolved) }
        guard let produced = registry.wiringToken?(nonce),
              produced == token(pack: expected, nonce: nonce) else {
            return .runtimeAbsent(pack: expected)
        }
        return .ok
    }
}
