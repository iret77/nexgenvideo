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
    public let version = "0.0.4"

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

    /// Hidden host-to-agent handoff after the ordered startup intake completes.
    public let starters = [
        PackStarter(
            id: "start",
            title: "Start the music video",
            prompt: "The host initialized this music-video pipeline and completed its declared startup intake. Inspect the current project state and files, then guide the user through the next unapproved phase. Never ask for or present a file-intake dialog for a pack hard step."
        )
    ]

    /// Once anything is approved the chip names the phase that is actually next.
    public func starters(for progress: PackProgress) -> [PackStarter] {
        guard progress.hasStarted else { return starters }
        if let next = progress.nextPhase {
            let label = Self.phaseLabel(next)
            return [PackStarter(
                id: "continue",
                title: "Continue — next: \(label)",
                prompt: "Let's pick up where we left off and carry on with the \(label) phase. The earlier phases are already approved, so leave those as they are."
            )]
        }
        return [PackStarter(
            id: "review",
            title: "Every phase approved — what's left?",
            prompt: "Every phase is approved. Show me where the project stands and what's left to do."
        )]
    }

    /// Pipeline phase name → the wording this pack uses for it in the UI.
    static func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "project_init": return "Project Init"
        case "analysis": return "Audio Analysis"
        case "brief": return "Brief"
        case "production_design": return "Production Design"
        case "treatment": return "Treatment"
        case "storyboard": return "Storyboard"
        case "bible": return "Bible"
        case "shotlist": return "Shot List"
        case "sanity": return "Sanity Check"
        case "frames": return "Frames"
        case "render": return "Render"
        default:
            return phase.split(separator: "_").map(\.capitalized).joined(separator: " ")
        }
    }

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
        registry.registerSanityCheck("scene3d_geometry", MusicvideoChecks.scene3dGeometryCheck)
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
        // song in audio/. Pin it to the engine so a missing/duplicate song blocks the phase upfront.
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
        registry.registerCockpitSurface(
            CockpitSurface(id: "analysis", title: "Analysis", symbol: "waveform", phase: "analysis", kind: "beatAnalysis")
        )
    }
}

/// The `.ngvpack` entry point. `Info.plist` `NSPrincipalClass` = `MusicvideoPackEntry`;
/// the host instantiates this after the load gate and calls `makePack()`.
@objc(MusicvideoPackEntry)
public final class MusicvideoPackEntry: PackEntry {
    public override func makePack() -> PackBox { PackBox(MusicvideoPack()) }
}
