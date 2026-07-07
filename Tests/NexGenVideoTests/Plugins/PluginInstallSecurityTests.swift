import Foundation
import Testing

@testable import NexGenVideo

/// Install-path security: https-only fetching (finding 5) and staged-install
/// rollback (finding 3 — a bad download never disturbs the working install).
@Suite("Loadable-pack install security")
struct PluginInstallSecurityTests {

    /// Build a catalog entry via JSON decode (robust against later optional fields).
    private func entry(id: String = "ngvtest", url: String, sha256: String = String(repeating: "0", count: 64)) throws -> PluginCatalog.Entry {
        let json = """
        {"id":"\(id)","displayName":"Test","tagline":"t","version":"0.0.1","minAppVersion":"0.1.0","url":"\(url)","sha256":"\(sha256)"}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(PluginCatalog.Entry.self, from: json)
    }

    // MARK: - https-only (finding 5)

    @Test func isHTTPSGuard() {
        #expect(PluginInstaller.isHTTPS(URL(string: "https://example.com/x.zip")!))
        #expect(PluginInstaller.isHTTPS(URL(string: "HTTPS://example.com/x.zip")!))
        #expect(!PluginInstaller.isHTTPS(URL(string: "http://example.com/x.zip")!))
        #expect(!PluginInstaller.isHTTPS(URL(string: "ftp://example.com/x.zip")!))
        #expect(!PluginInstaller.isHTTPS(URL(fileURLWithPath: "/tmp/x.zip")))
    }

    @MainActor
    @Test func installRejectsNonHTTPSBeforeDownloading() async throws {
        let e = try entry(url: "http://example.com/pack.ngvpack.zip")
        var fetched = false
        do {
            _ = try await PluginInstaller.install(e, appVersion: nil, fetch: { _ in
                fetched = true
                return Data()
            })
            Issue.record("expected an insecure-URL error to throw")
        } catch let error as PluginInstaller.InstallError {
            guard case .insecureURL = error else {
                Issue.record("expected .insecureURL, got \(error)"); return
            }
        }
        #expect(!fetched)  // the guard fires before any download
    }

    @Test func catalogFetchRejectsNonHTTPS() async {
        let result = await PluginCatalogService.fetch(from: URL(string: "http://evil.example/plugins.json")!)
        switch result {
        case .success:
            Issue.record("a non-https catalog URL must not fetch")
        case .failure(let error):
            guard case PluginCatalogService.FetchError.insecureURL = error else {
                Issue.record("expected .insecureURL, got \(error)"); return
            }
        }
    }

    // MARK: - Staged rollback (finding 3)

    /// A checksum mismatch must throw and leave the previous install byte-for-byte
    /// intact — the new bundle is only swapped in AFTER every gate passes.
    @MainActor
    @Test func badChecksumLeavesPriorInstallIntact() async throws {
        let id = "ngvtest-rollback"
        let fm = FileManager.default
        let dest = PluginPaths.installURL(id: id)
        try fm.createDirectory(at: PluginPaths.installDirectory, withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        // Plant a sentinel "prior install" at the exact destination path.
        try fm.createDirectory(at: dest.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let marker = dest.appendingPathComponent("Contents/marker.txt")
        try "prior-install".write(to: marker, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: dest) }

        let e = try entry(id: id, url: "https://ngvtest.invalid/rollback.ngvpack.zip")
        var fetched = false
        do {
            _ = try await PluginInstaller.install(e, appVersion: nil, fetch: { _ in
                fetched = true
                return Data("this is not the real pack, its sha256 won't match".utf8)
            })
            Issue.record("expected a checksum mismatch to throw")
        } catch let error as PluginInstaller.InstallError {
            guard case .checksumMismatch = error else {
                Issue.record("expected .checksumMismatch, got \(error)"); return
            }
        }

        #expect(fetched)  // the download ran; the checksum gate rejected it
        // The prior install survives, unchanged.
        #expect(fm.fileExists(atPath: marker.path))
        #expect((try? String(contentsOf: marker, encoding: .utf8)) == "prior-install")
    }
}
