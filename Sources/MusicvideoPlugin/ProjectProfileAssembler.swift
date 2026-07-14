import Foundation
import NexGenEngine

/// Builds a `ProjectFitProfile` from the persisted Brief and audio analysis,
/// applying the contract's mapping table WITHOUT reinterpretation
/// (`docs/PATTERN_FIT_CONTRACT.md` §"Runtime project profile"). Values that have
/// no lossless source are left missing rather than invented — an assembler must
/// not fill unknown fields merely to raise coverage, and uncalibrated DSP
/// features are not unit scores. Deterministic: same inputs → same profile.
public enum ProjectProfileAssembler {
    /// Brief tone tags map to affect tags only where the vocabulary is identical.
    /// `energetic` becomes `high_energy`; `quiet` and `other` imply no specific
    /// affect and stay unmapped until treatment or user context disambiguates.
    static let toneToAffect: [ToneTag: AffectTag] = [
        .melancholic: .melancholic,
        .ironic: .ironic,
        .euphoric: .euphoric,
        .dark: .dark,
        .surreal: .surreal,
        .poetic: .poetic,
        .energetic: .highEnergy,
    ]

    /// Confidence for a directly Brief-confirmed enum answer.
    static let briefConfidence = 0.9
    /// Confidence for the Brief-derived affect weighting (a lossy tone→affect map).
    static let affectConfidence = 0.8
    /// Confidence for an audio-analysis measurement (perceived BPM).
    static let audioConfidence = 0.9

    public static func assemble(
        brief: Brief, perceivedBpm: Double? = nil, matchMode: FitMatchMode = .balanced,
        excludedPatternIds: [String] = []
    ) -> ProjectFitProfile {
        // Brief tone → weighted affects (equal weights across the mapped tags).
        var affects: FitInput<[WeightedAffect]>?
        let mappedAffects = brief.tone.compactMap { toneToAffect[$0] }
        if !mappedAffects.isEmpty {
            let weight = 1.0 / Double(mappedAffects.count)
            let weighted = mappedAffects.map { WeightedAffect(value: $0, weight: weight) }
            affects = FitInput(value: weighted, source: .brief, confidence: affectConfidence, userConfirmed: true)
        }

        let creative = ProjectCreativeFit(
            affects: affects,
            conceptType: FitInput(value: brief.conceptType, source: .brief, confidence: briefConfidence, userConfirmed: true),
            lyricsIntegration: FitInput(value: brief.lyricsIntegration, source: .brief, confidence: briefConfidence, userConfirmed: true),
            figures: FitInput(value: brief.figures, source: .brief, confidence: briefConfidence, userConfirmed: true))

        let visual = ProjectVisualFit(
            visualMedium: FitInput(value: brief.visualMedium, source: .brief, confidence: briefConfidence, userConfirmed: true))

        // Perceived BPM is the only losslessly mappable audio axis; the semantic
        // audio axes (energy, onset density, section contrast, regularity, arc,
        // beat salience) require a separately versioned DSP→unit mapping that the
        // frozen policy does not define, so they stay missing.
        var audio = ProjectAudioFit()
        if let bpm = perceivedBpm, bpm > 0 {
            audio.perceivedBpm = FitInput(value: bpm, source: .audioAnalysis, confidence: audioConfidence)
        }

        // budget_tier is feasibility against an actual costed plan, not a Euro
        // lookup. The Brief carries only `budget_eur`, never a plan, so the whole
        // production dimension is left missing (never invented from thresholds).
        let production = ProjectProductionFit()

        var excluded: FitInput<[String]>?
        if !excludedPatternIds.isEmpty {
            excluded = FitInput(value: excludedPatternIds, source: .user, confidence: 1.0, userConfirmed: true)
        }

        return ProjectFitProfile(
            projectId: brief.project, matchMode: matchMode, audio: audio, creative: creative, visual: visual,
            production: production, excludedPatternIds: excluded)
    }
}
