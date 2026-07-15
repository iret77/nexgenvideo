import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// The Wong-Kar-Wai pilot is the roundtrip + scorer fixture: it exercises the
/// full machinery (policy load, profile decode/validate, deterministic scoring,
/// adaptations, hard gates, fail-closed gate, Brief→project assembly) while the
/// other 22 profiles are authored externally.
@Suite("Pattern fit pilot", .serialized)
struct PatternFitPilotTests {
    private let pilotId = "wong-kar-wai-doyle-neon-dream"

    private func pilotProfile() throws -> PatternFitProfile {
        let url = try #require(PackKnowledge.contractResourceURL("\(pilotId).fit-profile.json"))
        return try JSONDecoder().decode(PatternFitProfile.self, from: Data(contentsOf: url))
    }

    // MARK: Policy

    @Test("frozen policy loads with contract-exact weights")
    func policyWeights() throws {
        let policy = try PatternFitLibrary.loadPolicy()
        #expect(policy.scorerVersion == "pattern-fit-scorer/1.0")
        let dimSum = policy.dimensions.map(\.weight).reduce(0, +)
        #expect(abs(dimSum - 1.0) < 1e-9, "dimension weights must sum to 1.0")
        for dim in policy.dimensions {
            let axisSum = dim.axes.map(\.weight).reduce(0, +)
            #expect(abs(axisSum - 1.0) < 1e-9, "\(dim.dimension.rawValue) axis weights must sum to 1.0")
        }
        // Perceived BPM is exactly 3% of total fit (20% of the 15% rhythm dimension).
        #expect(abs((policy.globalWeight(for: .perceivedBpm) ?? 0) - 0.03) < 1e-9)
    }

    // MARK: Profile roundtrip + validation

    @Test("pilot fit-profile decodes, re-encodes semantically and validates")
    func pilotRoundtrips() throws {
        let url = try #require(PackKnowledge.contractResourceURL("\(pilotId).fit-profile.json"))
        let raw = try Data(contentsOf: url)
        let profile = try JSONDecoder().decode(PatternFitProfile.self, from: raw)
        #expect(profile.patternId == pilotId)
        #expect(PatternFitLibrary.validate(profile, expectedId: pilotId).isEmpty)

        // Encode → decode is identity (a true lossless round-trip). We don't byte-compare against the
        // source: the encoder omits nil-valued optionals (e.g. an adaptation's `threshold: null`), which
        // decode back to the same nil — semantically identical, not textually.
        let reencoded = try PatternFitLibrary.canonicalJSON(profile)
        let roundTripped = try JSONDecoder().decode(PatternFitProfile.self, from: reencoded)
        #expect(roundTripped == profile, "pilot profile must round-trip without loss")
    }

    @Test("the embedded YAML fit_profile equals the standalone pilot JSON")
    func embeddedProfileMatches() throws {
        let library = try Patterns.loadAllPatterns()
        let pilot = try #require(library.first { $0.id == pilotId })
        let embedded = try #require(pilot.fitProfile)
        #expect(embedded == (try pilotProfile()))
    }

    // MARK: Library coverage

    /// A pattern is OPTIONAL, so an unauthored one is not a defect — it is simply not a candidate.
    /// Ranking the pilot answers the only question that matters ("does it fit?") just as well with
    /// 1 profile as with 23; withholding it would deny a working answer over a pattern nobody has
    /// to take.
    /// No count is asserted on purpose. Nobody says the library ends at 23 — it grows as profiles
    /// get authored, and the code simply ranks whatever is there. A pinned number would make every
    /// new pattern a failing test.
    @Test("whatever carries a valid profile is rankable; the rest are simply not candidates")
    func coverageRanksWhatExists() throws {
        let (library, coverage) = try PatternFitLibrary.loadRecommendableLibrary()
        #expect(coverage.scored.contains(pilotId), "the pilot is scorable today")
        #expect(!coverage.unscored.contains(pilotId))
        #expect(library.count == coverage.scored.count, "every scored pattern is a candidate")
        #expect(coverage.invalid.isEmpty, "a present-but-broken profile would be a real defect")
        #expect(coverage.total == coverage.scored.count + coverage.unscored.count)
        #expect(coverage.total == (try Patterns.loadAllPatterns().count), "coverage spans the library")
    }

