import Foundation
import NexGenEngine

@MainActor
enum ProjectPackMigration {
    struct Request: Codable, Equatable {
        let source: ProjectPackBinding
        let target: ProjectPackBinding
    }

    struct PreparedRequest {
        fileprivate let key: String
        fileprivate let data: Data
        fileprivate let target: ProjectPackBinding
    }

    enum UpgradeKind: Equatable {
        case bindingOnly
        case schemaMigration
    }

    enum MigrationError: LocalizedError {
        case invalidSource
        case undeclaredMigration(from: String, to: String)
        case missingRuntimeMigration(from: String, to: String)
        case targetNotLive(id: String, version: String)

        var errorDescription: String? {
            switch self {
            case .invalidSource:
                return "The project changed after its format-pack upgrade was scheduled."
            case .undeclaredMigration(let from, let to):
                return "The format pack doesn't declare a migration from \(from) to \(to)."
            case .missingRuntimeMigration(let from, let to):
                return "The loaded format pack doesn't provide its declared migration from "
                    + "\(from) to \(to)."
            case .targetNotLive(let id, let version):
                return "The \(id) \(version) format pack isn't live for this upgrade."
            }
        }

        var recoverySuggestion: String? {
            "The saved project is untouched. Restart NexGenVideo to reopen it with "
                + "its previous format-pack version."
        }
    }

    private static let keyPrefix = "NGVPackMigration."
    private static let legacyKeyPrefix = "NGVLegacyPackMigration."

    static func request(for projectURL: URL) -> Request? {
        guard let key = ProjectIdentity.existingKey(for: projectURL),
              let data = UserDefaults.standard.data(forKey: keyPrefix + key) else {
            return nil
        }
        return try? JSONDecoder().decode(Request.self, from: data)
    }

    static func legacyTarget(for projectURL: URL) -> ProjectPackBinding? {
        guard let key = ProjectIdentity.existingKey(for: projectURL),
              let data = UserDefaults.standard.data(
                  forKey: legacyKeyPrefix + key
              ) else { return nil }
        return try? JSONDecoder().decode(ProjectPackBinding.self, from: data)
    }

    static func hasPending(projectURL: URL) -> Bool {
        request(for: projectURL) != nil
            || legacyTarget(for: projectURL) != nil
    }

    static func schedule(
        projectURL: URL,
        source: ProjectPackBinding,
        target: ProjectPackBinding
    ) throws {
        commit(try prepareSchedule(
            projectURL: projectURL,
            source: source,
            target: target
        ))
    }

    static func prepareSchedule(
        projectURL: URL,
        source: ProjectPackBinding,
        target: ProjectPackBinding
    ) throws -> PreparedRequest {
        guard source.id == target.id,
              source != target,
              let key = ProjectIdentity.existingKey(for: projectURL) else {
            throw MigrationError.invalidSource
        }
        let data = try JSONEncoder().encode(
            Request(source: source, target: target)
        )
        return PreparedRequest(key: key, data: data, target: target)
    }

    static func commit(_ request: PreparedRequest) {
        UserDefaults.standard.set(
            request.data,
            forKey: keyPrefix + request.key
        )
        PluginLoader.requestVersionForNextLaunch(
            id: request.target.id,
            version: request.target.version
        )
    }

    static func scheduleLegacy(
        projectURL: URL,
        target: ProjectPackBinding
    ) throws {
        let key = try ProjectIdentity.key(for: projectURL)
        UserDefaults.standard.set(
            try JSONEncoder().encode(target),
            forKey: legacyKeyPrefix + key
        )
    }

    static func effectiveBinding(
        persisted: ProjectPackBinding,
        projectURL: URL
    ) -> ProjectPackBinding {
        guard let request = request(for: projectURL),
              request.source == persisted else { return persisted }
        return request.target
    }

    nonisolated static func upgradeKind(
        source: ProjectPackBinding,
        target: ProjectPackBinding
    ) -> UpgradeKind {
        source.projectSchema == target.projectSchema
            ? .bindingOnly
            : .schemaMigration
    }

