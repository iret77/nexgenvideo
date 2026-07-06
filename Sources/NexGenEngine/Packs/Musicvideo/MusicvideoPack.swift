import Foundation

/// The musicvideo pack — registers music-specific behavior into the generic
/// engine. Port of `nexgen_pack_musicvideo/pack.py`.

/// Music shot-duration bands per mode. These were the engine-side
/// `MODE_DURATION_RANGES`; now supplied by the pack, so the engine's
/// Shot/sanity logic stays format-neutral. Port of `pack.py::_DURATION_BANDS`.
private let musicDurationBands: [String: (min: Double, max: Double)] = [
    "beat": (4.0, 15.0),
    "phrase": (4.0, 15.0),
    "section": (6.0, 60.0),
    "multicam": (30.0, 600.0),
]

/// Port of `pack.py::MusicDurationPolicy`.
public struct MusicDurationPolicy: DurationPolicy {
    public init() {}

    public func band(for mode: Mode, context: [String: String]) -> DurationBand {
        let key = mode.rawValue
        let (lo, hi) = musicDurationBands[key] ?? (4.0, 15.0)
        return DurationBand(label: key, minS: lo, maxS: hi)
    }
}

/// Thrown by the placeholder `"analysis"` phase runner — see the doc comment
/// on `MusicvideoPack.register`.
public struct AnalysisPhaseNotYetAvailable: Swift.Error, Sendable {
    public init() {}
}

/// Port of `pack.py::MusicvideoPack`.
///
/// The `analysis` phase's real runner pulls the DSP pipeline
/// (`analysis/pipeline.py`, heavy librosa/numpy/essentia/etc. deps) landing
/// separately as M8c — this work package (M8a/M8b) ports only the pure-logic
/// + knowledge layer. `register` still claims the `"analysis"` phase name
/// (mirroring Python's `register_phase`, and needed so `EngineRegistry`
/// callers can already ask "does this pack have an analysis phase") but the
/// runner throws until M8c wires the real one in.
public struct MusicvideoPack: Pack {
    public let name = "musicvideo"
    public let version = "0.0.1"

    public init() {}

    public func register(_ registry: EngineRegistry) {
        registry.registerDurationPolicy(MusicDurationPolicy())
        registry.registerProjectDirs(["audio", "lyrics", "analysis"])
        registry.registerSanityCheck("tempo", MusicvideoChecks.tempoCheck)
        registry.registerSanityCheck("pacing", MusicvideoChecks.pacingCheck)
        registry.registerPhase("analysis") { _ in throw AnalysisPhaseNotYetAvailable() }
        try? registry.registerUIContract(phase: "analysis", surface: "choice", taskClass: "classification")
    }
}
