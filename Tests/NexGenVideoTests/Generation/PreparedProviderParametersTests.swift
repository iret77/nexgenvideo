import Foundation
import Testing

@testable import NexGenVideo

@Suite("Prepared provider parameters")
struct PreparedProviderParametersTests {
    @Test func aFactoryCannotReplaceDuplicateOrDropAnApprovedInput() throws {
        for references in [["https://example.invalid/hidden.png"], []] as [[String]] {
            #expect(throws: (any Error).self) {
                try PreparedProviderParameters(referenceCount: 1) { _ in
                    .image(ImageGenerationParams(
                        prompt: "Portrait",
                        aspectRatio: "1:1",
                        resolution: nil,
                        quality: nil,
                        imageURLs: references,
                        numImages: 1
                    ))
                }
            }
        }
        #expect(throws: (any Error).self) {
            try PreparedProviderParameters(referenceCount: 2) { slots in
                .image(ImageGenerationParams(
                    prompt: "Portrait",
                    aspectRatio: "1:1",
                    resolution: nil,
                    quality: nil,
                    imageURLs: [slots[0], slots[0]],
                    numImages: 1
                ))
            }
        }
    }
    @Test func videoSettingsAreFrozenWhileReferenceLocationsAreBoundInOrder() throws {
        var duration = 5
        var calls = 0
        let prepared = try PreparedProviderParameters(referenceCount: 6) { slots in
            calls += 1
            return .video(VideoGenerationParams(prompt: "One continuous movement", duration: duration,
                aspectRatio: "16:9", resolution: "1080p", sourceVideoURL: slots[0],
                startFrameURL: slots[1], endFrameURL: slots[2], referenceImageURLs: [slots[3]],
                referenceVideoURLs: [slots[4]], referenceAudioURLs: [slots[5]], generateAudio: false))
        }
        duration = 10
        guard case .video(let actual) = try prepared.bind(["source", "start", "end", "image", "video", "audio"]) else {
            Issue.record("Expected prepared video parameters"); return
        }
        #expect(calls == 1)
        #expect(actual.duration == .seconds(5))
        #expect(actual.prompt == "One continuous movement")
        #expect(actual.resolution == "1080p")
        #expect(!actual.generateAudio)
        #expect(actual.sourceVideoURL == "source")
        #expect(actual.startFrameURL == "start")
        #expect(actual.endFrameURL == "end")
        #expect(actual.referenceImageURLs == ["image"])
        #expect(actual.referenceVideoURLs == ["video"])
        #expect(actual.referenceAudioURLs == ["audio"])
    }

    @Test func missingExtraAndEmptyReferenceLocationsFailBeforeDispatch() throws {
        let prepared = try PreparedProviderParameters(referenceCount: 1) { slots in
            .image(ImageGenerationParams(prompt: "Portrait", aspectRatio: "1:1", resolution: "2K",
                quality: "high", imageURLs: slots, numImages: 2))
        }
        #expect(throws: (any Error).self) { try prepared.bind([]) }
        #expect(throws: (any Error).self) { try prepared.bind(["first", "extra"]) }
        #expect(throws: (any Error).self) { try prepared.bind([""]) }
        guard case .image(let actual) = try prepared.bind(["hosted-reference"]) else {
            Issue.record("Expected prepared image parameters"); return
        }
        #expect(actual.numImages == 2)
        #expect(actual.quality == "high")
        #expect(actual.imageURLs == ["hosted-reference"])
    }
}
