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
}
