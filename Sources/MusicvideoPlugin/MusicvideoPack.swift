import Foundation
import NexGenEngine

/// The minimum NexGenVideo marketing version this pack build needs. This manifest
/// (id/version/minAppVersion/displayName/tagline) mirrors `plugins/musicvideo.json`,
/// which the release assembles into the `.ngvpack`'s Info.plist `NGVMinAppVersion` —
/// the value the load gate checks BEFORE loading this code. Keep the two in lockstep.
let musicvideoMinAppVersion = "1.0.3"

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
    public let version = "0.0.12"

    private static func adoptLegacyProjectSchema(_ projectURL: URL) throws {
        _ = projectURL
    }

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
            prompt: MusicvideoPack.phasePrompt(
                phase: "project_init",
                handoff: "The host initialized this music-video pipeline and collected the required Track plus optional Lyrics."
            )
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
                prompt: Self.phasePrompt(
                    phase: next,
                    handoff: "Continue from the durable project state with \(label). Earlier approved phases stay approved."
                )
            )]
        }
        return [PackStarter(
            id: "review",
            title: "Every phase approved — what's left?",
            prompt: "Every phase is approved. Show me where the project stands and what's left to do."
        )]
    }

    private static func phasePrompt(phase: String, handoff: String) -> String {
        let resourceName: String
        switch phase {
        case "frames": resourceName = "frame"
        default: resourceName = phase.replacingOccurrences(of: "_", with: "-")
        }
        guard let instructions = try? PackKnowledge.phaseDoc(name: resourceName),
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return handoff
        }
        return "\(handoff)\n\nFollow these packaged instructions for the current phase:\n\n\(instructions)"
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

    private func registerHardenedGate(
        _ phase: String,
        registry: EngineRegistry,
        check: @escaping EngineRegistry.GateRequirement
    ) {
        registry.registerPhaseLineageProvider(phase) {
            try MusicvideoPipelineLineage.snapshot(
                phase: phase,
                dataRoot: $0
            )
        }
        registry.registerGateRequirement(phase) {
            try check($0)
            try MusicvideoPipelineLineage.requireCurrent(
                phase: phase,
                dataRoot: $0
            )
        }
    }

    public func register(_ registry: EngineRegistry) {
        registry.registerProjectSchemaMigration(
            from: "musicvideo/legacy",
            to: "musicvideo/1.0.0",
            migrate: Self.adoptLegacyProjectSchema
        )
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
        registry.registerProgressPhaseRunner("analysis") { [weak registry] dataRoot, progress in
            guard let registry, let decoder = registry.audioDecoder else {
                throw MusicvideoAnalysisRunner.RunError.noDecoder
            }
            _ = try MusicvideoAnalysisRunner.run(
                dataRoot: dataRoot,
                decoder: decoder,
                transcriber: registry.transcriber,
                separator: registry.stemSeparator,
                beatDetector: registry.beatDetector,
                chordRecognizer: registry.chordRecognizer,
                progress: progress
            )
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
        registry.registerDeterministicStep(
            "prepare_frames_manifest",
            phase: "frames",
            summary: "Reconcile the role-aware Frames manifest with the approved shot list."
        ) {
            try MusicvideoPhasePreparation.frames(dataRoot: $0)
        }
        registry.registerDeterministicStep(
            "prepare_final_render_manifest",
            phase: "render",
            summary: "Reconcile the final render manifest with the approved shot list."
        ) {
            try MusicvideoPhasePreparation.render(dataRoot: $0)
        }
        // Hard gate: the analysis gate can't be stamped until a real analysis artifact (with genuine
        // beats/downbeats) exists — the deterministic backstop against a fabricated song structure.
        registry.registerGateRequirement("project_init") { try MusicvideoGateChecks.requireProjectTrack(dataRoot: $0) }
        registerHardenedGate("analysis", registry: registry) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: $0)
        }
        registerHardenedGate("brief", registry: registry) {
            try MusicvideoGateChecks.requireRealBrief(dataRoot: $0)
        }
        registerHardenedGate("production_design", registry: registry) {
            try MusicvideoGateChecks.requireRealProductionDesign(dataRoot: $0)
        }
        registerHardenedGate("treatment", registry: registry) {
            try MusicvideoGateChecks.requireRealTreatment(dataRoot: $0)
        }
        registerHardenedGate("storyboard", registry: registry) {
            try MusicvideoGateChecks.requireRealStoryboard(dataRoot: $0)
        }
        registerHardenedGate("bible", registry: registry) {
            try MusicvideoGateChecks.requireRealBible(dataRoot: $0)
        }
        registerHardenedGate("shotlist", registry: registry) {
            try MusicvideoGateChecks.requireRealShotlist(dataRoot: $0)
        }
        registerHardenedGate("sanity", registry: registry) {
            try MusicvideoGateChecks.requireCurrentSanity(dataRoot: $0)
        }
        registerHardenedGate("frames", registry: registry) {
            try MusicvideoGateChecks.requireRealFrames(dataRoot: $0)
        }
        registerHardenedGate("render", registry: registry) {
            try MusicvideoGateChecks.requireRealRender(dataRoot: $0)
        }
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
