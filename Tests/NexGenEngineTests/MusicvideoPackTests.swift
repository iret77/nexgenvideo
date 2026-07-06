import Foundation
import Testing
@testable import NexGenEngine

/// Port of `plugins/musicvideo/tests/test_pack.py`.
@Suite("Musicvideo Pack")
struct MusicvideoPackTests {
    @Test("pack registers music behavior")
    func packRegistersMusicBehavior() {
        let reg = PackRegistry()
        reg.load(MusicvideoPack())
        #expect(reg.engine.durationPolicy != nil)
        #expect(reg.engine.projectDirs.contains("audio"))
        #expect(reg.engine.projectDirs.contains("analysis"))
        #expect(reg.engine.sanityChecks["tempo"] != nil)
        #expect(reg.engine.phases["analysis"] != nil)
    }

    @Test("music duration bands")
    func musicDurationBands() {
        let policy = MusicDurationPolicy()
        let band = policy.band(for: .section, context: [:])
        #expect((band.minS, band.maxS) == (6.0, 60.0))
    }

    @Test("all mode duration bands carried over exactly")
    func allModeDurationBandsExact() {
        let policy = MusicDurationPolicy()
        #expect((policy.band(for: .beat, context: [:]).minS, policy.band(for: .beat, context: [:]).maxS) == (4.0, 15.0))
        #expect(
            (policy.band(for: .phrase, context: [:]).minS, policy.band(for: .phrase, context: [:]).maxS) == (4.0, 15.0)
        )
        #expect(
            (policy.band(for: .section, context: [:]).minS, policy.band(for: .section, context: [:]).maxS)
                == (6.0, 60.0)
        )
        #expect(
            (policy.band(for: .multicam, context: [:]).minS, policy.band(for: .multicam, context: [:]).maxS)
                == (30.0, 600.0)
        )
    }

    @Test("pack satisfies the Pack contract")
    func packSatisfiesContract() {
        let pack: Pack = MusicvideoPack()
        #expect(pack.name == "musicvideo")
        #expect(pack.version == "0.0.1")
    }

    @Test("pack registers the analysis UI contract entry")
    func packRegistersUIContract() {
        let reg = PackRegistry()
        reg.load(MusicvideoPack())
        let entry = reg.engine.uiContracts["analysis"]
        #expect(entry?.surface == "choice")
        #expect(entry?.taskClass == "classification")
    }
}
