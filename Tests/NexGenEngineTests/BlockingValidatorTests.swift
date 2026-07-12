import Foundation
import Testing
import MusicvideoPlugin

@Suite("BlockingValidator (t=0 blocking)")
struct BlockingValidatorTests {
    @Test("a full three-axis prompt passes")
    func fullPasses() {
        let r = BlockingValidator.validate(
            visualPrompt: "Alex stands, one hand on the hip, about to turn away, medium shot, slow dolly in.",
            hasCharacters: true)
        #expect(r.ok)
    }

    @Test("a missing camera move fails on the CAMERA axis")
    func missingCameraMove() {
        let r = BlockingValidator.validate(
            visualPrompt: "Alex stands, hand on hip, about to turn, medium shot.",
            hasCharacters: true)
        #expect(!r.ok)
        #expect(r.reasons.contains { $0.contains("CAMERA") })
    }

    @Test("a magic preamble without pose/vector fails")
    func magicPreambleFails() {
        let r = BlockingValidator.validate(
            visualPrompt: "START FRAME: a person, medium shot, static.",
            hasCharacters: false)
        #expect(!r.ok)
        #expect(r.reasons.contains { $0.contains("POSE") })
    }

    @Test("a figure-less cutaway skips pose/vector but still needs a camera anchor")
    func figurelessCutaway() {
        let ok = BlockingValidator.validate(
            visualPrompt: "empty street, wide shot, static, a tumbleweed rolls through.",
            hasCharacters: false)
        #expect(ok.ok)   // pose/vector skipped; framing + move present
        let noCamera = BlockingValidator.validate(
            visualPrompt: "empty street at dusk, a tumbleweed rolls through.",
            hasCharacters: false)
        #expect(!noCamera.ok)   // camera still mandatory
    }
}
