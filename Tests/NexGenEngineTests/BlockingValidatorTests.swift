import Foundation
import Testing
import MusicvideoPlugin

@Suite("BlockingValidator (t=0 blocking)")
struct BlockingValidatorTests {
    @Test("a full subject-blocking prompt passes")
    func fullPasses() {
        let r = BlockingValidator.validate(
            visualPrompt: "Alex stands, one hand on the hip, about to turn away, medium shot, slow dolly in.",
            hasCharacters: true)
        #expect(r.ok)
    }

    @Test("structured camera truth is not required in the subject prompt")
    func cameraIsStructured() {
        let r = BlockingValidator.validate(
            visualPrompt: "Alex stands, hand on hip, about to turn, medium shot.",
            hasCharacters: true)
        #expect(r.ok)
    }

    @Test("a magic preamble without pose/vector fails")
    func magicPreambleFails() {
        let r = BlockingValidator.validate(
            visualPrompt: "START FRAME: a person, medium shot, static.",
            hasCharacters: false)
        #expect(!r.ok)
        #expect(r.reasons.contains { $0.contains("POSE") })
    }

    @Test("a figure-less cutaway skips subject blocking")
    func figurelessCutaway() {
        let ok = BlockingValidator.validate(
            visualPrompt: "empty street, wide shot, static, a tumbleweed rolls through.",
            hasCharacters: false)
        #expect(ok.ok)
        let noCamera = BlockingValidator.validate(
            visualPrompt: "empty street at dusk, a tumbleweed rolls through.",
            hasCharacters: false)
        #expect(noCamera.ok)
    }
}
