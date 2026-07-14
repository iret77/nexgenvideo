import Foundation

/// A pack-provided reference-plan seam. The generic engine declares it; a format pack (musicvideo)
/// registers a provider that runs its deterministic reference planner — bible sheets scored by view
/// priority, plus inherited identity-anchor frames stacked on top (multi-shot character consistency,
/// CONCEPT §2/§4.1). The host's `next_render_shot` tool calls it so the agent renders a shot with the
/// planned reference set instead of hand-picking, giving the ported planner a live consumer (#195).
///
/// The pack resolves everything it needs from the data root (bible, shotlist, frames manifest, the
/// image model's reference cap), so the engine stays agnostic of the pack's planning rules — the same
/// dependency inversion as `PatternProviding`.
public protocol ReferencePlanProviding: Sendable {
    /// The reference plan for `shotId`, or nil when the project/shot can't be resolved (no shotlist, no
    /// such shot, no bible). Paths are relative to the project (resolvable against home / data root).
    func planReferences(dataRoot: URL, shotId: String) -> ReferencePlan?
}

/// The result of a reference plan: the accepted references (highest-priority first) plus any warnings
/// (e.g. refs dropped past the model cap, or an anchor stack that displaced planned refs).
public struct ReferencePlan: Sendable, Equatable {
    public struct Ref: Sendable, Equatable {
        /// Project-relative image path (bible sheet or identity-anchor frame).
        public let path: String
        /// `character` | `ensemble` | `location` | `prop` | `style` | `identity_anchor`.
        public let kind: String
        public let view: String
        public let score: Double
        public let purpose: String
        public init(path: String, kind: String, view: String, score: Double, purpose: String) {
            self.path = path
            self.kind = kind
            self.view = view
            self.score = score
            self.purpose = purpose
        }
    }
    public let refs: [Ref]
    public let warnings: [String]
    public init(refs: [Ref], warnings: [String]) {
        self.refs = refs
        self.warnings = warnings
    }
}
