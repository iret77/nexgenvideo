import Foundation
import Testing

@testable import NexGenVideo

@Suite("Format-pack uninstall")
struct PluginUninstallTests {
    @MainActor
    @Test("removing one version preserves side-by-side installs")
    func removesOnlySelectedVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = versionedBundle(root: root, version: "1.2.0")
        let second = versionedBundle(root: root, version: "1.3.0")
        let legacy = root.appendingPathComponent("musicvideo.ngvpack", isDirectory: true)
        try prepareBundle(first, version: "1.2.0")
        try prepareBundle(second, version: "1.3.0")
        try prepareBundle(legacy, version: "1.2.0")

        try PluginInstaller.uninstall(
            id: "musicvideo",
            version: "1.2.0",
            bundleURL: first,
            installDirectory: root
        )

        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(
            atPath: second.deletingLastPathComponent().path
        ))
    }

    @MainActor
    @Test("removing the last version cleans up its empty directory")
    func removesEmptyVersionDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = versionedBundle(root: root, version: "1.3.0")
        try prepareBundle(bundle, version: "1.3.0")

        try PluginInstaller.uninstall(
            id: "musicvideo",
            version: "1.3.0",
            bundleURL: bundle,
            installDirectory: root
        )

        #expect(!FileManager.default.fileExists(
            atPath: bundle.deletingLastPathComponent().path
        ))
    }

    @MainActor
    @Test("legacy flat installs remain removable by their declared version")
    func removesMatchingLegacyInstall() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("musicvideo.ngvpack", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            PluginBundleInfo.Key.id: "musicvideo",
            PluginBundleInfo.Key.version: "1.1.0",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        try PluginInstaller.uninstall(
            id: "musicvideo",
            version: "1.1.0",
            bundleURL: bundle,
            installDirectory: root
        )

        #expect(!FileManager.default.fileExists(atPath: bundle.path))
    }

    @MainActor
    @Test("removal refuses a bundle whose path and metadata do not match")
    func refusesMismatchedTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("misplaced.ngvpack", isDirectory: true)
        let canonical = versionedBundle(root: root, version: "1.2.0")
        try prepareBundle(selected, version: "1.2.0")
        try prepareBundle(canonical, version: "1.2.0")

        #expect(throws: PluginInstaller.InstallError.self) {
            try PluginInstaller.uninstall(
                id: "musicvideo",
                version: "1.2.0",
                bundleURL: selected,
                installDirectory: root
            )
        }
        #expect(FileManager.default.fileExists(atPath: selected.path))
        #expect(FileManager.default.fileExists(atPath: canonical.path))
    }

    @Test("snapshot matches exact versions and legacy bindings")
    func snapshotMatchesPinnedProjects() throws {
        let first = installedVersion("1.2.0")
        let second = installedVersion("1.3.0")
        let exact = projectUsage(name: "Exact", legacy: false)
        let other = projectUsage(name: "Other", legacy: false)
        let legacy = projectUsage(name: "Legacy", legacy: true)
        let firstBinding = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: first.version,
            projectSchema: "musicvideo/1.0.0"
        ))
        let secondBinding = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: second.version,
            projectSchema: "musicvideo/1.0.0"
        ))

        let snapshot = PluginRemovalPolicy.snapshot(
            installedVersions: [first, second],
            evidence: [
                .exact(firstBinding, knownProject: exact),
                .exact(firstBinding, isOpen: true),
                .exact(secondBinding, knownProject: other),
                .legacy(packID: "musicvideo", knownProject: legacy),
            ]
        )

        let firstState = try #require(snapshot.state(for: first))
        let secondState = try #require(snapshot.state(for: second))
        #expect(firstState.knownProjectUsages.map(\.name) == ["Exact", "Legacy"])
        #expect(secondState.knownProjectUsages.map(\.name) == ["Legacy", "Other"])
        #expect(firstState.isRequiredByOpenProject)
        #expect(!secondState.isRequiredByOpenProject)
        #expect(firstState.knownProjectUsages.first { $0.name == "Exact" }?.isLegacyBinding == false)
        #expect(firstState.knownProjectUsages.first { $0.name == "Legacy" }?.isLegacyBinding == true)
    }

    @Test("unknown and open-project states disable removal")
    func disabledRemovalStates() {
        let installed = installedVersion("1.2.0")
        let checking = PluginRemovalPresentation.resolve(
            installedVersion: installed,
            usage: nil
        )
        let open = PluginRemovalPresentation.resolve(
            installedVersion: installed,
            usage: PluginVersionUsageState(
                knownProjectUsages: [],
                isRequiredByOpenProject: true
            )
        )

        #expect(!checking.canRemove)
        #expect(checking.subtitle == "Checking project use…")
        #expect(!open.canRemove)
        #expect(open.subtitle == "Required by an open project.")
    }

    @Test("unreadable project bindings keep removal fail-closed")
    func unreadableBindingDisablesRemoval() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: root.appendingPathComponent(ProjectPluginSettings.filename)
        )
        let installed = installedVersion("1.2.0")
        let entry = ProjectEntry(
            id: UUID(),
            url: root,
            createdDate: .now,
            lastOpenedDate: .now
        )

        let snapshot = await PluginRemovalPolicy.loadSnapshot(
            installedVersions: [installed],
            registryEntries: [entry],
            openProjectRoots: []
        )
        let state = try #require(snapshot.state(for: installed))
        let presentation = PluginRemovalPresentation.resolve(
            installedVersion: installed,
            usage: state
        )

        #expect(!state.isUsageVerified)
        #expect(!presentation.canRemove)
        #expect(presentation.subtitle == "Project use could not be verified.")
    }

    @Test("missing registered projects keep removal fail-closed")
    func missingRegistryProjectDisablesRemoval() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installed = installedVersion("1.2.0")
        let entry = ProjectEntry(
            id: UUID(),
            url: missing,
            createdDate: .now,
            lastOpenedDate: .now
        )

        let snapshot = await PluginRemovalPolicy.loadSnapshot(
            installedVersions: [installed],
            registryEntries: [entry],
            openProjectRoots: []
        )
        let state = try #require(snapshot.state(for: installed))
        let presentation = PluginRemovalPresentation.resolve(
            installedVersion: installed,
            usage: state
        )

        #expect(!state.isUsageVerified)
        #expect(!presentation.canRemove)
    }

    @Test("existing generic projects keep removal verified")
    func existingGenericProjectAllowsRemoval() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let installed = installedVersion("1.2.0")
        let entry = ProjectEntry(
            id: UUID(),
            url: root,
            createdDate: .now,
            lastOpenedDate: .now
        )

        let snapshot = await PluginRemovalPolicy.loadSnapshot(
            installedVersions: [installed],
            registryEntries: [entry],
            openProjectRoots: []
        )
        let state = try #require(snapshot.state(for: installed))
        let presentation = PluginRemovalPresentation.resolve(
            installedVersion: installed,
            usage: state
        )

        #expect(state.isUsageVerified)
        #expect(presentation.canRemove)
    }

    @Test("known closed projects produce a warning without blocking removal")
    func closedProjectWarning() {
        let installed = installedVersion("1.2.0")
        let usage = projectUsage(name: "Claude Mouse", legacy: false)
        let presentation = PluginRemovalPresentation.resolve(
            installedVersion: installed,
            usage: PluginVersionUsageState(
                knownProjectUsages: [usage],
                isRequiredByOpenProject: false
            )
        )

        #expect(presentation.canRemove)
        #expect(presentation.subtitle == "Required by Claude Mouse.")
        #expect(presentation.removalMessage.contains("Claude Mouse"))
        #expect(presentation.removalMessage.contains("won't open"))
    }

    private func versionedBundle(root: URL, version: String) -> URL {
        root.appendingPathComponent("musicvideo", isDirectory: true)
            .appendingPathComponent(version)
            .appendingPathExtension(PluginPaths.bundleExtension)
    }

    private func installedVersion(_ version: String) -> InstalledPluginVersion {
        InstalledPluginVersion(
            packID: "musicvideo",
            version: version,
            displayName: "Music Video",
            projectSchema: "musicvideo/1.0.0",
            bundleURL: URL(fileURLWithPath: "/packs/musicvideo/\(version).ngvpack"),
            isLegacy: false,
            isPresentOnDisk: true,
            isResident: false
        )
    }

    private func projectUsage(name: String, legacy: Bool) -> ProjectPackUsage {
        ProjectPackUsage(
            projectID: UUID(),
            name: name,
            url: URL(fileURLWithPath: "/projects/\(name).ngv"),
            isLegacyBinding: legacy
        )
    }

    private func prepareBundle(_ bundle: URL, version: String) throws {
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                PluginBundleInfo.Key.id: "musicvideo",
                PluginBundleInfo.Key.version: version,
            ],
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
