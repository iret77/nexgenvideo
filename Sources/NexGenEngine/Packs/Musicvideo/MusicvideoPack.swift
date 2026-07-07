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

/// Port of `pack.py::MusicvideoPack`.
///
/// The `analysis` phase runner (M8c) locates the song in the project's
/// `audio/` dir, decodes it via the host-injected `AudioPCMDecoding`, runs the
/// native DSP pipeline, and persists `analysis/<song>.json`. It resolves the
/// decoder from the registry at run time — nil decoder → an actionable error,
/// never a crash.
public struct MusicvideoPack: Pack {
    public let name = "musicvideo"
    public let version = "0.0.1"

    /// Values mirror the retired `plugins/musicvideo/ngv-plugin.json`. The badge ships INSIDE the
    /// pack's resources (self-contained — cut from the owner's badge masters in
    /// `docs/design/plugin-badges/`, one per planned pack, uniform style).
    public let manifest = PackManifest(
        id: "musicvideo",
        displayName: "Music Video Studio",
        tagline: "Structured AI music-video production — analysis → treatment → storyboard → shotlist → render, with engine-enforced consistency.",
        badgeURL: PackKnowledge.badgeURL()
    )

    /// One honest starter: kick off the production pipeline in gate order. The
    /// brief interview builds on the song's tempo/structure, and the `analysis`
    /// gate must be approved before `brief`, so the starter runs analysis first
    /// rather than jumping straight to the brief (a dead end — brief would block).
    public let starters = [
        PackStarter(
            id: "start",
            title: "Start the music-video pipeline",
            prompt: "Start the music-video production pipeline for this project. Initialize the pipeline if needed with init_project, then orient with get_project_state. Next, ask me for the song and bring exactly one audio file into the project's audio/ folder with attach_song (it keeps the one-song contract; import_media only reaches the media library, not audio/). Then run the analysis phase (run_phase analysis) on it, present the result briefly with show_blocks (bpm, sections, key beats), and get the analysis gate approved. Only once analysis is approved, walk me through drafting the brief — ask about the video's direction first. "
                + AgentPresentationRules.text
        )
    ]

    public init() {}

    public func register(_ registry: EngineRegistry) {
        registry.registerDurationPolicy(MusicDurationPolicy())
        registry.registerProjectDirs(["audio", "lyrics", "analysis"])
        registry.registerSanityCheck("tempo", MusicvideoChecks.tempoCheck)
        registry.registerSanityCheck("pacing", MusicvideoChecks.pacingCheck)
        // The runner resolves the audio decoder from the registry at run time
        // (weak capture — the registry outlives the call; no retain cycle). A
        // missing decoder surfaces as an actionable error, not a crash.
        // analysis gates BEFORE brief: the brief interview builds on the song's
        // bpm/beats/sections, so it must sit right after project_init — not
        // appended after render (the Python append-order would be an impossible
        // workflow here).
        registry.registerPhase("analysis", after: "project_init") { [weak registry] dataRoot in
            guard let decoder = registry?.audioDecoder else {
                throw MusicvideoAnalysisRunner.RunError.noDecoder
            }
            _ = try MusicvideoAnalysisRunner.run(dataRoot: dataRoot, decoder: decoder)
        }
        try? registry.registerUIContract(phase: "analysis", surface: "choice", taskClass: "classification")
    }
}
