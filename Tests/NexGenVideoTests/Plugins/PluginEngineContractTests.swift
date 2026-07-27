import Foundation
import NexGenEngine
import Testing

@testable import NexGenVideo

/// The host↔pack binary contract gate. A pack built against a different engine contract has no
/// witness-table entry for requirements added since — calling through it jumps to a null address.
/// It must be refused from the Info.plist alone, before `Bundle.load()` maps any of its code in.
@Suite("Loadable-pack engine contract")
struct PluginEngineContractTests {

    /// A well-formed pack plist; `contract` omitted entirely when nil (the in-the-wild case).
    private func info(contract: Int?, minApp: String = "0.1.0") -> PluginBundleInfo {
        var plist: [String: Any] = [
            PluginBundleInfo.Key.id: "musicvideo",
            PluginBundleInfo.Key.version: "0.0.4",
            PluginBundleInfo.Key.minAppVersion: minApp,
            PluginBundleInfo.Key.principalClass: "MusicvideoPackEntry",
            PluginBundleInfo.Key.displayName: "Music Video",
            PluginBundleInfo.Key.tagline: "tag",
        ]
        if let contract { plist[PluginBundleInfo.Key.engineContract] = contract }
        return PluginBundleInfo(plist: plist)
    }

    @Test func matchingContractPasses() {
        #expect(info(contract: EngineContract.current).engineContract == EngineContract.current)
        #expect(PluginGate.evaluate(info: info(contract: EngineContract.current), appVersion: "0.4.1") == nil)
    }

    @Test func differingContractIsIncompatible() {
        for offset in [-1, 1, 7] {
            let packContract = EngineContract.current + offset
            let blocked = PluginGate.evaluate(info: info(contract: packContract), appVersion: "0.4.1")
            #expect(blocked == .requiresEngineContract(pack: packContract, app: EngineContract.current))
        }
    }

    /// Every pack shipped before the check exists carries no `NGVEngineContract` — it reads as 0 and
    /// is refused. This is the exact binary that crashed the app on open.
    @Test func absentContractReadsAsPreContractAndIsRefused() {
        #expect(info(contract: nil).engineContract == 0)
        #expect(PluginGate.evaluate(info: info(contract: nil), appVersion: "0.4.1")
                == .requiresEngineContract(pack: 0, app: EngineContract.current))
    }

    /// A non-integer stamp is not "close enough" — it reads as pre-contract, never as a match.
    @Test func unparseableContractReadsAsPreContract() {
        let plist: [String: Any] = [PluginBundleInfo.Key.engineContract: "2"]
        #expect(PluginBundleInfo(plist: plist).engineContract == 0)
    }

    @Test func contractCheckIsPure() {
        #expect(PluginGate.contractCheck(packContract: 3, engine: 3) == nil)
        #expect(PluginGate.contractCheck(packContract: 1, engine: 3)
                == .requiresEngineContract(pack: 1, app: 3))
    }

    /// A too-old app reports the version it needs, not the contract mismatch that follows from it.
    @Test func versionReasonWinsOverContract() {
        #expect(PluginGate.evaluate(info: info(contract: 0, minApp: "9.9.9"), appVersion: "0.4.1")
                == .requiresAppVersion("9.9.9"))
    }

    @Test func reasonIsUserFacingAndActionable() {
        let reason = PluginIncompatibility.requiresEngineContract(pack: 0, app: 2).reason
        #expect(!reason.isEmpty)
        #expect(reason.localizedCaseInsensitiveContains("update"))
        #expect(reason.hasSuffix("."))
    }

    // MARK: - Info.plist round-trip

    /// A plist integer written the way `assemble_ngvpack.sh` writes it must read back as that Int.
    @Test func readsContractFromRealPlist() throws {
        let contents = FileManager.default.temporaryDirectory
            .appendingPathComponent("contract-\(UUID().uuidString).ngvpack/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }
        let plist: [String: Any] = [
            PluginBundleInfo.Key.id: "musicvideo",
            PluginBundleInfo.Key.version: "0.0.4",
            PluginBundleInfo.Key.minAppVersion: "0.1.0",
            PluginBundleInfo.Key.principalClass: "MusicvideoPackEntry",
            PluginBundleInfo.Key.engineContract: EngineContract.current,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let read = try #require(PluginBundleInfo(bundleURL: contents.deletingLastPathComponent()))
        #expect(read.engineContract == EngineContract.current)
        #expect(PluginGate.evaluate(info: read, appVersion: "0.4.1") == nil)
    }
}

/// Opening a project whose pack isn't live must be refused, not degraded to the generic workflow.
@MainActor
@Suite("Project format-pack open gate")
struct ProjectPackGateTests {

    private func record(id: String = "musicvideo", state: InstalledPluginRecord.State) -> InstalledPluginRecord {
        InstalledPluginRecord(
            id: id, displayName: id, tagline: "", headline: "", benefit: "",
            version: "0.0.4", minAppVersion: "0.1.0",
            bundleURL: URL(fileURLWithPath: "/tmp/\(id).ngvpack"), state: state)
    }

    @Test func genericProjectNeedsNothing() {
        #expect(ProjectPackGate.requirement(packID: nil, isRegistered: false, record: nil) == .satisfied)
        #expect(ProjectPackGate.requirement(packID: "", isRegistered: false, record: nil) == .satisfied)
    }

    @Test func unreadableProjectSettingsFailClosed() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pack-gate-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: project) }
        try Data("{not-json".utf8).write(
            to: project.appendingPathComponent("ngv.json")
        )

        #expect(ProjectPackGate.evaluate(projectURL: project) == .unreadable)

        let wrongType = try JSONSerialization.data(
            withJSONObject: ["activePlugin": 42]
        )
        try wrongType.write(
            to: project.appendingPathComponent("ngv.json"),
            options: .atomic
        )
        #expect(ProjectPackGate.evaluate(projectURL: project) == .unreadable)
    }

    @Test func registeredPackOpens() {
        #expect(ProjectPackGate.requirement(packID: "musicvideo", isRegistered: true, record: record(state: .loaded))
                == .satisfied)
    }

    @Test func trustedSessionDeclarationRejectsMissingOrMismatchedSettings() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pack-declaration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: project) }

        #expect(
            ProjectPackGate.evaluate(
                projectURL: project,
                declaredPack: "musicvideo"
            ) == .settingsMissing(expected: "musicvideo")
        )

        let settings = try JSONSerialization.data(
            withJSONObject: ["activePlugin": "other"]
        )
        try settings.write(
            to: project.appendingPathComponent("ngv.json")
        )
        #expect(
            ProjectPackGate.evaluate(
                projectURL: project,
                declaredPack: "musicvideo"
            ) == .inconsistent(
                expected: "musicvideo",
                resolved: "other"
            )
        )
    }

    @Test func notInstalledIsMissing() {
        #expect(ProjectPackGate.requirement(packID: "musicvideo", isRegistered: false, record: nil)
                == .missing(id: "musicvideo"))
    }

    /// The incident shape: the pack is installed but the contract gate refused it, so nothing is
    /// registered. The reason travels to the dialog instead of the project opening generic.
    @Test func gateBlockedPackReportsItsReason() {
        let blocked = PluginIncompatibility.requiresEngineContract(pack: 0, app: EngineContract.current)
        #expect(ProjectPackGate.requirement(
            packID: "musicvideo", isRegistered: false, record: record(state: .incompatible(blocked)))
                == .incompatible(id: "musicvideo", reason: blocked.reason))
    }

    @Test func stagedUpdateAsksForARestart() {
        #expect(ProjectPackGate.requirement(
            packID: "musicvideo", isRegistered: false, record: record(state: .updatePendingRestart))
                == .needsRestart(id: "musicvideo"))
    }

    /// Installed and gate-clean but absent from the registry (it never registered) — treat it as
    /// missing and offer the pack rather than opening a pack project without its pack.
    @Test func installedButUnregisteredIsMissing() {
        #expect(ProjectPackGate.requirement(packID: "musicvideo", isRegistered: false, record: record(state: .loaded))
                == .missing(id: "musicvideo"))
    }
}