    // MARK: Deterministic scoring

    @Test("an all-ideal project scores a perfect exceptional index")
    func idealScoresPerfect() throws {
        let policy = try PatternFitLibrary.loadPolicy()
        let rec = PatternFitScorer.score(
            pattern: try pilotProfile(), patternName: "pilot", project: idealProject(), policy: policy)
        #expect(rec.excluded == false)
        #expect(abs((rec.fitScore ?? 0) - 100) < 1e-6)
        #expect(rec.fitBand == .exceptional)
        #expect(rec.conflicts.isEmpty)
        #expect(abs(rec.inputCoverage - 1.0) < 1e-6)
    }

    @Test("a visual-medium avoid is a soft conflict capped by balanced mode")
    func softConflictCap() throws {
        let policy = try PatternFitLibrary.loadPolicy()
        var project = idealProject()
        project.visual.visualMedium = FitInput(value: .cg3d, source: .brief, confidence: 0.9, userConfirmed: true)
        let rec = PatternFitScorer.score(pattern: try pilotProfile(), patternName: "pilot", project: project, policy: policy)
        #expect(rec.conflicts.contains { $0.hasPrefix("visual_medium:") })
        // 94 raw − 5 penalty = 89, but a remaining conflict caps balanced at 69.
        #expect(abs((rec.fitScore ?? 0) - 69) < 1e-6)
        #expect(rec.fitBand == .good)
    }

    @Test("a micro budget triggers the adaptation and its fit cap")
    func adaptationCap() throws {
        let policy = try PatternFitLibrary.loadPolicy()
        var project = idealProject()
        project.production.budgetTier = FitInput(value: .micro, source: .brief, confidence: 0.9)
        let rec = PatternFitScorer.score(pattern: try pilotProfile(), patternName: "pilot", project: project, policy: policy)
        #expect(rec.adaptations.contains { $0.adaptationId == "micro-budget-neon-room" })
        #expect(rec.conflicts.isEmpty, "micro is a stretch for the pilot, not an avoid")
        #expect(abs((rec.fitScore ?? 0) - 68) < 1e-6, "capped by maximum_recommended_fit 68")
    }

    @Test("a user exclusion hard-gates the pattern with no numeric score")
    func hardExclusion() throws {
        let policy = try PatternFitLibrary.loadPolicy()
        var project = idealProject()
        project.excludedPatternIds = FitInput(value: [pilotId], source: .user, confidence: 1.0, userConfirmed: true)
        let rec = PatternFitScorer.score(pattern: try pilotProfile(), patternName: "pilot", project: project, policy: policy)
        #expect(rec.excluded)
        #expect(rec.fitScore == nil)
        #expect(rec.fitBand == .excluded)
    }

    @Test("agent-inferred exclusions cannot veto a pattern")
    func inferenceCannotVeto() throws {
        let policy = try PatternFitLibrary.loadPolicy()
        var project = idealProject()
        project.excludedPatternIds = FitInput(value: [pilotId], source: .agentInference, confidence: 0.7)
        let rec = PatternFitScorer.score(pattern: try pilotProfile(), patternName: "pilot", project: project, policy: policy)
        #expect(rec.excluded == false, "agent inference moves soft scores but never vetoes")
    }

