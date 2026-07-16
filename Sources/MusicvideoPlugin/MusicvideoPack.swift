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
        badgeURL: PackKnowledge.badgeURL(),
        accentHex: "#FF2D55"
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
        // Wiring-liveness probe: proves this pack's code is actually installed into the registry the
        // runtime built for a session (not silently absent). See PackWiring.
        registry.registerWiringProbe { PackWiring.token(pack: "musicvideo", nonce: $0) }
        registry.registerDurationPolicy(MusicDurationPolicy())
        // Agent-callable pattern query surface (suggest/get) — the live path to the pattern library.
        registry.registerPatternProvider(MusicvideoPatternProvider())
        registry.registerReferencePlanProvider(MusicvideoReferencePlanProvider())
        registry.registerProjectDirs(["audio", "lyrics", "analysis"])
        registry.registerSanityCheck("tempo", MusicvideoChecks.tempoCheck)
        registry.registerSanityCheck("pacing", MusicvideoChecks.pacingCheck)
        registry.registerSanityCheck("bible_integration", MusicvideoChecks.bibleReferenceIntegrityCheck)
        registry.registerSanityCheck("blocking", MusicvideoChecks.noBlockingAtT0Check)
        registry.registerSanityCheck("content_block", MusicvideoChecks.contentBlockRiskCheck)
        registry.registerSanityCheck("prompt_language", MusicvideoChecks.promptLanguageCheck)
        registry.registerSanityCheck("still_only_discipline", MusicvideoChecks.stillOnlyDisciplineCheck)
        registry.registerSanityCheck("variation", MusicvideoChecks.variationCheck)
        registry.registerSanityCheck("redundancy", MusicvideoChecks.redundancyCheck)
        registry.registerSanityCheck("keyframe_anchor", MusicvideoChecks.keyframeAnchorCheck)
        registry.registerSanityCheck("location_view", MusicvideoChecks.locationViewCheck)
        registry.registerSanityCheck("proportion_anchor", MusicvideoChecks.proportionAnchorCheck)
        registry.registerSanityCheck("composition", MusicvideoChecks.compositionCheck)
        registry.registerSanityCheck("provider_consistency", MusicvideoChecks.providerConsistencyCheck)
        registry.registerSanityCheck("reference_mode_prompt", MusicvideoChecks.referenceModePromptCheck)
        registry.registerSanityCheck("literal", MusicvideoChecks.literalCheck)
        registry.registerSanityCheck("plausibility", MusicvideoChecks.plausibilityCheck)
        registry.registerSanityCheck("compatibility", MusicvideoChecks.compatibilityCheck)
        registry.registerSanityCheck("pattern_drift", MusicvideoChecks.patternDriftCheck)
        registry.registerSanityCheck("expanding_camera", MusicvideoChecks.expandingCameraCheck)
        registry.registerSanityCheck("seedance_camera", MusicvideoChecks.seedanceDisciplineCheck)
        registry.registerSanityCheck("references", MusicvideoChecks.referenceBudgetCheck)
        registry.registerSanityCheck("frame_ratio", MusicvideoChecks.frameRatioCheck)
        registry.registerSanityCheck("frame_size", MusicvideoChecks.frameSizeCheck)
        registry.registerSanityCheck("builder_bypass", MusicvideoChecks.builderBypassCheck)
        registry.registerSanityCheck("plan_adherence", MusicvideoChecks.planAdherenceCheck)
        registry.registerSanityCheck("handle_discipline", MusicvideoChecks.handleDisciplineCheck)
        registry.registerSanityCheck("frame_audit_bridge", MusicvideoChecks.frameAuditBridgeCheck)
        // The runner resolves the audio decoder from the registry at run time
        // (weak capture — the registry outlives the call; no retain cycle). A
        // missing decoder surfaces as an actionable error, not a crash.
        // analysis gates BEFORE brief: the brief interview builds on the song's
        // bpm/beats/sections, so it must sit right after project_init — not
        // appended after render (the Python append-order would be an impossible
        // workflow here).
        registry.registerPhase("analysis", after: "project_init") { [weak registry] dataRoot in
            guard let registry, let decoder = registry.audioDecoder else {
                throw MusicvideoAnalysisRunner.RunError.noDecoder
            }
            _ = try MusicvideoAnalysisRunner.run(
                dataRoot: dataRoot, decoder: decoder,
                transcriber: registry.transcriber,
                separator: registry.stemSeparator,
                beatDetector: registry.beatDetector,
                chordRecognizer: registry.chordRecognizer)
        }
        // #174: the one-song contract is load-bearing — analysis is meaningless without exactly one
        // song in audio/. Pin it to the engine so a missing/duplicate song blocks the phase upfront
        // with an actionable message, regardless of whether the agent established it via attach_song.
        // Runs before the heavy DSP; defense-in-depth with the runner's own locateSong.
        registry.registerDeterministicStep(
            "one_song_contract", phase: "analysis",
            summary: "Exactly one song must be in audio/ (engine-enforced before analysis)."
        ) { dataRoot in
            _ = try MusicvideoAnalysisRunner.locateSong(dataRoot: dataRoot)
        }
        // Hard gate: the analysis gate can't be stamped until a real analysis artifact (with genuine
        // beats/downbeats) exists — the deterministic backstop against a fabricated song structure.
        registry.registerGateRequirement("analysis") { try MusicvideoGateChecks.requireRealAnalysis(dataRoot: $0) }
        // Per-phase acceptance harness — every gate deterministically verifies the phase's artifact is
        // real and to spec (not decoration). More phases wired as their checks land.
        registry.registerGateRequirement("brief") { try MusicvideoGateChecks.requireRealBrief(dataRoot: $0) }
        registry.registerGateRequirement("shotlist") { try MusicvideoGateChecks.requireRealShotlist(dataRoot: $0) }
        registry.registerGateRequirement("bible") { try MusicvideoGateChecks.requireRealBible(dataRoot: $0) }
        registry.registerGateRequirement("treatment") { try MusicvideoGateChecks.requireRealTreatment(dataRoot: $0) }
        registry.registerGateRequirement("storyboard") { try MusicvideoGateChecks.requireRealStoryboard(dataRoot: $0) }
        registry.registerGateRequirement("production_design") { try MusicvideoGateChecks.requireRealProductionDesign(dataRoot: $0) }
        registry.registerGateRequirement("frames") { try MusicvideoGateChecks.requireRealFrames(dataRoot: $0) }
        registry.registerGateRequirement("render") { try MusicvideoGateChecks.requireRealRender(dataRoot: $0) }
        registry.registerGateRequirement("cover") { try MusicvideoGateChecks.requireRealCover(dataRoot: $0) }
        try? registry.registerUIContract(phase: "analysis", surface: "choice", taskClass: "classification")
    }
}

/// The `.ngvpack` entry point. `Info.plist` `NSPrincipalClass` = `MusicvideoPackEntry`;
/// the host instantiates this after the load gate and calls `makePack()`.
@objc(MusicvideoPackEntry)
public final class MusicvideoPackEntry: PackEntry {
    public override func makePack() -> PackBox { PackBox(MusicvideoPack()) }
}
