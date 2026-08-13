import Testing
@testable import NexGenVideo

@Suite("Whisper.cpp transcriber")
struct WhisperCppTranscriberTests {
    @Test("automatic language selection still performs transcription")
    func automaticLanguageTranscribes() {
        let configuration = WhisperCppTranscriber.decodingConfiguration(language: "auto")

        #expect(configuration.language == "auto")
        #expect(!configuration.detectLanguageOnly)
    }

    @Test("an explicit language still performs transcription")
    func explicitLanguageTranscribes() {
        let configuration = WhisperCppTranscriber.decodingConfiguration(language: "en")

        #expect(configuration.language == "en")
        #expect(!configuration.detectLanguageOnly)
    }

    @Test("prompted text in a no-speech decoder window is not acoustic evidence")
    func rejectsNoSpeechSegment() {
        #expect(!WhisperCppTranscriber.isAcousticallySupportedSegment(
            noSpeechProbability: 0.6,
            threshold: 0.6
        ))
        #expect(!WhisperCppTranscriber.isAcousticallySupportedSegment(
            noSpeechProbability: 0.9,
            threshold: 0.6
        ))
    }

    @Test("speech below the model threshold remains available for alignment")
    func acceptsSpeechSegment() {
        #expect(WhisperCppTranscriber.isAcousticallySupportedSegment(
            noSpeechProbability: 0.59,
            threshold: 0.6
        ))
    }

    @Test("known-text alignment never falls back to decoder timing")
    func missingDTWFailsClosed() {
        #expect(WhisperCppTranscriber.resolvedTiming(
            decoderStart: 1,
            decoderEnd: 2,
            dtwStart: nil,
            dtwEnd: nil,
            preferDTW: true
        ) == nil)
        let measured = WhisperCppTranscriber.resolvedTiming(
            decoderStart: 1,
            decoderEnd: 2,
            dtwStart: 3,
            dtwEnd: 4,
            preferDTW: true
        )
        #expect(measured?.start == 3)
        #expect(measured?.end == 4)
    }

    @Test("DTW token moments become non-degenerate ordered word spans")
    func dtwMomentsBecomeSpans() {
        let words = WhisperCppTranscriber.finalizedDTWSpans([
            .init(text: "first", start: 1, end: 1),
            .init(text: "second", start: 2, end: 2.4),
        ])
        #expect(words.count == 2)
        #expect(words[0].start == 1)
        #expect(words[0].end == 2)
        #expect(words[1].start == 2)
        #expect(words[1].end == 2.4)

        #expect(WhisperCppTranscriber.finalizedDTWSpans([
            .init(text: "unsupported", start: 1, end: 1),
        ]).isEmpty)
    }
}
