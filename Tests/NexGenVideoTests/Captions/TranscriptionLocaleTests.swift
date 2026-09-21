import Foundation
import Testing
@testable import NexGenVideo

@Suite("Transcription.matchLocale")
struct TranscriptionLocaleTests {
    // A representative slice of SpeechTranscriber.supportedLocales (clean language_region).
    private let supported = [
        "en_US", "en_GB", "fr_FR", "fr_CA", "es_ES", "de_DE", "sr_Cyrl_RS", "sr_Latn_RS",
    ].map(Locale.init(identifier:))

    @Test(arguments: [
        ("de-DE-u-rg-atzzzz", "de-DE"),
        ("de-DE-u-ca-gregory", "de-DE"),
        ("de-DE-U-RG-ATZZZZ", "de-DE"),
    ])
    func unicodeLocaleExtensionIsRemoved(identifier: String, expected: String) {
        #expect(Transcription.baseLocaleIdentifier(identifier) == expected)
    }

    @Test(arguments: ["en-US", "sr-Latn-RS", "de_DE", "", "de-DE-u", "not_a_locale"])
    func ordinaryAndMalformedIdentifiersAreUnchanged(identifier: String) {
        #expect(Transcription.baseLocaleIdentifier(identifier) == identifier)
    }

    @Test func malformedCandidateDoesNotMatch() {
        let result = Transcription.matchLocale(
            candidates: [Locale(identifier: "not_a_locale")],
            supported: supported
        )

        #expect(result == nil)
    }

    @Test func unicodeLocaleExtensionMatchesTheBaseLocale() {
        let result = Transcription.matchLocale(
            candidates: [Locale(identifier: "de-DE-u-rg-atzzzz")],
            supported: supported
        )

        #expect(result?.identifier == "de_DE")
    }

    @Test func scriptSubtagKeepsTheExplicitVariant() {
        let result = Transcription.matchLocale(
            candidates: [Locale(identifier: "sr-Latn-RS-u-rg-dezzzz")],
            supported: supported
        )

        #expect(result?.language.script?.identifier == "Latn")
    }

    @Test func ordinaryRegionalTagIsUnchanged() {
        let result = Transcription.matchLocale(
            candidates: [Locale(identifier: "en-US")],
            supported: supported
        )

        #expect(result?.identifier == "en_US")
    }

    @Test func regionOverrideKeywordIsStrippedToLanguageMatch() {
        // French user on an English UI → en_US@rg=frzzzz. Should resolve to an en_* model.
        let result = Transcription.matchLocale(candidates: [Locale(identifier: "en_US@rg=frzzzz")], supported: supported)
        #expect(result?.identifier == "en_US")
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

    @Test func noSharedLanguageReturnsNil() {
        let result = Transcription.matchLocale(candidates: [Locale(identifier: "ja_JP")], supported: supported)
        #expect(result == nil)
    }
}