    static func applyPending(
        projectURL: URL,
        workingCopyKey: String
    ) throws -> Bool {
        if let target = legacyTarget(for: projectURL) {
            return try applyLegacy(
                projectURL: projectURL,
                workingCopyKey: workingCopyKey,
                target: target
            )
        }
        guard let request = request(for: projectURL) else { return false }
        guard PluginLoader.liveBinding(id: request.target.id)
                == request.target else {
            throw MigrationError.targetNotLive(
                id: request.target.id,
                version: request.target.version
            )
        }
        guard case .bound(let persisted) = ProjectPluginSettings.bindingResolution(
            projectURL: projectURL
        ), persisted == request.source else {
            throw MigrationError.invalidSource
        }
        if ProjectPluginSettings.bindingResolution(
            projectURL: ProjectWorkingCopy.home(workingCopyKey)
        ) == .bound(request.target) {
            return true
        }
        guard let info = PluginLoader.installedInfo(
            id: request.target.id,
            version: request.target.version
        )?.info,
              info.projectSchema == request.target.projectSchema else {
            throw MigrationError.undeclaredMigration(
                from: request.source.projectSchema,
                to: request.target.projectSchema
            )
        }
        let migrate: @Sendable (URL) throws -> Void
        if upgradeKind(
            source: request.source,
            target: request.target
        ) == .bindingOnly {
            migrate = { _ in }
        } else {
            guard info.migratesFrom.contains(request.source.projectSchema) else {
                throw MigrationError.undeclaredMigration(
                    from: request.source.projectSchema,
                    to: request.target.projectSchema
                )
            }
            let registry = PackCatalog.registry(activePack: request.target.id)
            guard let migration = registry.projectSchemaMigrations.first(where: {
                $0.from == request.source.projectSchema
                    && $0.to == request.target.projectSchema
            }) else {
                throw MigrationError.missingRuntimeMigration(
                    from: request.source.projectSchema,
                    to: request.target.projectSchema
                )
            }
            migrate = migration.migrate
        }

        try migrateWorkingCopy(
            key: workingCopyKey,
            target: request.target,
            migrate: migrate
        )
        return true
    }

    static func bindLegacyProject(
        projectURL: URL,
        workingCopyKey: String
    ) throws -> Bool {
        guard case .legacy(let id) = ProjectPluginSettings.bindingResolution(
            projectURL: projectURL
        ), let binding = PluginLoader.liveBinding(id: id),
              binding.projectSchema == "\(id)/legacy" else {
            return false
        }
        if ProjectPluginSettings.bindingResolution(
            projectURL: ProjectWorkingCopy.home(workingCopyKey)
        ) == .bound(binding) {
            return false
        }
        try ProjectWorkingCopy.transact(
            key: workingCopyKey,
            markDirty: false
        ) { staging in
            try ProjectPluginSettings.setActivePlugin(
                binding,
                projectURL: staging
            )
        }
        return true
    }

    static func cancel(projectURL: URL) {
        if let request = request(for: projectURL) {
            PluginLoader.requestVersionForNextLaunch(
                id: request.source.id,
                version: request.source.version
            )
        }
        clear(projectURL: projectURL)
    }

    static func complete(projectURL: URL) {
        clear(projectURL: projectURL)
    }

    private static func clear(projectURL: URL) {
        guard let key = ProjectIdentity.existingKey(for: projectURL) else { return }
        UserDefaults.standard.removeObject(forKey: keyPrefix + key)
        UserDefaults.standard.removeObject(forKey: legacyKeyPrefix + key)
    }

    private static func applyLegacy(
        projectURL: URL,
        workingCopyKey: String,
        target: ProjectPackBinding
    ) throws -> Bool {
        guard case .legacy(let id) = ProjectPluginSettings.bindingResolution(
            projectURL: projectURL
        ), id == target.id else {
            throw MigrationError.invalidSource
        }
        guard PluginLoader.liveBinding(id: target.id) == target else {
            throw MigrationError.targetNotLive(
                id: target.id,
                version: target.version
            )
        }
        if ProjectPluginSettings.bindingResolution(
            projectURL: ProjectWorkingCopy.home(workingCopyKey)
        ) == .bound(target) {
            return true
        }
        let sourceSchema = "\(id)/legacy"
        guard let info = PluginLoader.installedInfo(
            id: target.id,
            version: target.version
        )?.info,
              info.projectSchema == target.projectSchema,
              info.migratesFrom.contains(sourceSchema) else {
            throw MigrationError.undeclaredMigration(
                from: sourceSchema,
                to: target.projectSchema
            )
        }
        let registry = PackCatalog.registry(activePack: target.id)
        guard let migration = registry.projectSchemaMigrations.first(where: {
            $0.from == sourceSchema && $0.to == target.projectSchema
        }) else {
            throw MigrationError.missingRuntimeMigration(
                from: sourceSchema,
                to: target.projectSchema
            )
        }
        try migrateWorkingCopy(
            key: workingCopyKey,
            target: target,
            migrate: migration.migrate
        )
        return true
    }

    private static func migrateWorkingCopy(
        key: String,
        target: ProjectPackBinding,
        migrate: @escaping @Sendable (URL) throws -> Void
    ) throws {
        try ProjectWorkingCopy.transact(key: key) { staging in
            try migrate(staging)
            try ProjectPluginSettings.setActivePlugin(
                target,
                projectURL: staging
            )
            try VideoProject.validateEditableContents(at: staging)
        }
    }
}
