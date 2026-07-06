import Foundation

/// Collects named sanity checks so the engine can run engine-core checks plus
/// whatever a format pack contributes. Port of the sanity-relevant slice of
/// `pack.py::EngineRegistry` (`sanity_checks` dict + `register_sanity_check`).
///
/// Registration is by name and last-write-wins: a pack may register a check
/// under a core check's name to override it outright (see `register(name:check:)`).
/// M8 packs use this same `register` entry point to add pack-specific checks.
public final class CheckRegistry: @unchecked Sendable {
    public private(set) var checks: [String: SanityCheck] = [:]

    public init() {}

    /// Registers `check` under `name`, overwriting any existing check with
    /// that name. Port of `EngineRegistry.register_sanity_check`.
    public func register(_ name: String, _ check: @escaping SanityCheck) {
        checks[name] = check
    }
}

/// Name -> check. Names double as the report ordering key. Port of
/// `sanity/checks/__init__.py::CORE_CHECKS`.
public let coreChecks: [String: SanityCheck] = [
    "coverage": coverageCheck,
    "mode_match": modeMatchCheck,
    "prompt_quality": promptQualityCheck,
]

/// Installs the engine's built-in generic checks onto `registry`. Idempotent
/// per name: re-registering overwrites. A pack registers its own checks (or
/// overrides a core check by name) after calling this — whichever call runs
/// last for a given name wins, mirroring `mcp_server.py::_gather_checks`
/// (pack checks register first via `discover_packs()`, then
/// `register_core_checks` runs, so today a pack cannot actually shadow a core
/// check of the same name; only the reverse). Port of
/// `sanity/checks/__init__.py::register_core_checks`.
public func registerCoreChecks(_ registry: CheckRegistry) {
    for (name, check) in coreChecks {
        registry.register(name, check)
    }
}
