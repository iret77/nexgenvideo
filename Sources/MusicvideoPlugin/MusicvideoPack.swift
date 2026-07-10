import Foundation
import NexGenEngine

/// The minimum NexGenVideo marketing version this pack build needs. This manifest
/// (id/version/minAppVersion/displayName/tagline) mirrors `plugins/musicvideo.json`,
/// which the release assembles into the `.ngvpack`'s Info.plist `NGVMinAppVersion` —
/// the value the load gate checks BEFORE loading this code. Keep the two in lockstep.
let musicvideoMinAppVersion = "0.1.0"

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
    public let version = "0.0.3"

    /// Values mirror the retired `plugins/musicvideo/ngv-plugin.json`. The badge ships INSIDE the
    /// pack's resources (self-contained — cut from the owner's badge masters in
    /// `docs/design/plugin-badges/`, one per planned pack, uniform style).
    public let manifest = PackManifest(
        id: "musicvideo",
        displayName: "Music Video",
        tagline: "Structured AI music video production with engine-enforced consistency.",
        headline: "Turn a song into a finished video.",
        benefit: "Reads your track and plans shots to the beat.",
        minAppVersion: musicvideoMinAppVersion,
        badgeURL: PackKnowledge.badgeURL()
    )

    /// One honest starter. The prompt is USER-VISIBLE — it lands in the transcript as if the user
    /// typed it, so it reads as a natural first-person request, NOT an agent-facing instruction wall.
    /// The tool choreography (attach_song, run_phase, show_blocks) lives in the agent manual, tool
    /// descriptions, and phase docs — never in this line.
    public let starters = [
        PackStarter(
            id: "start",
            title: "Start the music video",
            prompt: "Let's make a music video from my song. Start the pipeline and take me through it step by step — begin by asking me for the track."
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

/// The `.ngvpack` entry point. `Info.plist` `NSPrincipalClass` = `MusicvideoPackEntry`;
/// the host instantiates this after the load gate and calls `makePack()`.
@objc(MusicvideoPackEntry)
public final class MusicvideoPackEntry: PackEntry {
    public override func makePack() -> PackBox { PackBox(MusicvideoPack()) }
}
