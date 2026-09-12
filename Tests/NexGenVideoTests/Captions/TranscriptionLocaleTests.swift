import Foundation
import Testing
@testable import NexGenVideo

@Suite("Transcription.matchLocale")
struct TranscriptionLocaleTests {
    // A representative slice of SpeechTranscriber.supportedLocales (clean language_region).
    private let supported = ["en_US", "en_GB", "fr_FR", "fr_CA", "es_ES", "de_DE"].map(Locale.init(identifier:))

    @Test func unicodeExtensionIsStrippedBeforeRegionMatching() {
        let result = Transcription.matchLocale(
            candidates: [Locale(identifier: "de-DE-u-rg-zazzzz")],
            supported: supported
        )
        #expect(result?.identifier == "de_DE")
    }

    @Test func plainLanguageRegionRemainsAnExactMatch() {
        let result = Transcription.matchLocale(candidates: [Locale(identifier: "en-US")], supported: supported)
        #expect(result?.identifier == "en_US")
    }

    @Test func scriptMatchWinsOverRegionOnlyMatch() {
        let supported = ["sr_Cyrl_RS", "sr_Latn_BA"].map(Locale.init(identifier:))
        let result = Transcription.matchLocale(
            candidates: [Locale(identifier: "sr-Latn-RS-u-ca-gregory")],
            supported: supported
        )
        #expect(result?.identifier == "sr_Latn_BA")
    }

    @Test func languageRegionMismatchFallsBackToSameLanguage() {
        // n_FR (English language, France region) has no en_FR model → any en_*.
        let result = Transcription.matchLocale(candidates: [Locale(identifier: "en_FR")], supported: supported)
        #expect(result?.language.languageCode?.identifier == "en")
    }

    @Test func exactRegionIsPreferredOverSameLanguage() {
        let result = Transcription.matchLocale(candidates: [Locale(identifier: "fr_CA")], supported: supported)
        #expect(result?.identifier == "fr_CA")
    }

    @Test func preferredLanguageOrderWins() {
        // A French speaker whose preferred list leads with fr should transcribe in French.
        let result = Transcription.matchLocale(
            candidates: ["fr_FR", "en_US"].map(Locale.init(identifier:)), supported: supported
        )
        #expect(result?.identifier == "fr_FR")
    }

    @Test func languageOnlyCandidateMatchesAnyRegion() {
        let result = Transcription.matchLocale(candidates: [Locale(identifier: "fr")], supported: supported)
        #expect(result?.language.languageCode?.identifier == "fr")
    }

    @Test func invalidAndUndeterminedLocalesDoNotMatch() {
        #expect(Transcription.baseLocale(for: Locale(identifier: "invalid")) == nil)
        #expect(Transcription.baseLocale(for: Locale(identifier: "und")) == nil)
    }

    @Test func noSharedLanguageReturnsNil() {
        let result = Transcription.matchLocale(candidates: [Locale(identifier: "ja_JP")], supported: supported)
        #expect(result == nil)
    }
}
