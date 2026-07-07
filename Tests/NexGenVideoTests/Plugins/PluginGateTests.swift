import Foundation
import Testing

@testable import NexGenVideo

@Suite("Loadable-pack version gate")
struct PluginGateTests {

    // MARK: - SemanticVersion

    @Test func parsesStrictTriples() {
        #expect(SemanticVersion("1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion("0.4.1") == SemanticVersion(major: 0, minor: 4, patch: 1))
        #expect(SemanticVersion("10.20.30") == SemanticVersion(major: 10, minor: 20, patch: 30))
        // Surrounding whitespace is tolerated; leading zeros parse numerically.
        #expect(SemanticVersion(" 0.4.1 ") == SemanticVersion(major: 0, minor: 4, patch: 1))
        #expect(SemanticVersion("01.02.03") == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test func rejectsNonStrict() {
        #expect(SemanticVersion("") == nil)                // empty
        #expect(SemanticVersion("1.2") == nil)             // wrong arity (too few)
        #expect(SemanticVersion("4") == nil)               // wrong arity (too few)
        #expect(SemanticVersion("1.2.3.4") == nil)         // wrong arity (too many)
        #expect(SemanticVersion("1.2.3garbage") == nil)    // trailing garbage
        #expect(SemanticVersion("1.2.3-rc1") == nil)       // pre-release metadata
        #expect(SemanticVersion("1.2.3-beta.4") == nil)    // pre-release metadata
        #expect(SemanticVersion("1.2.3+build") == nil)     // build metadata
        #expect(SemanticVersion("v1.2.3") == nil)          // leading non-digit
        #expect(SemanticVersion("1.x.3") == nil)           // non-numeric component
        #expect(SemanticVersion("1..3") == nil)            // empty middle component
        #expect(SemanticVersion("-1.2.3") == nil)          // sign
        #expect(SemanticVersion("abc") == nil)
    }

    @Test func ordersCorrectly() {
        #expect(SemanticVersion("0.4.1")! < SemanticVersion("0.4.2")!)
        #expect(SemanticVersion("0.9.9")! < SemanticVersion("1.0.0")!)
        #expect(SemanticVersion("1.2.0")! < SemanticVersion("1.10.0")!)  // numeric, not lexical
        #expect(SemanticVersion("2.0.0")! >= SemanticVersion("2.0.0")!)
    }

    // MARK: - PluginGate

    private func info(id: String = "musicvideo", version: String = "0.0.1",
                      minApp: String = "0.1.0", principal: String = "MusicvideoPackEntry") -> PluginBundleInfo {
        PluginBundleInfo(plist: [
            PluginBundleInfo.Key.id: id,
            PluginBundleInfo.Key.version: version,
            PluginBundleInfo.Key.minAppVersion: minApp,
            PluginBundleInfo.Key.principalClass: principal,
            PluginBundleInfo.Key.displayName: "Music Video Studio",
            PluginBundleInfo.Key.tagline: "tag",
        ])
    }

    @Test func compatibleWhenAppMeetsMinimum() {
        #expect(PluginGate.evaluate(info: info(minApp: "0.1.0"), appVersion: "0.4.1") == nil)
        #expect(PluginGate.evaluate(info: info(minApp: "0.4.1"), appVersion: "0.4.1") == nil)
    }

