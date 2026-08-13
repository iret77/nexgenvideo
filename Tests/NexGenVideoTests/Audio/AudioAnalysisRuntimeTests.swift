import Foundation
import Testing
@testable import NexGenEngine
@testable import NexGenVideo

@Suite("Audio analysis runtime")
struct AudioAnalysisRuntimeTests {
    @Test("macOS 26 production runtime keeps the future system adapter dormant")
    func registersPlatformCapabilities() {
        let registry = EngineRegistry()

        AudioAnalysisRuntime.configure(
            registry,
            distributionMinimumSystemVersion: "26.0"
        )

        #expect(registry.audioDecoder != nil)
        #expect(registry.transcriber != nil)
        #expect(registry.transcriber is any ContextualAudioTranscribing)
        #expect(registry.transcriber is any AudioLyricsAligning)
        #expect(registry.stemSeparator != nil)
        #expect(registry.beatDetector != nil)
        #expect(registry.chordRecognizer != nil)
        #expect(registry.musicUnderstandingAnalyzer == nil)
    }

    @Test("system adapter requires both a released distribution floor and runtime")
    func musicUnderstandingReleasePolicy() {
        let macOS26 = OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 0,
            patchVersion: 0
        )
        let macOS27 = OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        )

        #expect(!AudioAnalysisRuntime.enablesMusicUnderstanding(
            distributionMinimumSystemVersion: "26.0",
            runtime: macOS27
        ))
        #expect(!AudioAnalysisRuntime.enablesMusicUnderstanding(
            distributionMinimumSystemVersion: "27.0",
            runtime: macOS26
        ))
        #expect(AudioAnalysisRuntime.enablesMusicUnderstanding(
            distributionMinimumSystemVersion: "27.0",
            runtime: macOS27
        ))
        #expect(!AudioAnalysisRuntime.enablesMusicUnderstanding(
            distributionMinimumSystemVersion: nil,
            runtime: macOS27
        ))
        #expect(!AudioAnalysisRuntime.enablesMusicUnderstanding(
            distributionMinimumSystemVersion: "preview",
            runtime: macOS27
        ))
    }
}
