import Foundation
import Testing
import NexGenEngine
import MusicvideoPlugin

@Suite("PackWiring")
struct PackWiringTests {
    @Test("a generic project has nothing to wire")
    func genericNoPack() {
        #expect(PackWiring.verify(expected: nil, resolved: nil, registry: EngineRegistry()) == .noPack)
    }

    @Test("the P0 break: project declares a pack the runtime resolves to nil is caught")
    func unresolvedIsCaught() {
        // Package says "musicvideo" but the runtime resolution returned nil — the exact P0 symptom.
        let r = PackWiring.verify(expected: "musicvideo", resolved: nil, registry: EngineRegistry())
        #expect(r == .unresolved(expected: "musicvideo", resolved: nil))
        #expect(r.isWired == false)
    }

    @Test("resolved AND the pack registered its probe ⇒ wired")
    func wiredWhenRegistered() {
        PackCatalog.register(MusicvideoPack())
        let registry = PackCatalog.registry(activePack: "musicvideo")
        #expect(PackWiring.verify(expected: "musicvideo", resolved: "musicvideo", registry: registry) == .ok)
    }

    @Test("resolved but no probe in the registry ⇒ runtime absent, not a false pass")
    func runtimeAbsentWhenNoProbe() {
        let r = PackWiring.verify(expected: "musicvideo", resolved: "musicvideo", registry: EngineRegistry())
        #expect(r == .runtimeAbsent(pack: "musicvideo"))
    }

    @Test("token is deterministic and pack/nonce specific")
    func tokenStable() {
        #expect(PackWiring.token(pack: "musicvideo", nonce: "n1") == PackWiring.token(pack: "musicvideo", nonce: "n1"))
        #expect(PackWiring.token(pack: "musicvideo", nonce: "n1") != PackWiring.token(pack: "musicvideo", nonce: "n2"))
        #expect(PackWiring.token(pack: "musicvideo", nonce: "n1") != PackWiring.token(pack: "other", nonce: "n1"))
    }
}
