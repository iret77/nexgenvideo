/// NexGenEngine — the format-neutral Swift port of the production engine's
/// pure core (project layout, artifact schemas, gates, sanity). No AppKit,
/// SwiftUI, or network: every type is a value type and `Sendable`, so the host
/// can drive it off the main actor.
///
/// This mirrors the Python `nexgen_engine` package (see `engine/`). The Python
/// engine remains the oracle: parity tests replay its `read` JSON against this
/// port. See `docs/ENGINE_MIGRATION.md`.
public enum NexGenEngine {
    /// Port version. Tracks the Swift port independently of the Python engine's
    /// package version (`engine/nexgen_engine/__init__.py::__version__`).
    public static let version = "0.1.0"
}
