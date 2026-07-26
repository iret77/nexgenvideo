import Foundation

/// Headless CI self-test for the pack LOAD path — the guard that static `otool`/`nm` checks can't be
/// (they missed the 0.7.6 "entry point not found" rpath regression). When `NGV_SELFTEST_PACK` points
/// at a `.ngvpack`, the REAL app binary — with its real `Contents/Frameworks/libNexGenEngine.dylib`
/// and rpath — loads it through the actual gate + `Bundle.load()` + `principalClass as? PackEntry.Type`
/// cast, prints the result, and exits (0 = loaded, 1 = anything else). CI runs it with the pack in an
/// EXTERNAL directory so it reproduces the field layout: pack outside the app bundle, shared engine
/// resolved via the host's `@executable_path/../Frameworks`. No-op in normal launches.
@MainActor
enum PackSelfTest {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["NGV_SELFTEST_PACK"], !path.isEmpty else { return }
        let record = PluginLoader.load(at: URL(fileURLWithPath: path))
        if record.state == .loaded {
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
        let expected: [HardStep.Kind] = [.song, .lyrics, .script, .character, .location, .style]
        guard startup.map(\.kind) == expected else {
            return "project_init hard-step order is not track, lyrics, script, character, location, style"
        }
        guard manifest.steps(for: "analysis").isEmpty else {
            return "analysis duplicates startup intake"
        }
        return nil
    }
}
