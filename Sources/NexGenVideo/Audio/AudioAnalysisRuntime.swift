import Foundation
import NexGenEngine

enum AudioAnalysisRuntime {
    static let musicUnderstandingMinimum = OperatingSystemVersion(
        majorVersion: 27,
        minorVersion: 0,
        patchVersion: 0
    )

    static func configure(
        _ registry: EngineRegistry,
        distributionMinimumSystemVersion: String? = Bundle.main.object(
            forInfoDictionaryKey: "LSMinimumSystemVersion"
        ) as? String
    ) {
        registry.registerAudioDecoder(AVFoundationAudioDecoder())
        registry.registerTranscriber(WhisperCppTranscriber())
        registry.registerStemSeparator(DemucsStemSeparator())
        registry.registerBeatDetector(BeatThisDetector())
        registry.registerChordRecognizer(ChordRecognizer())
        if enablesMusicUnderstanding(
            distributionMinimumSystemVersion: distributionMinimumSystemVersion,
            runtime: ProcessInfo.processInfo.operatingSystemVersion
        ), #available(macOS 27.0, *) {
            registry.registerMusicUnderstandingAnalyzer(AppleMusicUnderstandingAnalyzer())
        }
    }

    static func enablesMusicUnderstanding(
        distributionMinimumSystemVersion: String?,
        runtime: OperatingSystemVersion
    ) -> Bool {
        guard let distributionMinimum = parseVersion(distributionMinimumSystemVersion) else {
            return false
        }
        return isAtLeast(distributionMinimum, musicUnderstandingMinimum)
            && isAtLeast(runtime, musicUnderstandingMinimum)
    }

    private static func parseVersion(_ value: String?) -> OperatingSystemVersion? {
        guard let value else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              let major = Int(parts[0]),
              major >= 0 else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) : 0
        let patch = parts.count > 2 ? Int(parts[2]) : 0
        guard let minor, let patch, minor >= 0, patch >= 0 else { return nil }
        return OperatingSystemVersion(
            majorVersion: major,
            minorVersion: minor,
            patchVersion: patch
        )
    }

    private static func isAtLeast(
        _ candidate: OperatingSystemVersion,
        _ minimum: OperatingSystemVersion
    ) -> Bool {
        if candidate.majorVersion != minimum.majorVersion {
            return candidate.majorVersion > minimum.majorVersion
        }
        if candidate.minorVersion != minimum.minorVersion {
            return candidate.minorVersion > minimum.minorVersion
        }
        return candidate.patchVersion >= minimum.patchVersion
    }
}
