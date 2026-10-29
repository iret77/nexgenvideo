import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo

@Suite("Production workflow Recovery migration")
@MainActor
struct ProductionWorkflowRecoveryMigrationTests {
    @Test func archiveResetsPlanningWithoutMovingTimelineOrPaidMedia() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let intent = try ProductionWorkflowRecoveryMigration.preview(projectURL: root, source: .core, target: .core)
        try ProductionWorkflowRecoveryMigration.archiveAndReset(intent, staging: root)
        #expect(try Data(contentsOf: root.appendingPathComponent(Project.timelineFilename)) == Data("edited timeline".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent("pipeline/frames/legacy.png")) == Data("paid image bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pipeline/brief.yaml").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pipeline/treatment/v4.md").path))
        let history = root.appendingPathComponent("pipeline/migration-history/\(intent.fingerprint)")
        #expect(try Data(contentsOf: history.appendingPathComponent("pipeline/treatment/v4.md")) == Data("approved treatment".utf8))
        let gates = try YAMLArtifactStore(dataRoot: root.appendingPathComponent("pipeline")).load(Gates.self, at: PipelineLayout.gatesFile)
        #expect(Set(gates.gates.keys) == Set(ProductionWorkflowV2.corePhases))
        #expect(gates.gates.values.allSatisfy { !$0.approved && $0.notes == nil })
    }

    @Test func sourceChangeAfterPreviewRejectsBeforeAnyArchiveMove() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let intent = try ProductionWorkflowRecoveryMigration.preview(projectURL: root, source: .core, target: .core)
        try Data("changed timeline".utf8).write(to: root.appendingPathComponent(Project.timelineFilename))
        #expect(throws: ProductionWorkflowRecoveryMigration.MigrationError.self) {
            try ProductionWorkflowRecoveryMigration.archiveAndReset(intent, staging: root)
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("pipeline/brief.yaml").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pipeline/migration-history").path))
    }

    @Test func outputNamespaceProtectsLegacyMediaAndRejectsOverwrite() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let intent = try ProductionWorkflowRecoveryMigration.preview(projectURL: root, source: .core, target: .core)
        try ProductionWorkflowRecoveryMigration.archiveAndReset(intent, staging: root)
        let dataRoot = root.appendingPathComponent("pipeline")
        try ProjectPluginSettings.setProductionContract(.current, projectURL: root)
        try ProductionWorkflowRecoveryMigration.finish(intent, staging: root)
        let output = try ProductionWorkflowRecoveryMigration.outputPath(area: "production_design/lighting", leaf: "new.png", dataRoot: dataRoot)
        #expect(output == "production_design/lighting/\(intent.namespaceID)/new.png")
        #expect(throws: ProductionWorkflowRecoveryMigration.MigrationError.self) {
            try ProductionWorkflowRecoveryMigration.requireNewOutput("frames/legacy.png", dataRoot: dataRoot)
        }
        let destination = dataRoot.appendingPathComponent(output)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first result".utf8).write(to: destination)
        #expect(throws: ProductionWorkflowRecoveryMigration.MigrationError.self) {
            try ProductionWorkflowRecoveryMigration.requireNewOutput(output, dataRoot: dataRoot)
        }
        #expect(throws: ProductionWorkflowRecoveryMigration.MigrationError.self) {
            try ProductionWorkflowRecoveryMigration.outputPath(area: "renders", leaf: "../../legacy.png", dataRoot: dataRoot)
        }
    }

    @Test func stagedArchiveIsNotAnAuthorizingCompletedMigration() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let intent = try ProductionWorkflowRecoveryMigration.preview(projectURL: root, source: .core, target: .core)
        try ProductionWorkflowRecoveryMigration.archiveAndReset(intent, staging: root)
        #expect(throws: ProductionWorkflowRecoveryMigration.MigrationError.self) {
            try ProductionWorkflowRecoveryMigration.requireCommittedHistory(intent, staging: root)
        }
    }

    @Test func freshExplicitCoreEnrollmentCanCreateItsNamespace() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectPluginSettings.setProductionContract(.current, projectURL: root)
        let dataRoot = root.appendingPathComponent("pipeline")
        try ProductionWorkflowRecoveryMigration.initializeOutputNamespace(dataRoot: dataRoot, workflow: .core(.current))
        let path = try ProductionWorkflowRecoveryMigration.outputPath(area: "storyboard/sketches", leaf: "moment.png", dataRoot: dataRoot)
        #expect(path.hasPrefix("storyboard/sketches/"))
        #expect(path.hasSuffix("/moment.png"))
        #expect(!path.contains("legacy"))
    }

    @Test func dirtyRecoveryPreviewAndCoreTransactionPreserveUnsavedTimeline() throws {
        let root = try fixture()
        let savedTimeline = try JSONEncoder().encode(Timeline())
        try savedTimeline.write(to: root.appendingPathComponent(Project.timelineFilename))
        let key = try ProjectIdentity.key(for: root)
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: root) }
        let opened = try ProjectWorkingCopy.open(key: key, packageURL: root)
        let edited = try JSONEncoder().encode(Timeline(fps: 30))
        try edited.write(to: opened.home.appendingPathComponent(Project.timelineFilename))
        try ProjectWorkingCopy.markDirty(key: key)
        let source = try #require(ProjectWorkingCopy.recoverableDirtyHome(for: root))
        #expect(source == opened.home)
        let intent = try ProductionWorkflowRecoveryMigration.preview(projectURL: root, sourceRoot: source, source: .core, target: .core)
        #expect(intent.files != intent.savedFiles)
        try ProjectPackMigration.migrateCoreWorkingCopy(projectURL: root, workingCopyKey: key, intent: intent)
        #expect(try Data(contentsOf: ProjectWorkingCopy.home(key).appendingPathComponent(Project.timelineFilename)) == edited)
        #expect(try Data(contentsOf: root.appendingPathComponent(Project.timelineFilename)) == savedTimeline)
        #expect(ProductionWorkflowRecoveryMigration.authorizesCoreRecovery(projectURL: root, recoveryURL: ProjectWorkingCopy.home(key)))
        let recovered = try ProjectWorkingCopy.open(key: key, packageURL: root)
        #expect(recovered.recoveredUnsaved)
        #expect(ProjectPluginSettings.productionContractResolution(projectURL: recovered.home) == .bound(.current))
        try JSONEncoder().encode(Timeline(fps: 60)).write(to: recovered.home.appendingPathComponent(Project.timelineFilename))
        #expect(ProductionWorkflowRecoveryMigration.authorizesCoreRecovery(projectURL: root, recoveryURL: recovered.home))
    }

    @Test func sourcePreviewReaderRejectsUnauthorizedDirtyCoreDeclaration() throws {
        let root = try fixture()
        try JSONEncoder().encode(Timeline()).write(to: root.appendingPathComponent(Project.timelineFilename))
        let key = try ProjectIdentity.key(for: root)
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: root) }
        let opened = try ProjectWorkingCopy.open(key: key, packageURL: root)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: opened.home)
        try ProjectWorkingCopy.markDirty(key: key)
        #expect(throws: ProjectWorkingCopy.PersistError.self) { try ProjectWorkingCopy.recoverableDirtyHome(for: root) }
        #expect(!ProductionWorkflowRecoveryMigration.authorizesCoreRecovery(projectURL: root, recoveryURL: opened.home))
    }

    @Test func namespaceChangeCannotReuseAnExistingPreviewFingerprint() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let intent = try ProductionWorkflowRecoveryMigration.preview(projectURL: root, source: .core, target: .core)
        let altered = ProductionWorkflowRecoveryMigration.Intent(projectName: intent.projectName, source: intent.source,
            target: intent.target, files: intent.files, savedFiles: intent.savedFiles, archivePaths: intent.archivePaths,
            startupProofs: intent.startupProofs, namespaceID: UUID().uuidString.lowercased(), fingerprint: intent.fingerprint)
        #expect(throws: ProductionWorkflowRecoveryMigration.MigrationError.self) {
            try ProductionWorkflowRecoveryMigration.archiveAndReset(altered, staging: root)
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("pipeline/brief.yaml").path))
    }

    @Test func legacyRescheduleClearsAnUnrelatedProductionResetIntent() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectPluginSettings.setActivePlugin("musicvideo", projectURL: root)
        let key = try ProjectIdentity.key(for: root)
        let resetKey = "NGVProductionReset." + key
        let legacyKey = "NGVLegacyPackMigration." + key
        defer { UserDefaults.standard.removeObject(forKey: resetKey); UserDefaults.standard.removeObject(forKey: legacyKey) }
        UserDefaults.standard.set(Data("stale reset intent".utf8), forKey: resetKey)
        let target = try #require(ProjectPackBinding(id: "musicvideo", version: "0.5.16", projectSchema: "musicvideo/2.0.0"))
        try ProjectPackMigration.scheduleLegacy(projectURL: root, target: target)
        #expect(UserDefaults.standard.data(forKey: resetKey) == nil)
        #expect(UserDefaults.standard.data(forKey: legacyKey) != nil)
    }

    @Test func cancellingFileVerificationProducesNoArchive() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let control = ProductionMigrationPreflight.Control()
        control.cancel()
        #expect(throws: CancellationError.self) { try control.digest(root.appendingPathComponent(Project.timelineFilename)) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pipeline/migration-history").path))
    }

    @Test func historicalArchiveReaderDoesNotRequireTheLatestOutputNamespace() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let intent = try ProductionWorkflowRecoveryMigration.preview(projectURL: root, source: .core, target: .core)
        try ProductionWorkflowRecoveryMigration.archiveAndReset(intent, staging: root)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: root)
        try ProductionWorkflowRecoveryMigration.finish(intent, staging: root)
        let dataRoot = root.appendingPathComponent("pipeline")
        let later = ProductionWorkflowRecoveryMigration.OutputNamespace(schema: "production-output-namespace/v1",
            id: UUID().uuidString.lowercased(), sourceFingerprint: "", protectedPaths: [])
        try JSONArtifactStore(dataRoot: dataRoot).save(later, to: ProductionWorkflowRecoveryMigration.OutputNamespace.relativePath)
        #expect(try ProductionWorkflowRecoveryMigration.readCommittedHistories(staging: root).map(\.intent.fingerprint) == [intent.fingerprint])
        try Data("changed history".utf8).write(to: dataRoot.appendingPathComponent(
            "migration-history/" + intent.fingerprint + "/pipeline/treatment/v4.md"))
        #expect(throws: (any Error).self) { try ProductionWorkflowRecoveryMigration.readCommittedHistories(staging: root) }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString + ".ngv")
        let dataRoot = try ProjectScaffold.initProject(home: root, name: "Fixture", mode: .generic)
        try Data("edited timeline".utf8).write(to: root.appendingPathComponent(Project.timelineFilename))
        try Data("approved brief".utf8).write(to: dataRoot.appendingPathComponent(PipelineLayout.briefFile))
        try Data("approved treatment".utf8).write(to: dataRoot.appendingPathComponent("treatment/v4.md"))
        try Data("paid image bytes".utf8).write(to: dataRoot.appendingPathComponent("frames/legacy.png"))
        var gates = Gates(project: "Fixture")
        GatesOperations.approve(&gates, phase: "brief")
        GatesOperations.approve(&gates, phase: "render")
        try YAMLArtifactStore(dataRoot: dataRoot).save(gates, to: PipelineLayout.gatesFile)
        _ = try ProjectIdentity.key(for: root)
        return root
    }
}
