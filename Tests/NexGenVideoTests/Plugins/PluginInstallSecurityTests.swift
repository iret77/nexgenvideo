import Foundation
import Testing

@testable import NexGenVideo

/// Install-path security: https-only fetching (finding 5) and staged-install
/// rollback (finding 3 — a bad download never disturbs the working install).
@Suite("Loadable-pack install security")
struct PluginInstallSecurityTests {

    @MainActor
    @Test func localSnapshotBindsBytesPermissionsAndContainedLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.ngvpack", isDirectory: true)
        let copy = root.appendingPathComponent("copy.ngvpack", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = source.appendingPathComponent("payload")
        try Data("original".utf8).write(to: file)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "payload")
        try fm.copyItem(at: source, to: copy)
        let expected = try PluginInstaller.localBundleFingerprint(source)
        #expect(try PluginInstaller.localBundleFingerprint(copy) == expected)
        try Data("changed".utf8).write(to: copy.appendingPathComponent("payload"))
        #expect(try PluginInstaller.localBundleFingerprint(copy) != expected)
        try Data("original".utf8).write(to: copy.appendingPathComponent("payload"))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: copy.appendingPathComponent("payload").path)
        #expect(try PluginInstaller.localBundleFingerprint(copy) != expected)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("escape").path, withDestinationPath: "../outside")
        #expect(throws: (any Error).self) { try PluginInstaller.localBundleFingerprint(source) }
    }

    @MainActor
    @Test func localCommitRejectsAliasesChangedCopiesAndVersionReplacement() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.ngvpack", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source.appendingPathComponent("payload"))
        let expected = try PluginInstaller.localBundleFingerprint(source)
        let id = "ngvtest-local-" + UUID().uuidString.lowercased()
        let directory = PluginPaths.versionDirectory(id: id)
        try fm.createDirectory(at: PluginPaths.installDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory); try? fm.removeItem(at: root) }
        try fm.createSymbolicLink(atPath: directory.path, withDestinationPath: outside.path)
        #expect(throws: (any Error).self) {
            try PluginInstaller.commitValidatedBundle(source, id: id, version: "0.0.1", replaceExisting: false, expectedTree: expected)
        }
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
        try fm.removeItem(at: directory)
        try Data("changed after validation".utf8).write(to: source.appendingPathComponent("payload"))
        #expect(throws: (any Error).self) {
            try PluginInstaller.commitValidatedBundle(source, id: id, version: "0.0.1", replaceExisting: false, expectedTree: expected)
        }
        #expect(!fm.fileExists(atPath: PluginPaths.installURL(id: id, version: "0.0.1").path))
        try Data("original".utf8).write(to: source.appendingPathComponent("payload"))
        try PluginInstaller.commitValidatedBundle(source, id: id, version: "0.0.1", replaceExisting: false, expectedTree: expected)
        let installed = PluginPaths.installURL(id: id, version: "0.0.1")
        try Data("different version contents".utf8).write(to: source.appendingPathComponent("payload"))
        let changed = try PluginInstaller.localBundleFingerprint(source)
        #expect(throws: (any Error).self) {
            try PluginInstaller.commitValidatedBundle(source, id: id, version: "0.0.1", replaceExisting: false, expectedTree: changed)
        }
        #expect(try PluginInstaller.localBundleFingerprint(installed) == expected)
        #expect(try fm.contentsOfDirectory(atPath: directory.path) == ["0.0.1.ngvpack"])
    }

    @MainActor
    @Test func localImportRejectsRemoteURLsSymlinksAndMalformedMetadata() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("pack.ngvpack", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias.ngvpack", isDirectory: true)
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: source.path)
        for url in [URL(string: "https://example.com/pack.ngvpack")!, alias] {
            do {
                _ = try PluginInstaller.installLocal(at: url)
                Issue.record("A remote URL or symlink was admitted as a local pack")
            } catch let error as PluginInstaller.InstallError {
                guard case .unpack(let reason) = error else {
                    Issue.record("The source was not rejected before staging"); continue
                }
                #expect(reason == "choose a .ngvpack bundle from disk")
            }
        }
        do {
            _ = try PluginInstaller.installLocal(at: source)
            Issue.record("Missing pack metadata was admitted")
        } catch let error as PluginInstaller.InstallError {
            guard case .gate(.malformedMetadata(_)) = error else {
                Issue.record("Missing metadata did not fail its structural gate"); return
            }
        }
    }

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