    @Test("a sparse Brief-only project is provisional with follow-up questions")
    func provisionalFromBrief() throws {
        // Brief maps only medium/concept/figures/lyrics/affects (+bpm): coverage stays below the
        // policy floor, so the result is provisional and questions are required.
        let brief = try Brief(
            project: "p", generated: "2026-01-01", mission: .demo, targetPlatform: "web",
            aspectRatio: .landscape16x9, projectMode: "section", conceptType: .narrative,
            visualMedium: .liveActionStylized, visualMediumNotes: "neon HK arthouse", tone: [.melancholic],
            figures: .artistPlusOthers, lyricsIntegration: .metaphorical)
        let policy = try PatternFitLibrary.loadPolicy()
        let project = ProjectProfileAssembler.assemble(brief: brief, perceivedBpm: 92)
        let set = PatternFitScorer.rank(
            patterns: [(try pilotProfile(), "pilot")], project: project, policy: policy,
            projectProfileSha256: "0", policySha256: "0")
        #expect(set.questionsRequiredBeforeRanking)
        #expect(!set.missingHighImpactInputs.isEmpty)
        #expect(set.results.first?.fitBand == .provisional)
        #expect(set.slots.bestOverallPatternId == nil, "provisional results fill no slots")
    }

    // MARK: Assembler mapping

    @Test("assembler maps Brief losslessly and leaves uncalibrated axes missing")
    func assemblerMapping() throws {
        let brief = try Brief(
            project: "proj", generated: "2026-01-01", mission: .demo, targetPlatform: "web",
            aspectRatio: .landscape16x9, projectMode: "section", budgetEur: 5000, conceptType: .narrative,
            visualMedium: .liveActionStylized, visualMediumNotes: "neon", tone: [.melancholic, .poetic, .quiet],
            figures: .artistPlusOthers, lyricsIntegration: .metaphorical)
        let project = ProjectProfileAssembler.assemble(brief: brief, perceivedBpm: 120)

        #expect(project.visual.visualMedium?.value == .liveActionStylized)
        #expect(project.creative.conceptType?.value == .narrative)
        #expect(project.creative.figures?.value == .artistPlusOthers)
        #expect(project.creative.lyricsIntegration?.value == .metaphorical)
        // `quiet` implies no affect; only melancholic + poetic map, at equal weight.
        let affects = try #require(project.creative.affects?.value)
        #expect(Set(affects.map { $0.value }) == Set([AffectTag.melancholic, .poetic]))
        #expect(affects.allSatisfy { abs($0.weight - 0.5) < 1e-9 })
        #expect(project.audio.perceivedBpm?.value == 120)
        // No costed plan → the whole production dimension stays missing (never invented from budget_eur).
        #expect(project.production.budgetTier == nil)
        #expect(project.audio.energyLevel == nil, "uncalibrated DSP axes are not invented")
    }

    // MARK: Helpers

    /// Every axis set to an ideal value for the pilot, source `.user`, so a clean
    /// run yields coverage 1.0 and a perfect raw fit.
    private func idealProject(matchMode: FitMatchMode = .balanced) -> ProjectFitProfile {
        func c<V>(_ v: V) -> FitInput<V> { FitInput(value: v, source: .user, confidence: 0.9) }
        func n(_ v: Double) -> FitInput<Double> { FitInput(value: v, source: .user, confidence: 0.9) }
        return ProjectFitProfile(
            projectId: "ideal", matchMode: matchMode,
            audio: ProjectAudioFit(
                perceivedBpm: n(120), beatSalience: c(.low), onsetDensityHz: n(3.0),
                rhythmicRegularity: c(.regular), sectionContrast: n(0.5), energyLevel: n(0.4), energyArc: c(.wave)),
            creative: ProjectCreativeFit(
                affects: FitInput(value: [WeightedAffect(value: .melancholic, weight: 1.0)], source: .user, confidence: 0.9),
                conceptType: c(.narrative), lyricsIntegration: c(.metaphorical), narrativeClarity: n(0.5),
                figures: c(.artistPlusOthers), performanceIntensity: c(.low), choreography: c(OrdinalLevel.none),
                directAddress: c(OrdinalLevel.none), crowdEnergy: c(OrdinalLevel.none)),
            visual: ProjectVisualFit(
                visualMedium: c(.liveActionStylized), abstraction: n(0.4), polish: c(.stylized),
                emotionalDistance: c(.intimate)),
            production: ProjectProductionFit(
                budgetTier: c(.medium), locationComplexity: c(.medium), castScale: c(.low),
                choreographyComplexity: c(OrdinalLevel.none), vfxComplexity: c(.low), postComplexity: c(.high)))
    }
}
