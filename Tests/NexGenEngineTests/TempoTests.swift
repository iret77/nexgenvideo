import Foundation
import Testing
@testable import NexGenEngine

/// Port of `plugins/musicvideo/tests/test_tempo.py`.
@Suite("Musicvideo Tempo")
struct TempoTests {
    @Test("tempo bands are non-empty")
    func tempoBandsNonEmpty() {
        #expect(tempoBands.count >= 1)
    }

    @Test("classify returns a TempoBand with sane fields")
    func classifyReturnsSaneFields() {
        let band = classifyTempo(128.0)
        #expect(!band.label.isEmpty)
        #expect(0.0 < band.aslMin)
        #expect(band.aslMin <= band.aslTarget)
        #expect(band.aslTarget <= band.aslMax)
        #expect(band.aslMax <= band.hardCap)
        #expect(band.bpmMin <= 128.0 && 128.0 < band.bpmMax)
    }

    @Test("classify picks uptempo for fast BPM")
    func classifyPicksUptempo() {
        #expect(classifyTempo(140.0).label == "uptempo_dance")
    }

    @Test("classify picks downtempo for slow BPM")
    func classifyPicksDowntempo() {
        let band = classifyTempo(75.0)
        #expect(band.label == "downtempo_soul")
        #expect(band.bpmMin <= 75.0 && 75.0 < band.bpmMax)
    }

    @Test("classify in phrase mode relaxes the band")
    func classifyPhraseModeRelaxesBand() {
        let base = classifyTempo(128.0)
        let phrase = classifyTempo(128.0, mode: "phrase")
        #expect(phrase.hardCap > base.hardCap)
        #expect(phrase.label.hasSuffix("_phrase"))
    }

    @Test("asl_violation smoke")
    func aslViolationSmoke() {
        let band = classifyTempo(128.0)
        let result = aslViolation([1.5, 1.5, 2.0], band: band)
        #expect(result.status == "ok")
        #expect(result.asl > 0.0)
    }
}
