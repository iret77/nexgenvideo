import Foundation
import Testing
import NexGenEngine
import MusicvideoPlugin

@testable import NexGenVideo

@Suite("Installed native pack")
struct InstalledPackTests {

    @Test func musicvideoPackIsListed() throws {
        // Packs are loaded at runtime now (empty compiled-in list); register the
        // loadable pack the way the host's PluginLoader does before asserting.
        try CurrentMusicvideoFixture.load()
        let pack = InstalledPack.named("musicvideo")
        #expect(pack != nil)
        // Mirrors plugins/musicvideo.json.
        #expect(pack?.displayName == "Music Video")
        #expect(pack?.tagline?.isEmpty == false)
        #expect(InstalledPack.all.contains { $0.name == "musicvideo" })
    }

    @Test func unknownPackResolvesToNil() {
        #expect(InstalledPack.named("does-not-exist") == nil)
        #expect(InstalledPack.named(nil) == nil)
    }
}