    @Test func blocksWhenAppTooOld() {
        #expect(PluginGate.evaluate(info: info(minApp: "0.5.0"), appVersion: "0.4.1")
                == .requiresAppVersion("0.5.0"))
    }

    @Test func devBuildWithoutVersionIsAlwaysCompatible() {
        #expect(PluginGate.evaluate(info: info(minApp: "9.9.9"), appVersion: nil) == nil)
    }

    /// The host-missing-version leniency applies ONLY to a well-formed pack: a
    /// malformed `NGVMinAppVersion` is incompatible even on a dev host — it must
    /// never be silently treated as compatible.
    @Test func malformedMinAppVersionIsIncompatibleEvenOnDevHost() {
        for bad in ["1.2", "1.2.3garbage", "1.2.3-rc1", ""] {
            if case .malformedMetadata = PluginGate.versionCheck(minAppVersion: bad, appVersion: nil) {} else {
                Issue.record("malformed minAppVersion \"\(bad)\" must block on a dev host")
            }
            if case .malformedMetadata = PluginGate.versionCheck(minAppVersion: bad, appVersion: "0.4.1") {} else {
                Issue.record("malformed minAppVersion \"\(bad)\" must block on a versioned host")
            }
        }
    }

    @Test func malformedMetadataBlocks() {
        if case .malformedMetadata = PluginGate.evaluate(info: info(id: "Bad Id"), appVersion: "1.0.0") {} else {
            Issue.record("invalid id should be malformed")
        }
        if case .malformedMetadata = PluginGate.evaluate(info: info(version: "notaversion"), appVersion: "1.0.0") {} else {
            Issue.record("invalid version should be malformed")
        }
        if case .malformedMetadata = PluginGate.evaluate(info: info(minApp: "bogus"), appVersion: "1.0.0") {} else {
            Issue.record("invalid minAppVersion should be malformed")
        }
        if case .malformedMetadata = PluginGate.evaluate(info: info(principal: ""), appVersion: "1.0.0") {} else {
            Issue.record("empty principal class should be malformed")
        }
    }

    @Test func reasonStringsAreUserFacing() {
        #expect(PluginIncompatibility.requiresAppVersion("0.5.0").reason == "Requires NexGenVideo 0.5.0 or newer.")
        #expect(PluginIncompatibility.malformedMetadata("x").reason.hasPrefix("Damaged pack"))
        #expect(PluginIncompatibility.untrustedSignature("y").reason.hasPrefix("Signature check failed"))
    }

    // MARK: - PluginBundleInfo reads a real Info.plist on disk

    @Test func readsInfoPlistFromBundle() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-\(UUID().uuidString).ngvpack/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        let plist: [String: Any] = [
            PluginBundleInfo.Key.id: "musicvideo",
            PluginBundleInfo.Key.version: "0.0.1",
            PluginBundleInfo.Key.minAppVersion: "0.1.0",
            PluginBundleInfo.Key.principalClass: "MusicvideoPackEntry",
            PluginBundleInfo.Key.displayName: "Music Video Studio",
            PluginBundleInfo.Key.tagline: "structured music video",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: tmp.appendingPathComponent("Info.plist"))

        let bundleURL = tmp.deletingLastPathComponent()
        let read = try #require(PluginBundleInfo(bundleURL: bundleURL))
        #expect(read.id == "musicvideo")
        #expect(read.version == "0.0.1")
        #expect(read.minAppVersion == "0.1.0")
        #expect(read.principalClass == "MusicvideoPackEntry")
        #expect(read.displayName == "Music Video Studio")
        #expect(PluginGate.evaluate(info: read, appVersion: "0.4.1") == nil)
    }

    @Test func missingPlistYieldsNil() {
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).ngvpack")
        #expect(PluginBundleInfo(bundleURL: bogus) == nil)
    }

    // MARK: - Install paths

    @Test func idValidation() {
        #expect(PluginPaths.isValidID("musicvideo"))
        #expect(PluginPaths.isValidID("short_movie-2"))
        #expect(!PluginPaths.isValidID(""))
        #expect(!PluginPaths.isValidID("../evil"))
        #expect(!PluginPaths.isValidID("Music Video"))
        #expect(!PluginPaths.isValidID("dots.here"))
    }

    @Test func installURLStaysInsideDirectory() {
        let url = PluginPaths.installURL(id: "musicvideo")
        #expect(url.lastPathComponent == "musicvideo.ngvpack")
        #expect(url.deletingLastPathComponent().standardizedFileURL == PluginPaths.installDirectory.standardizedFileURL)
    }
}
