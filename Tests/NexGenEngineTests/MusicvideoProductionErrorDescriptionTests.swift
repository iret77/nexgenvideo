import Foundation
import Testing
@testable import NexGenEngine

@Suite("Music Video validation diagnostics")
struct MusicvideoProductionErrorDescriptionTests {
    @Test("ownership and coverage errors identify the actual refused segment or coverage item")
    func identifiesRefusedPayload() {
        for error in [MusicvideoProductionValidationErrorV1.mouthOwnershipMismatch("segment-alpha"), .coverageMissing("coverage-alpha")] {
            let message = error.localizedDescription
            #expect(message.contains(error == .mouthOwnershipMismatch("segment-alpha") ? "segment-alpha" : "coverage-alpha"))
            #expect(!message.contains("error 4") && !message.contains("error 5"))
        }
        #expect(MusicvideoProductionValidationErrorV1.mouthOwnershipMismatch("segment-alpha").localizedDescription
            != MusicvideoProductionValidationErrorV1.mouthOwnershipMismatch("segment-beta").localizedDescription)
        #expect(MusicvideoProductionValidationErrorV1.coverageMissing("coverage-alpha").localizedDescription
            != MusicvideoProductionValidationErrorV1.coverageMissing("coverage-beta").localizedDescription)
    }

    @Test("all validation cases keep their exact diagnostic field or reference")
    func keepsExactDiagnosticContext() {
        let errors: [MusicvideoProductionValidationErrorV1] = [.invalidField("source.clock"), .duplicateID("duplicate-alpha"),
            .unknownReference("unknown-alpha"), .sourceMismatch("source-alpha")]
        for (error, expected) in zip(errors, ["source.clock", "duplicate-alpha", "unknown-alpha", "source-alpha"]) {
            #expect(error.localizedDescription.contains(expected))
        }
    }
}
