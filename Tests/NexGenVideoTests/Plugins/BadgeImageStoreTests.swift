import Foundation
import Testing

@testable import NexGenVideo

/// The badge loader's URL guard + in-memory cache (finding 7). The remote path
/// needs the network, so only the pure guard and the local-file cache path — the
/// parts with testable logic — are exercised here.
@Suite("Plugin badge loader")
struct BadgeImageStoreTests {

    @Test func isLoadableAllowsFileAndHTTPSOnly() {
        #expect(BadgeImageStore.isLoadable(URL(string: "https://ex.com/b.png")!))
        #expect(BadgeImageStore.isLoadable(URL(string: "HTTPS://ex.com/b.png")!))
        #expect(BadgeImageStore.isLoadable(URL(fileURLWithPath: "/tmp/b.png")))
        #expect(!BadgeImageStore.isLoadable(URL(string: "http://ex.com/b.png")!))
        #expect(!BadgeImageStore.isLoadable(URL(string: "ftp://ex.com/b.png")!))
    }

    @MainActor
    @Test func loadsAndCachesLocalFile() async throws {
        // A 1×1 transparent PNG — enough for NSImage(data:) to decode headless.
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("badge-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(BadgeImageStore.shared.cached(url) == nil)
        let image = await BadgeImageStore.shared.image(for: url)
        #expect(image != nil)
        // The load is cached — the same instance is returned on subsequent calls.
        #expect(BadgeImageStore.shared.cached(url) === image)
        #expect(await BadgeImageStore.shared.image(for: url) === image)
    }

    @MainActor
    @Test func disallowedSchemeDoesNotLoad() async {
        let image = await BadgeImageStore.shared.image(for: URL(string: "http://ngvtest.invalid/b.png")!)
        #expect(image == nil)
    }
}
