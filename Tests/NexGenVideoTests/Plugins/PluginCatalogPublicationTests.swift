import Foundation
import Testing

@Suite("Plugin catalog publication")
struct PluginCatalogPublicationTests {
    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/publish_plugin_catalog.py")
    }

    private var releaseWorkflowURL: URL {
        scriptURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/release.yml")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-publication-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeEntry(to directory: URL, sha256: String) throws {
        try Data("pack".utf8).write(
            to: directory.appendingPathComponent("musicvideo.ngvpack.zip")
        )
        let entry: [String: Any] = [
            "id": "musicvideo",
            "displayName": "Music Video",
            "version": "1.0.0",
            "projectSchema": "musicvideo/2.0.0",
            "migratesFrom": ["musicvideo/legacy", "musicvideo/1.0.0"],
            "minAppVersion": "1.0.0",
            "zip": "musicvideo.ngvpack.zip",
            "sha256": sha256,
        ]
        try JSONSerialization.data(withJSONObject: entry).write(
            to: directory.appendingPathComponent("musicvideo.entry.json")
        )
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (process.terminationStatus, output)
    }

    private func catalog(at url: URL) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    @Test("repeated previews project the same pack into isolated channels")
    func repeatedPreviewsStayIsolated() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = root.appendingPathComponent("entries", isDirectory: true)
        try FileManager.default.createDirectory(at: entries, withIntermediateDirectories: true)
        try writeEntry(to: entries, sha256: String(repeating: "a", count: 64))
        let stable = root.appendingPathComponent("stable.json")
        let stableData = Data(#"{"schema":"plugins/v2","plugins":[]}"#.utf8)
        try stableData.write(to: stable)

        let first = root.appendingPathComponent("preview-1.json")
        let second = root.appendingPathComponent("preview-2.json")
        #expect(try run([
            entries.path,
            "https://example.test/releases/download/preview-1",
            first.path,
        ]).status == 0)
        #expect(try run([
            entries.path,
            "https://example.test/releases/download/preview-2",
            second.path,
        ]).status == 0)

        let firstCatalog = try catalog(at: first)
        let secondCatalog = try catalog(at: second)
        let firstPlugins = try #require(firstCatalog["plugins"] as? [[String: Any]])
        let secondPlugins = try #require(secondCatalog["plugins"] as? [[String: Any]])
        #expect((firstPlugins.first?["url"] as? String)?.contains("/preview-1/") == true)
        #expect((secondPlugins.first?["url"] as? String)?.contains("/preview-2/") == true)
        #expect(firstPlugins.first?["projectSchema"] as? String == "musicvideo/2.0.0")
        #expect(firstPlugins.first?["migratesFrom"] as? [String] == [
            "musicvideo/legacy",
            "musicvideo/1.0.0",
        ])
        #expect(try Data(contentsOf: stable) == stableData)
    }

    @Test("preview builds cannot run production blocker or resume mutations")
    func previewSkipsProductionGateMutations() throws {
        let workflow = try String(contentsOf: releaseWorkflowURL, encoding: .utf8)

        #expect(workflow.contains("""
              - name: Reject open release blockers
                if: ${{ inputs.dry_run == false }}
        """))
        #expect(workflow.contains("""
              - name: Inspect or resume release publication
                if: ${{ inputs.dry_run == false }}
        """))
        #expect(workflow.contains("gh label list"))
        #expect(workflow.contains("--repo iret77/nexgenvideo"))
        #expect(!workflow.contains("gh label view"))
    }

    @Test("publication resume updates the dispatched ref before pushing appcast")
    func resumeFastForwardsBeforeAppcastCommit() throws {
        let workflow = try String(contentsOf: releaseWorkflowURL, encoding: .utf8)
        let fetch = try #require(
            workflow.range(of: #"git fetch --no-tags origin "$GITHUB_REF_NAME""#)
        )
        let checkout = try #require(workflow.range(of: "git checkout --detach FETCH_HEAD"))
        let appcast = try #require(workflow.range(of: "python3 scripts/update_appcast.py"))

        #expect(fetch.lowerBound < checkout.lowerBound)
        #expect(checkout.lowerBound < appcast.lowerBound)
    }

    @Test("a published stable pack version is immutable")
    func stableVersionIsImmutable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = root.appendingPathComponent("entries", isDirectory: true)
        try FileManager.default.createDirectory(at: entries, withIntermediateDirectories: true)
        try writeEntry(to: entries, sha256: String(repeating: "b", count: 64))
        let existing = root.appendingPathComponent("catalog.json")
        let existingData = Data("""
        {
          "schema": "plugins/v2",
          "plugins": [{
            "id": "musicvideo",
            "version": "1.0.0",
            "sha256": "\(String(repeating: "a", count: 64))",
            "url": "https://example.test/releases/download/plugins/musicvideo-1.0.0.ngvpack.zip"
          }]
        }
        """.utf8)
        try existingData.write(to: existing)
        let output = root.appendingPathComponent("pending.json")

        let result = try run([
            entries.path,
            "https://example.test/releases/download/plugins",
            output.path,
            "--existing",
            existing.path,
        ])

        #expect(result.status != 0)
        #expect(result.output.contains("refusing to replace published musicvideo-1.0.0"))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: existing) == existingData)
    }
}
