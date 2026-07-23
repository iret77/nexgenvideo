import Foundation
import Testing
@testable import NexGenVideo

@Suite("HF model store")
struct HFModelStoreTests {
    @Test("SHA-256 matches the published digest format")
    func sha256() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-model-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)

        #expect(try HFModelStore.sha256Hex(of: url)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
