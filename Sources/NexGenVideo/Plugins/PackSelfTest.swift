import Foundation
import NexGenEngine

/// Headless CI self-test for the pack LOAD path — the guard that static `otool`/`nm` checks can't be
/// (they missed the 0.7.6 "entry point not found" rpath regression). When `NGV_SELFTEST_PACK` points
/// at a `.ngvpack`, the REAL app binary — with its real `Contents/Frameworks/libNexGenEngine.dylib`
/// and rpath — loads it through the actual gate + `Bundle.load()` + `principalClass as? PackEntry.Type`
/// cast, prints the result, and exits. CI runs it with the pack in an
/// EXTERNAL directory so it reproduces the field layout: pack outside the app bundle, shared engine
/// resolved via the host's `@executable_path/../Frameworks`. No-op in normal launches.
@MainActor
enum PackSelfTest {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["NGV_SELFTEST_PACK"], !path.isEmpty else { return }
        let record = PluginLoader.load(at: URL(fileURLWithPath: path))
        if ProcessInfo.processInfo.environment[
            "NGV_SELFTEST_EXPECT_ENGINE_INCOMPATIBLE"
        ] == "1" {
            if case .incompatible(.requiresEngineContract) = record.state {
                FileHandle.standardOutput.write(
                    Data("SELFTEST_PACK_OK rejected incompatible engine contract\n".utf8)
                )
                exit(0)
            }
            FileHandle.standardError.write(
                Data("SELFTEST_PACK_FAIL expected an engine-contract rejection\n".utf8)
            )
            exit(1)
        }
        if record.state == .loaded {
            if ProcessInfo.processInfo.environment["NGV_SELFTEST_LOAD_ONLY"] == "1" {
                FileHandle.standardOutput.write(
                    Data("SELFTEST_PACK_OK loaded compatible \(record.id) v\(record.version)\n".utf8)
                )
                exit(0)
            }
            if let reason = requiredResourceFailure(record) {
                FileHandle.standardError.write(Data("SELFTEST_PACK_FAIL \(record.id): \(reason)\n".utf8))
                exit(1)
            }
            FileHandle.standardOutput.write(Data("SELFTEST_PACK_OK loaded \(record.id) v\(record.version)\n".utf8))
            exit(0)
        }
        let reason = record.incompatibility?.reason ?? "state=\(record.state)"
        FileHandle.standardError.write(Data("SELFTEST_PACK_FAIL \(record.id.isEmpty ? "?" : record.id): \(reason)\n".utf8))
        exit(1)
    }

    private static func requiredResourceFailure(_ record: InstalledPluginRecord) -> String? {
        guard record.id == "musicvideo" else { return nil }
        guard let manifest = HardStepManifest.load(bundleURL: record.bundleURL) else {
            return "required hardsteps.json is missing or malformed"
        }
        let startup = manifest.steps(for: "project_init")
        guard let song = startup.first(where: { $0.kind == .song }),
              song.required,
              song.accept.contains("audio") else {
            return "project_init has no required audio song intake"
        }
        guard startup.map(\.kind) == [.song, .lyrics] else {
            return "project_init hard-step order is not exactly track, lyrics"
        }
        guard startup.dropFirst().allSatisfy({ !$0.required }) else {
            return "lyrics intake is not optional"
        }
        guard manifest.steps(for: "analysis").isEmpty else {
            return "analysis contains file intake"
        }
        let creative = manifest.steps(for: "brief")
        guard creative.map(\.kind) == [.script, .character, .location, .style] else {
            return "brief hard-step order is not existing story, characters, locations, style"
        }
        guard creative.allSatisfy({ !$0.required }) else {
            return "creative-material intake is not fully optional"
        }
        let failures = PipelineAgentContract.failures(
            registry: PackCatalog.registry(activePack: record.id),
            manifest: manifest,
            phaseDocument: {
                phaseDocument($0, bundleURL: record.bundleURL)
            }
        )
        return failures.first
    }

    private static func phaseDocument(
        _ name: String,
        bundleURL: URL
    ) -> String? {
        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let suffix = "/MusicvideoPack/phases/\(name).md"
        for case let url as URL in enumerator where url.path.hasSuffix(suffix) {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return nil
    }
}
