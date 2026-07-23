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
        guard let song = manifest.steps(for: "analysis").first(where: { $0.kind == .song }),
              song.required,
              song.accept.contains("audio") else {
            return "analysis has no required audio song intake"
        }
        let expectedByPhase: [String: Set<String>] = [
            "project_init": ["script", "character", "location", "style"],
            "analysis": ["song", "lyrics"],
        ]
        for (phase, expected) in expectedByPhase {
            let present = Set(manifest.steps(for: phase).map(\.kind.rawValue))
            let missing = expected.subtracting(present)
            guard missing.isEmpty else {
                return "\(phase) hard steps are missing: \(missing.sorted().joined(separator: ", "))"
            }
        }
        return nil
    }
}
