import Foundation
import Testing
@testable import NexGenEngine

/// Port of `plugins/musicvideo/tests/test_patterns.py`, plus targeted
/// coverage for `PatternsSimilarity` and `PatternsMoodInference` (ported
/// alongside `patterns.py`'s re-exports, not separately test-filed in the
/// Python source).
@Suite("Musicvideo Patterns", .serialized)
struct PatternsTests {
    @Test("MoodBand raw values")
    func moodBandValues() {
        #expect(MoodBand.cinematic.rawValue == "cinematic")
        #expect(MoodBand.highEnergy.rawValue == "high_energy")
    }

    @Test("PatternTempoBand raw values")
    func tempoBandValues() {
        #expect(PatternTempoBand.slow.rawValue == "slow")
        #expect(PatternTempoBand.fast.rawValue == "fast")
    }

    @Test("tempo band thresholds")
    func tempoBandThresholds() {
        #expect(patternTempoBand(70) == .slow)
        #expect(patternTempoBand(95) == .medium)
        #expect(patternTempoBand(120) == .uptempo)
        #expect(patternTempoBand(160) == .fast)
    }

    @Test("pattern library loads and validates")
    func libraryLoadsAndValidates() throws {
        let library = try Patterns.loadAllPatterns()
        #expect(library.count >= 1)
        #expect(library.count == 23)
    }

    @Test("score and similarity smoke")
    func scoreAndSimilaritySmoke() throws {
        let scored = try Patterns.scorePatterns(maxResults: 3, minScore: nil)
        #expect(scored.count >= 1)
        let anchorId = scored[0].pattern.id
        let neighbours = try PatternsSimilarity.suggestSimilar(patternId: anchorId, top: 3)
        #expect(neighbours.allSatisfy { $0.score >= 0.0 && $0.score <= 1.0 })
    }

    @Test("suggestPatterns hard-filters by trigger match")
    func suggestPatternsHardFilters() throws {
        let matches = try Patterns.suggestPatterns(visualMedium: .liveActionRealistic, maxResults: 50)
        for pattern in matches {
            #expect(pattern.matches(visualMedium: .liveActionRealistic, mood: nil, tempo: nil, concept: nil, figures: nil, aspect: nil))
        }
    }

    // MARK: - PatternsMoodInference

    @Test("mood_from_tone_tags maps the first known tag")
    func moodFromToneTagsMapsFirstKnown() {
        #expect(PatternsMoodInference.moodFromToneTags([.melancholic]) == .melancholic)
        #expect(PatternsMoodInference.moodFromToneTags([.other, .euphoric]) == .euphoric)
    }

    @Test("mood_from_tone_tags returns nil for empty or unmapped-only input")
    func moodFromToneTagsNilForEmpty() {
        #expect(PatternsMoodInference.moodFromToneTags(nil) == nil)
        #expect(PatternsMoodInference.moodFromToneTags([]) == nil)
        #expect(PatternsMoodInference.moodFromToneTags([.other]) == nil)
    }

    @Test("mood_from_treatment requires at least 2 hits and a clear winner")
    func moodFromTreatmentThreshold() {
        #expect(PatternsMoodInference.moodFromTreatment("") == nil)
        // Only 1 hit for melancholic -> below threshold.
        #expect(PatternsMoodInference.moodFromTreatment("a bit sad today") == nil)
        // 2+ hits, clear winner.
        #expect(PatternsMoodInference.moodFromTreatment("so melancholic, so sad, full of longing") == .melancholic)
    }

    @Test("mood_from_treatment returns nil on a tie")
    func moodFromTreatmentTie() {
        // 2 hits melancholic ("sad", "lonely") vs 2 hits euphoric ("joy", "celebrate") -> tie -> nil.
        let text = "sad and lonely, yet joy and celebrate"
        #expect(PatternsMoodInference.moodFromTreatment(text) == nil)
    }

    @Test("infer_mood prefers brief.tone over treatment text")
    func inferMoodPrefersBriefTone() throws {
        let brief = try Brief(
            project: "proj", generated: "2026-01-01", mission: .demo, targetPlatform: "web",
            aspectRatio: .landscape16x9, projectMode: "section", conceptType: .abstract,
            visualMedium: .liveActionRealistic, tone: [.melancholic], figures: .none, lyricsIntegration: .ignored
        )
        let (mood, source) = PatternsMoodInference.inferMood(brief: brief, treatmentText: "so euphoric, joy, celebrate")
        #expect(mood == .melancholic)
        #expect(source == "brief.tone")
    }

    @Test("infer_mood falls back to treatment text when brief has no usable tone")
    func inferMoodFallsBackToTreatment() throws {
        let brief = try Brief(
            project: "proj", generated: "2026-01-01", mission: .demo, targetPlatform: "web",
            aspectRatio: .landscape16x9, projectMode: "section", conceptType: .abstract,
            visualMedium: .liveActionRealistic, figures: .none, lyricsIntegration: .ignored
        )
        let (mood, source) = PatternsMoodInference.inferMood(
            brief: brief, treatmentText: "so euphoric, such joy, let's celebrate"
        )
        #expect(mood == .euphoric)
        #expect(source == "treatment")
    }

    @Test("infer_mood falls back to the neutral label when nothing matches")
    func inferMoodFallbackLabel() {
        let (mood, source) = PatternsMoodInference.inferMood(brief: nil, treatmentText: nil)
        #expect(mood == nil)
        #expect(source == "fallback (no match)")
    }

    // MARK: - PatternsSimilarity

    @Test("similarity of a pattern with itself is 1.0")
    func similarityOfPatternWithItself() throws {
        let library = try Patterns.loadAllPatterns()
        let p = try #require(library.first)
        #expect(abs(PatternsSimilarity.similarity(p, p) - 1.0) < 1e-9)
    }

    @Test("suggestSimilar excludes the anchor and returns unknown-id as empty")
    func suggestSimilarExcludesAnchor() throws {
        let library = try Patterns.loadAllPatterns()
        let anchor = try #require(library.first)
        let neighbours = try PatternsSimilarity.suggestSimilar(patternId: anchor.id, top: 100)
        #expect(!neighbours.contains { $0.pattern.id == anchor.id })
        #expect(try PatternsSimilarity.suggestSimilar(patternId: "does-not-exist", top: 5).isEmpty)
    }
}
