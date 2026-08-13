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

    @Test("prompted text in a no-speech segment is not acoustic evidence")
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
}
