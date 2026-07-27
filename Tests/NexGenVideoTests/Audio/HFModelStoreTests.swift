import Foundation
import Testing
@testable import NexGenVideo

@Suite("HF model store")
struct HFModelStoreTests {
    private func temporaryStore() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hf-model-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("SHA-256 matches the published digest format")
    func sha256() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-model-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)

        #expect(try HFModelStore.sha256Hex(of: url)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("a pinned revision and matching download are installed")
    func matchingDownloadIsInstalled() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let payload = Data("abc".utf8)
        var requestedURL: URL?

        let installed = try HFModelStore.ensure(
            repo: "owner/model",
            revision: "0123456789abcdef0123456789abcdef01234567",
            file: "model.bin",
            subdir: "test",
            minBytes: payload.count,
            expectedSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            storeRoot: store,
            downloader: { source, destination in
                requestedURL = source
                try payload.write(to: destination)
            }
        )

        #expect(requestedURL?.absoluteString.contains(
            "/resolve/0123456789abcdef0123456789abcdef01234567/"
        ) == true)
        #expect(try Data(contentsOf: installed) == payload)
    }

    @Test("a mutable Hugging Face revision is rejected before download")
    func mutableRevisionIsRejected() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store) }
        var downloaded = false

        #expect(throws: HFModelStore.StoreError.self) {
            _ = try HFModelStore.ensure(
                repo: "owner/model",
                revision: "main",
                file: "model.bin",
                subdir: "test",
                minBytes: 1,
                expectedSHA256: String(repeating: "0", count: 64),
                storeRoot: store,
                downloader: { _, _ in downloaded = true }
            )
        }
        #expect(downloaded == false)
    }

    @Test("a corrupt cache is replaced only by verified bytes")
    func corruptCacheIsReplaced() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let directory = store.appendingPathComponent("test", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = directory.appendingPathComponent("model.bin")
        try Data("corrupt".utf8).write(to: cached)
        let payload = Data("abc".utf8)
        var downloaded = false

        let installed = try HFModelStore.ensure(
            urlString: "https://example.test/model.bin",
            file: "model.bin",
            subdir: "test",
            minBytes: payload.count,
            expectedSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            storeRoot: store,
            downloader: { _, destination in
                downloaded = true
                try payload.write(to: destination)
            }
        )

        #expect(downloaded)
        #expect(try Data(contentsOf: installed) == payload)
    }

    @Test("a download with the wrong hash is rejected and removed")
    func wrongDownloadHashIsRejected() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store) }

        #expect(throws: HFModelStore.StoreError.self) {
            _ = try HFModelStore.ensure(
                urlString: "https://example.test/model.bin",
                file: "model.bin",
                subdir: "test",
                minBytes: 1,
                expectedSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                storeRoot: store,
                downloader: { _, destination in
                    try Data("wrong".utf8).write(to: destination)
                }
            )
        }
        let directory = store.appendingPathComponent("test", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("Whisper accepts only the documented immutable model set")
    func whisperModelsArePinned() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store) }
        #expect(Set(WhisperModelStore.specifications.keys)
            == Set(["large-v3-turbo", "medium", "small"]))
        #expect(WhisperModelStore.specifications["large-v3-turbo"]?.revision
            == "5359861c739e955e79d9a303bcbc70fb988958b1")
        #expect(WhisperModelStore.specifications["large-v3-turbo"]?.sha256
            == "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")

        #expect(throws: WhisperModelStore.ModelError.self) {
            _ = try WhisperModelStore.ensureModel(
                "unapproved-model",
                storeRoot: store,
                downloader: { _, _ in Issue.record("unsupported model reached the downloader") }
            )
        }
    }
}