/// The save backstop. `AppState` gates the Home window and the Open panel, but a Finder double-click
/// reaches the document directly — and that is the likely route for a project received from someone
/// else. Refusing the SAVE is what actually prevents the damage, whatever the route in.
@Suite("save is refused without the project's pack")
struct PackUnavailableErrorTests {

    @Test("the message names the pack and says nothing was written")
    func messageIsActionable() {
        let error = PackUnavailableError(packID: "musicvideo", detail: nil)
        let text = (error.errorDescription ?? "") + " " + (error.recoverySuggestion ?? "")
        #expect(text.contains("musicvideo"))
        #expect(text.contains("Settings"))
        // The user must know the package on disk is intact — otherwise the honest move looks risky.
        #expect(text.lowercased().contains("untouched"))
    }

    @Test("an installed-but-refused pack repeats the load gate's own reason")
    func incompatibleCarriesReason() {
        let reason = PluginIncompatibility.requiresEngineContract(pack: 1, app: 2).reason
        let error = PackUnavailableError(packID: "musicvideo", detail: reason)
        #expect(error.recoverySuggestion?.contains(reason) == true)
        // …and still tells them the saved version survived.
        #expect(error.recoverySuggestion?.lowercased().contains("untouched") == true)
    }

    @Test("unreadable format settings refuse save without touching the package")
    func unreadableSettingsAreActionable() {
        let error = ProjectFormatSettingsUnavailableError()
        let text = (error.errorDescription ?? "")
            + " "
            + (error.recoverySuggestion ?? "")
        #expect(text.contains("ngv.json"))
        #expect(text.lowercased().contains("untouched"))
    }

    @Test("an off-main save asks for a retry instead of claiming ngv.json is damaged")
    func offMainSaveMessageIsAccurate() {
        let error = ProjectSaveContextError()
        let text = (error.errorDescription ?? "")
            + " "
            + (error.recoverySuggestion ?? "")
        #expect(text.contains("Save again"))
        #expect(!text.contains("ngv.json"))
        #expect(text.lowercased().contains("untouched"))
    }
}
