import Foundation
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
            ProjectPackMigration.effectiveBinding(
                persisted: source,
                projectURL: project
            ) == target
        )
        ProjectPackMigration.cancel(projectURL: project)
        #expect(
            ProjectPackMigration.effectiveBinding(
                persisted: source,
                projectURL: project
            ) == source
        )
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
}
