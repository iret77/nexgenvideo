import Testing

@testable import NexGenVideo

@Suite("Format-pack lifecycle")
struct PluginLifecycleTests {
    private func binding(
        id: String = "musicvideo",
        version: String,
        schema: String
    ) -> ProjectPackBinding {
        ProjectPackBinding(
            id: id,
            version: version,
            projectSchema: schema
        )!
    }

    @Test("new project cannot use stale resident code")
    func staleResidentVersionRequiresRestart() {
        let old = binding(version: "0.0.5", schema: "musicvideo/legacy")
        let current = binding(version: "0.0.6", schema: "musicvideo/1.0.0")

        #expect(
            PluginUpdateCenter.activationRequirement(
                live: old,
                target: current
            ) == .restart
        )
    }

    @Test("fresh process may load the selected current version")
    func noResidentVersionMayLoad() {
        let current = binding(version: "0.0.6", schema: "musicvideo/1.0.0")
        #expect(
            PluginUpdateCenter.activationRequirement(
                live: nil,
                target: current
            ) == .load
        )
    }

    @Test("exact current binding is ready")
    func exactResidentVersionIsReady() {
        let current = binding(version: "0.0.6", schema: "musicvideo/1.0.0")
        #expect(
            PluginUpdateCenter.activationRequirement(
                live: current,
                target: current
            ) == .ready
        )
    }

    @Test("startup defaults to the newest installed compatible version")
    func startupDefaultsToNewestVersion() {
        #expect(
            PluginLoader.startupVersion(
                available: ["0.0.5", "0.0.6"],
                requested: nil
            ) == "0.0.6"
        )
    }

    @Test("an explicit project version wins only while it remains available")
    func startupHonorsValidPinAndFallsBackFromInvalidPin() {
        #expect(
            PluginLoader.startupVersion(
                available: ["0.0.5", "0.0.6"],
                requested: "0.0.5"
            ) == "0.0.5"
        )
        #expect(
            PluginLoader.startupVersion(
                available: ["0.0.5"],
                requested: "0.0.6"
            ) == "0.0.5"
        )
    }

    @Test("an update loaded in-process does not request a restart")
    func liveInstallClearsRestartAttention() {
        #expect(
            PluginUpdateCenter.attention(after: .loaded) == nil
        )
        #expect(
            PluginUpdateCenter.attention(
                after: .updatePendingRestart
            ) == .restartRequired
        )
    }

    @Test("global restart state does not offer an already-current project an upgrade")
    func projectAttentionRequiresDifferentTarget() {
        let current = binding(
            version: "0.0.6",
            schema: "musicvideo/1.0.0"
        )
        #expect(
            PluginUpdateCenter.projectAttention(
                global: .restartRequired,
                target: current,
                current: current
            ) == nil
        )
    }

    @Test("restart requires one complete installed target")
    func restartPlanRejectsMissingState() {
        let current = binding(
            version: "0.0.6",
            schema: "musicvideo/1.0.0"
        )
        #expect(throws: PluginUpdateCenter.RestartFailure.noInstalledUpdate) {
            try PluginUpdateCenter.validatedRestartTargets([]) { _ in true }
        }
        #expect(throws: PluginUpdateCenter.RestartFailure.targetMissing(current)) {
            try PluginUpdateCenter.validatedRestartTargets([current]) { _ in false }
        }
        let documentary = binding(
            id: "documentary",
            version: "0.1.0",
            schema: "documentary/1.0.0"
        )
        #expect(throws: PluginUpdateCenter.RestartFailure.targetMissing(current)) {
            try PluginUpdateCenter.validatedRestartTargets(
                [current, documentary]
            ) {
                $0 == documentary
            }
        }
    }

    @Test("restart accepts the exact installed target")
    func restartPlanUsesInstalledTarget() throws {
        let musicvideo = binding(
            version: "0.0.6",
            schema: "musicvideo/1.0.0"
        )
        let documentary = binding(
            id: "documentary",
            version: "0.1.0",
            schema: "documentary/1.0.0"
        )
        let installed = [musicvideo, documentary]
        let targets = try PluginUpdateCenter.validatedRestartTargets(
            [musicvideo, documentary]
        ) {
            installed.contains($0)
        }
        #expect(targets == [documentary, musicvideo])
    }
}
