import Foundation
import Testing
@testable import NexGenEngine

/// #166: the structured camera triplet → prompt prose (port of frames/generate.py's camera projection).
@Suite("Camera prose")
struct CameraProseTests {
    @Test("full triplet + note projects height, spaced angle, lens feel, note")
    func fullTriplet() throws {
        let cam = CameraSetup(height: .eyeLevel, angle: .threeQuarterLeft, lensHint: .wide, note: "handheld drift")
        #expect(cam.promptProse() == "eye_level camera height, three quarter left, wide lens feel, handheld drift")
    }

    @Test("no note omits the trailing clause")
    func noNote() {
        let cam = CameraSetup(height: .low, angle: .frontal, lensHint: .normal)
        #expect(cam.promptProse() == "low camera height, frontal, normal lens feel")
    }

    @Test("profile/back angles spell out with spaces")
    func spacedAngles() {
        #expect(CameraSetup(height: .high, angle: .profileRight, lensHint: .long).promptProse()
            == "high camera height, profile right, long lens feel")
        #expect(CameraSetup(height: .overhead, angle: .back, lensHint: .normal).promptProse()
            == "overhead camera height, back, normal lens feel")
    }

    @Test("framing projects to a composition line")
    func framingComposition() {
        #expect(Framing.ms.compositionProse == "ms framing")
        #expect(Framing.wide.compositionProse == "wide framing")
    }
}
