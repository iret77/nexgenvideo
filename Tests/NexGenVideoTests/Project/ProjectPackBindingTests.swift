import Foundation
import MusicvideoPlugin
import NexGenEngine
import Testing

@testable import NexGenVideo

@MainActor
@Suite("Project pack binding")
struct ProjectPackBindingTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pack-binding-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    @Test func exactBindingRoundTrips() throws {
        let project = try directory()
        defer { try? FileManager.default.removeItem(at: project) }
        let binding = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "0.0.6",
            projectSchema: "musicvideo/1.0.0"
        ))

        try ProjectPluginSettings.setActivePlugin(
            binding,
            projectURL: project
        )

        #expect(
            ProjectPluginSettings.bindingResolution(projectURL: project)
                == .bound(binding)
        )
    }

    @Test func mutationGuardRejectsSameIDSiblingBindings() throws {
        PackCatalog.register(MusicvideoPack())
        let project = try directory()
        defer { try? FileManager.default.removeItem(at: project) }
        let trusted = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: MusicvideoPack().version,
            projectSchema: "musicvideo/2.0.0"
        ))
        try ProjectPluginSettings.setActivePlugin(trusted, projectURL: project)

        #expect(try ProjectPackGate.requireMutation(
            projectURL: project,
            declaredPack: trusted.id,
            declaredBinding: trusted
        ) == trusted.id)

        let siblingVersion = try #require(ProjectPackBinding(
            id: trusted.id,
            version: "0.4.5",
            projectSchema: trusted.projectSchema
        ))
        try ProjectPluginSettings.setActivePlugin(
            siblingVersion,
            projectURL: project
        )
        #expect(throws: GateBlocked.self) {
            _ = try ProjectPackGate.requireMutation(
                projectURL: project,
                declaredPack: trusted.id,
                declaredBinding: trusted
            )
        }

        let siblingSchema = try #require(ProjectPackBinding(
            id: trusted.id,
            version: trusted.version,
            projectSchema: "musicvideo/2.0.1"
        ))
        try ProjectPluginSettings.setActivePlugin(
            siblingSchema,
            projectURL: project
        )
        #expect(throws: GateBlocked.self) {
            _ = try ProjectPackGate.requireMutation(
                projectURL: project,
                declaredPack: trusted.id,
                declaredBinding: trusted
            )
        }
    }

    @Test func idOnlyProjectsRemainExplicitlyLegacy() throws {
        let project = try directory()
        defer { try? FileManager.default.removeItem(at: project) }
        try Data(#"{"activePlugin":"musicvideo"}"#.utf8).write(
            to: project.appendingPathComponent("ngv.json")
        )

        #expect(
            ProjectPluginSettings.bindingResolution(projectURL: project)
                == .legacy("musicvideo")
        )
    }

    @Test func partialBindingFailsClosed() throws {
        let project = try directory()
        defer { try? FileManager.default.removeItem(at: project) }
        try Data(
            #"{"activePlugin":"musicvideo","activePluginVersion":"0.0.6"}"#.utf8
        ).write(to: project.appendingPathComponent("ngv.json"))

        #expect(
            ProjectPluginSettings.bindingResolution(projectURL: project)
                == .unreadable
        )
    }

    @Test func explicitUpgradeIntentTemporarilySelectsOnlyItsTarget() throws {
        let project = try directory()
        defer {
            ProjectPackMigration.cancel(projectURL: project)
            try? FileManager.default.removeItem(at: project)
        }
        let source = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "0.0.5",
            projectSchema: "musicvideo/legacy"
        ))
        let target = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "0.0.6",
            projectSchema: "musicvideo/1.0.0"
        ))
        try ProjectPluginSettings.setActivePlugin(
            source,
            projectURL: project
        )
        _ = try ProjectIdentity.regenerate(at: project)
        let savedSettings = try Data(
            contentsOf: project.appendingPathComponent(
                ProjectPluginSettings.filename
            )
        )

        let prepared = try ProjectPackMigration.prepareSchedule(
            projectURL: project,
            source: source,
            target: target
        )

        #expect(ProjectPackMigration.request(for: project) == nil)
        #expect(
            ProjectPackMigration.effectiveBinding(
                persisted: source,
                projectURL: project
            ) == source
        )
        ProjectPackMigration.commit(prepared)
        #expect(ProjectPackMigration.request(for: project)?.source == source)
        #expect(
            ProjectPackMigration.restartResolution(
                required: target,
                projectURL: project
            ) == .pending(
                ProjectPackMigration.Request(
                    source: source,
                    target: target
                )
            )
        )
        let restartCopy = AppState.pendingUpgradeRestartCopy(
            ProjectPackMigration.Request(
                source: source,
                target: target
            ),
            projectURL: project
        )
        #expect(restartCopy.informative.contains("0.0.5 to 0.0.6"))
        #expect(restartCopy.informative.contains("return to 0.0.5"))
        #expect(restartCopy.informative.contains("saved project remains unchanged"))
        #expect(
            ProjectPackMigration.effectiveBinding(
                persisted: source,
                projectURL: project
            ) == target
        )
        #expect(try Data(
            contentsOf: project.appendingPathComponent(
                ProjectPluginSettings.filename
            )
        ) == savedSettings)
        ProjectPackMigration.cancel(projectURL: project)
        #expect(
            ProjectPackMigration.effectiveBinding(
                persisted: source,
                projectURL: project
            ) == source
        )
        #expect(try Data(
            contentsOf: project.appendingPathComponent(
                ProjectPluginSettings.filename
            )
        ) == savedSettings)
    }

    @Test func sameSchemaUpgradeChangesOnlyThePinnedVersion() throws {
        let source = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "0.0.6",
            projectSchema: "musicvideo/1.0.0"
        ))
        let target = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "0.0.7",
            projectSchema: "musicvideo/1.0.0"
        ))

        #expect(
            ProjectPackMigration.upgradeKind(
                source: source,
                target: target
            ) == .bindingOnly
        )
    }

    @Test func staleUpgradeRequestCannotRedirectRestartToItsTarget() throws {
        let project = try directory()
        defer {
            ProjectPackMigration.cancel(projectURL: project)
            try? FileManager.default.removeItem(at: project)
        }
        let persisted = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "1.2.0",
            projectSchema: "musicvideo/1.0.0"
        ))
        let staleSource = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "1.1.0",
            projectSchema: "musicvideo/1.0.0"
        ))
        let staleTarget = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "1.3.0",
            projectSchema: "musicvideo/1.0.0"
        ))
        try ProjectPluginSettings.setActivePlugin(
            persisted,
            projectURL: project
        )
        _ = try ProjectIdentity.regenerate(at: project)
        let savedSettings = try Data(
            contentsOf: project.appendingPathComponent(
                ProjectPluginSettings.filename
            )
        )
        ProjectPackMigration.commit(
            try ProjectPackMigration.prepareSchedule(
                projectURL: project,
                source: staleSource,
                target: staleTarget
            )
        )

        #expect(
            ProjectPackMigration.effectiveBinding(
                persisted: persisted,
                projectURL: project
            ) == persisted
        )
        #expect(
            ProjectPackMigration.restartResolution(
                required: persisted,
                projectURL: project
            ) == .versionConflict(persisted)
        )
        #expect(try Data(
            contentsOf: project.appendingPathComponent(
                ProjectPluginSettings.filename
            )
        ) == savedSettings)
    }

    @Test func legacyRestartRequiresThePersistedIDAndRequiredTarget() throws {
        let project = try directory()
        defer {
            ProjectPackMigration.cancel(projectURL: project)
            try? FileManager.default.removeItem(at: project)
        }
        try ProjectPluginSettings.setActivePlugin(
            "musicvideo",
            projectURL: project
        )
        _ = try ProjectIdentity.regenerate(at: project)
        let target = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "1.3.0",
            projectSchema: "musicvideo/1.0.0"
        ))
        let other = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "1.2.0",
            projectSchema: "musicvideo/1.0.0"
        ))
        try ProjectPackMigration.scheduleLegacy(
            projectURL: project,
            target: target
        )

        #expect(
            ProjectPackMigration.restartResolution(
                required: target,
                projectURL: project
            ) == .legacy(target)
        )
        #expect(
            ProjectPackMigration.restartResolution(
                required: other,
                projectURL: project
            ) == .versionConflict(other)
        )
    }

    @Test func changedSchemaRequiresPackOwnedMigration() throws {
        let source = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "0.0.6",
            projectSchema: "musicvideo/1.0.0"
        ))
        let target = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "0.1.0",
            projectSchema: "musicvideo/2.0.0"
        ))

        #expect(
            ProjectPackMigration.upgradeKind(
                source: source,
                target: target
            ) == .schemaMigration
        )
    }

    @Test func newerSameSchemaIsACompatibleVersionOnlyUpgrade() throws {
        let source = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "1.2.0",
            projectSchema: "musicvideo/1.0.0"
        ))
        let target = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "1.3.0",
            projectSchema: "musicvideo/1.0.0"
        ))

        #expect(ProjectPackMigration.compatibleUpgradeKind(
            source: source,
            target: target,
            targetMigratesFrom: [],
            hasRuntimeMigration: false
        ) == .bindingOnly)
    }

    @Test func schemaUpgradeRequiresDeclarationAndLiveMigration() throws {
        let source = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "1.2.0",
            projectSchema: "musicvideo/1.0.0"
        ))
        let target = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "1.3.0",
            projectSchema: "musicvideo/2.0.0"
        ))

        #expect(ProjectPackMigration.compatibleUpgradeKind(
            source: source,
            target: target,
            targetMigratesFrom: [source.projectSchema],
            hasRuntimeMigration: false
        ) == nil)
        #expect(ProjectPackMigration.compatibleUpgradeKind(
            source: source,
            target: target,
            targetMigratesFrom: [],
            hasRuntimeMigration: true
        ) == nil)
        #expect(ProjectPackMigration.compatibleUpgradeKind(
            source: source,
            target: target,
            targetMigratesFrom: [source.projectSchema],
            hasRuntimeMigration: true
        ) == .schemaMigration)
    }

    @Test func downgradeIsNeverPresentedAsAnUpgrade() throws {
        let source = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "1.3.0",
            projectSchema: "musicvideo/1.0.0"
        ))
        let target = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "1.2.0",
            projectSchema: "musicvideo/1.0.0"
        ))

        #expect(ProjectPackMigration.compatibleUpgradeKind(
            source: source,
            target: target,
            targetMigratesFrom: [],
            hasRuntimeMigration: false
        ) == nil)
    }

    @Test func aDifferentPackIsNeverPresentedAsAnUpgrade() throws {
        let source = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "1.2.0",
            projectSchema: "musicvideo/1.0.0"
        ))
        let target = try #require(ProjectPackBinding(
            id: "documentary",
            version: "1.3.0",
            projectSchema: "documentary/1.0.0"
        ))

        #expect(ProjectPackMigration.compatibleUpgradeKind(
            source: source,
            target: target,
            targetMigratesFrom: [],
            hasRuntimeMigration: false
        ) == nil)
    }
}
