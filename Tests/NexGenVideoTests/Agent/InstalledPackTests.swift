import Foundation
import Testing

@testable import NexGenVideo

@Suite("Installed native pack")
struct InstalledPackTests {

    @Test func musicvideoPackIsListed() {
        let pack = InstalledPack.named("musicvideo")
        #expect(pack != nil)
        // Mirrors the retired plugins/musicvideo/ngv-plugin.json values.
        #expect(pack?.displayName == "Music Video Studio")
        #expect(pack?.tagline?.isEmpty == false)
        #expect(InstalledPack.all.contains { $0.name == "musicvideo" })
    }

    @Test func unknownPackResolvesToNil() {
        #expect(InstalledPack.named("does-not-exist") == nil)
        #expect(InstalledPack.named(nil) == nil)
    }
}
