import Foundation
import NexGenEngine

enum AudioAnalysisRuntime {
    static func configure(_ registry: EngineRegistry) {
        registry.registerAudioDecoder(AVFoundationAudioDecoder())
        registry.registerTranscriber(WhisperCppTranscriber())
        registry.registerStemSeparator(DemucsStemSeparator())
        registry.registerBeatDetector(BeatThisDetector())
        registry.registerChordRecognizer(ChordRecognizer())
        if #available(macOS 27.0, *) {
            registry.registerMusicUnderstandingAnalyzer(AppleMusicUnderstandingAnalyzer())
        }
    }
}
