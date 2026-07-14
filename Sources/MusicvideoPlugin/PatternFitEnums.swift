import Foundation
import NexGenEngine

// Swift mirrors of the frozen `pattern-fit/1.0` contract enums (schemas in the
// private `nexgenvideo-internal` repo). Raw values are the authoritative JSON
// tokens — never rename a raw value without a contract version bump.
//
// `VisualMedium`, `ConceptType`, `FigurePresence` and `LyricsIntegration` are
// deliberately NOT redefined here: the contract's enums are token-identical to
// the engine `Brief` enums, so the runtime project profile maps without
// reinterpretation (see the mapping table in PATTERN_FIT_CONTRACT.md).

/// The six weighted scoring dimensions. Contract `DimensionName`.
public enum FitDimensionName: String, Codable, Sendable, CaseIterable {
    case affectEnergy = "affect_energy"
    case conceptStory = "concept_story"
    case subjectPerformance = "subject_performance"
    case mediumAesthetic = "medium_aesthetic"
    case rhythmEdit = "rhythm_edit"
    case production
}

/// Every scored axis across the six dimensions. Contract `FitAxis`.
public enum FitAxis: String, Codable, Sendable, CaseIterable {
    case affect
    case energyLevel = "energy_level"
    case energyArc = "energy_arc"
    case conceptType = "concept_type"
    case lyricsIntegration = "lyrics_integration"
    case narrativeClarity = "narrative_clarity"
    case figures
    case performanceIntensity = "performance_intensity"
    case choreography
    case directAddress = "direct_address"
    case crowdEnergy = "crowd_energy"
    case visualMedium = "visual_medium"
    case abstraction
    case polish
    case emotionalDistance = "emotional_distance"
    case perceivedBpm = "perceived_bpm"
    case beatSalience = "beat_salience"
    case onsetDensityHz = "onset_density_hz"
    case rhythmicRegularity = "rhythmic_regularity"
    case sectionContrast = "section_contrast"
    case budgetTier = "budget_tier"
    case locationComplexity = "location_complexity"
    case castScale = "cast_scale"
    case choreographyComplexity = "choreography_complexity"
    case vfxComplexity = "vfx_complexity"
    case postComplexity = "post_complexity"
}

/// Risk appetite for conflicts. Contract `MatchMode`.
public enum FitMatchMode: String, Codable, Sendable, CaseIterable {
    case conservative
    case balanced
    case experimental
}

/// Affect / mood vocabulary. Contract `AffectTag`.
public enum AffectTag: String, Codable, Sendable, CaseIterable {
    case aggressive, anthemic, cinematic, confrontational, dark, dreamy, euphoric, fragile
    case highEnergy = "high_energy"
    case humorous, intimate, introspective, ironic, melancholic, meditative, narrative
    case playful, poetic, rebellious, romantic, surreal, tense, triumphant, urgent, warm
}

/// Feasibility band relative to the actual production plan. Contract `BudgetTier`.
public enum BudgetTier: String, Codable, Sendable, CaseIterable {
    case micro, low, medium, high
}

/// Camera/subject relationship. Contract `EmotionalDistance`.
public enum EmotionalDistance: String, Codable, Sendable, CaseIterable {
    case `private`, intimate, observational, `public`, confrontational
}

/// Shape of the energy curve. Contract `EnergyArc`.
public enum EnergyArc: String, Codable, Sendable, CaseIterable {
    case sparse
    case sustainedLow = "sustained_low"
    case sustainedHigh = "sustained_high"
    case gradualBuild = "gradual_build"
    case escalating
    case dropDriven = "drop_driven"
    case wave
    case dynamicContrast = "dynamic_contrast"
}

/// Four-step ordinal used for several production/performance axes. Contract `OrdinalLevel`.
public enum OrdinalLevel: String, Codable, Sendable, CaseIterable {
    case none, low, medium, high
}

/// Surface finish register. Contract `PolishLevel`.
public enum PolishLevel: String, Codable, Sendable, CaseIterable {
    case deliberatelyRaw = "deliberately_raw"
    case lofi, naturalistic, stylized
    case highGloss = "high_gloss"
}

/// How tightly cutting tracks the grid. Contract `RhythmicRegularity`.
public enum RhythmicRegularity: String, Codable, Sendable, CaseIterable {
    case free, variable, regular
    case gridDriven = "grid_driven"
}

/// A hard production capability a pattern may require. Contract `ProductionCapability`.
public enum ProductionCapability: String, Codable, Sendable, CaseIterable {
    case artistPerformance = "artist_performance"
    case choreography, crowd
    case multipleLocations = "multiple_locations"
    case practicalLightingControl = "practical_lighting_control"
    case precisionCameraMove = "precision_camera_move"
    case specialtyCamera = "specialty_camera"
    case stopMotion = "stop_motion"
    case animation2d = "2d_animation"
    case cg3d = "3d_cg"
    case vfxCompositing = "vfx_compositing"
    case heavyPost = "heavy_post"
}

/// A user-/brief-declared production constraint. Contract `ProjectConstraint`.
public enum ProjectConstraint: String, Codable, Sendable, CaseIterable {
    case noArtistOnCamera = "no_artist_on_camera"
    case noChoreography = "no_choreography"
    case noCrowd = "no_crowd"
    case singleLocation = "single_location"
    case singleSmallRoom = "single_small_room"
    case minimalPost = "minimal_post"
    case noVfx = "no_vfx"
    case noTextOverlays = "no_text_overlays"
    case stillOnly = "still_only"
}

/// A concrete pipeline lever an adaptation actuates. Contract `PipelineLever`.
public enum PipelineLever: String, Codable, Sendable, CaseIterable {
    case camera, color
    case editPacing = "edit_pacing"
    case framing, lighting, performance, production
    case promptStyle = "prompt_style"
    case sectionArc = "section_arc"
    case transitions
}

/// A pattern's broad style family, used for creative-stretch diversity. Contract `StyleFamily`.
public enum StyleFamily: String, Codable, Sendable, CaseIterable {
    case abstract, animation
    case cinematicNarrative = "cinematic_narrative"
    case dance, documentary
    case diyLofi = "diy_lofi"
    case graphicTypography = "graphic_typography"
    case performance, spectacle, surreal
}

/// Where a pattern sits on the director↔genre spectrum. Contract `PatternKind`.
public enum FitPatternKind: String, Codable, Sendable, CaseIterable {
    case director, hybrid, genre
}

/// Provenance class of a fit evidence entry. Contract `EvidenceBasis`.
public enum EvidenceBasis: String, Codable, Sendable, CaseIterable {
    case measured, documented, inferred
}

/// Where a runtime project-profile input came from. Contract `InputSource`.
public enum FitInputSource: String, Codable, Sendable, CaseIterable {
    case audioAnalysis = "audio_analysis"
    case brief, user
    case agentInference = "agent_inference"
}

/// How a single axis resolved during scoring. Contract `AxisResolution`.
public enum AxisResolution: String, Codable, Sendable, CaseIterable {
    case ideal, compatible, stretch, conflict, unlisted, unscored
}

/// Qualified band plus the two out-of-band states. Contract `PatternFitRecommendation.fit_band`.
public enum FitBand: String, Codable, Sendable, CaseIterable {
    case exceptional, strong, good, stretch, weak, excluded, provisional
}
