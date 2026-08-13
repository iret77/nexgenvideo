import Testing
@testable import NexGenEngine
@testable import NexGenVideo

@Suite("Audio analysis runtime")
struct AudioAnalysisRuntimeTests {
    @Test("production runtime registers every capability for the current platform")
    func registersPlatformCapabilities() {
        let registry = EngineRegistry()

        AudioAnalysisRuntime.configure(registry)

        #expect(registry.audioDecoder != nil)
        #expect(registry.transcriber != nil)
        #expect(registry.transcriber is any ContextualAudioTranscribing)
        #expect(registry.transcriber is any AudioLyricsAligning)
        #expect(registry.stemSeparator != nil)
        #expect(registry.beatDetector != nil)
        #expect(registry.chordRecognizer != nil)
        if #available(macOS 27.0, *) {
            #expect(registry.musicUnderstandingAnalyzer != nil)
        } else {
            #expect(registry.musicUnderstandingAnalyzer == nil)
        }
    }
}
