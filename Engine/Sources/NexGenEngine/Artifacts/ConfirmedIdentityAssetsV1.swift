import Foundation

public enum ConfirmedIdentityAssetRoleV1: String, Codable, Sendable,
    Equatable, CaseIterable {
    case character
    case location
}

public struct ConfirmedIdentityAssetV1: Codable, Sendable, Equatable {
    public let id: String
    public let role: ConfirmedIdentityAssetRoleV1
    public let identityName: String
    public let identitySlug: String
    public let path: String
    public let sha256: String
    public let originalPath: String
    public let originalSHA256: String
    public let confirmedAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case identityName = "identity_name"
        case identitySlug = "identity_slug"
        case path
        case sha256
        case originalPath = "original_path"
        case originalSHA256 = "original_sha256"
        case confirmedAt = "confirmed_at"
    }

    public init(
        id: String,
        role: ConfirmedIdentityAssetRoleV1,
        identityName: String,
        identitySlug: String,
        path: String,
        sha256: String,
        originalPath: String,
        originalSHA256: String,
        confirmedAt: String
    ) {
        self.id = id
        self.role = role
        self.identityName = identityName
        self.identitySlug = identitySlug
        self.path = path
        self.sha256 = sha256
        self.originalPath = originalPath
        self.originalSHA256 = originalSHA256
        self.confirmedAt = confirmedAt
    }
}

public struct ConfirmedIdentityAssetManifestV1: Codable, Sendable,
    Equatable {
    public static let schemaVersion = "confirmed-identity-assets/v1"

    public let schema: String
    public let project: String
    public var entries: [String: ConfirmedIdentityAssetV1]

    public init(
        schema: String = schemaVersion,
        project: String,
        entries: [String: ConfirmedIdentityAssetV1] = [:]
    ) {
        self.schema = schema
        self.project = project
        self.entries = entries
    }
}

public struct BibleViewProvenanceRequirementV1: Sendable, Equatable {
    public let path: String
    public let confirmedRole: ConfirmedIdentityAssetRoleV1?
    public let identityID: String?
    public let identityName: String?

    public init(
        path: String,
        confirmedRole: ConfirmedIdentityAssetRoleV1?,
        identityID: String?,
        identityName: String?
    ) {
        self.path = path
        self.confirmedRole = confirmedRole
        self.identityID = identityID
        self.identityName = identityName
    }
}

public enum BibleViewProvenanceRequirementsV1 {
    public static func make(
        bible: Bible
    ) -> [BibleViewProvenanceRequirementV1] {
        var requirements = bible.characters.flatMap { entity in
            entity.sheets.values.map {
                BibleViewProvenanceRequirementV1(
                    path: $0,
                    confirmedRole: .character,
                    identityID: entity.id,
                    identityName: entity.name
                )
            }
        }
        requirements += bible.ensembles.flatMap { entity in
            entity.sheets.values.map {
                BibleViewProvenanceRequirementV1(
                    path: $0,
                    confirmedRole: nil,
                    identityID: entity.id,
                    identityName: entity.name
                )
            }
        }
        requirements += bible.props.flatMap { entity in
            entity.sheets.values.map {
                BibleViewProvenanceRequirementV1(
                    path: $0,
                    confirmedRole: nil,
                    identityID: entity.id,
                    identityName: entity.name
                )
            }
        }
        requirements += bible.locations.flatMap { entity in
            var paths = entity.sheets.values.map {
                BibleViewProvenanceRequirementV1(
                    path: $0,
                    confirmedRole: .location,
                    identityID: entity.id,
                    identityName: entity.name
                )
            }
            if !entity.scene3d.panorama.isEmpty {
                paths.append(BibleViewProvenanceRequirementV1(
                    path: entity.scene3d.panorama,
                    confirmedRole: .location,
                    identityID: entity.id,
                    identityName: entity.name
                ))
            }
            return paths
        }
        return requirements.sorted {
            if $0.path == $1.path {
                return ($0.identityID ?? "") < ($1.identityID ?? "")
            }
            return $0.path < $1.path
        }
    }
}

public enum ConfirmedIdentityAssetStoreV1 {
    public static func load(dataRoot: URL) throws
        -> ConfirmedIdentityAssetManifestV1 {
        let url = PipelineLayout.url(
            PipelineLayout.confirmedIdentityAssetsFile,
            in: dataRoot
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ConfirmedIdentityAssetManifestV1(
                project: FrameInventory.projectName(of: dataRoot)
                    ?? dataRoot.lastPathComponent
            )
        }
        return try JSONArtifactStore(dataRoot: dataRoot).load(
            ConfirmedIdentityAssetManifestV1.self,
            at: PipelineLayout.confirmedIdentityAssetsFile
        )
    }

    public static func save(
        _ manifest: ConfirmedIdentityAssetManifestV1,
        dataRoot: URL
    ) throws {
        try validate(manifest, dataRoot: dataRoot)
        try JSONArtifactStore(dataRoot: dataRoot).save(
            manifest,
            to: PipelineLayout.confirmedIdentityAssetsFile
        )
    }

    public static func recordIntake(
        role: ConfirmedIdentityAssetRoleV1,
        identityName: String,
        identitySlug: String,
        paths: [String],
        dataRoot: URL,
        confirmedAt: String = currentTimestamp()
    ) throws {
        var manifest = try load(dataRoot: dataRoot)
        try requireIdentity(
            manifest,
            dataRoot: dataRoot
        )
        for path in paths {
            let sha256 = try currentHash(path: path, dataRoot: dataRoot)
            let idData = Data(
                "\(role.rawValue)\n\(identitySlug)\n\(path)\n\(sha256)"
                    .utf8
            )
            manifest.entries[path] = ConfirmedIdentityAssetV1(
                id: "confirmed-identity-\(FileDigest.sha256(of: idData))",
                role: role,
                identityName: identityName,
                identitySlug: identitySlug,
                path: path,
                sha256: sha256,
                originalPath: path,
                originalSHA256: sha256,
                confirmedAt: confirmedAt
            )
        }
        try save(manifest, dataRoot: dataRoot)
    }

    @discardableResult
    public static func adopt(
        from sourcePath: String,
        to destinationPath: String,
        dataRoot: URL
    ) throws -> Bool {
        let manifest = try load(dataRoot: dataRoot)
        try requireIdentity(manifest, dataRoot: dataRoot)
        guard let source = manifest.entries[sourcePath],
              source.path == source.originalPath,
              try isCurrent(source, dataRoot: dataRoot) else {
            return false
        }
        let destinationSHA256 = try currentHash(
            path: destinationPath,
            dataRoot: dataRoot
        )
        return destinationSHA256 == source.sha256
    }

    public static func isCurrent(
        _ path: String,
        dataRoot: URL
    ) throws -> Bool {
        try currentEntry(path, dataRoot: dataRoot) != nil
    }

    public static func intakeLineageSHA256(dataRoot: URL) throws -> String {
        let manifest = try load(dataRoot: dataRoot)
        try requireIdentity(manifest, dataRoot: dataRoot)
        var intake = manifest
        intake.entries = manifest.entries.filter { path, entry in
            path == entry.path && entry.path == entry.originalPath
        }
        try validate(intake, dataRoot: dataRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileDigest.sha256(of: try encoder.encode(intake))
    }

    public static func currentEntry(
        _ path: String,
        dataRoot: URL
    ) throws -> ConfirmedIdentityAssetV1? {
        let manifest = try load(dataRoot: dataRoot)
        try requireIdentity(manifest, dataRoot: dataRoot)
        return try currentEntries(
            path,
            manifest: manifest,
            dataRoot: dataRoot
        ).first
    }

    private static func currentEntries(
        _ path: String,
        manifest: ConfirmedIdentityAssetManifestV1,
        dataRoot: URL
    ) throws -> [ConfirmedIdentityAssetV1] {
        if let entry = manifest.entries[path] {
            return try isCurrent(entry, dataRoot: dataRoot) ? [entry] : []
        }
        guard let destinationSHA256 = try? currentHash(
            path: path,
            dataRoot: dataRoot
        ) else { return [] }
        return manifest.entries.values
            .filter {
                $0.path == $0.originalPath
                    && $0.sha256 == destinationSHA256
                    && (try? isCurrent($0, dataRoot: dataRoot)) == true
            }
            .sorted { $0.id < $1.id }
            .map {
                adoptedEntry(
                    from: $0,
                    destinationPath: path,
                    destinationSHA256: destinationSHA256
                )
            }
    }

    public static func matchesCurrent(
        _ path: String,
        role: ConfirmedIdentityAssetRoleV1,
        identityID: String,
        identityName: String,
        dataRoot: URL
    ) throws -> Bool {
        let manifest = try load(dataRoot: dataRoot)
        try requireIdentity(manifest, dataRoot: dataRoot)
        let normalizedID = identityID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let normalizedName = identityName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return try currentEntries(
            path,
            manifest: manifest,
            dataRoot: dataRoot
        ).contains { entry in
            let normalizedSlug = entry.identitySlug
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            let nameMatches = entry.identityName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalizedName) == .orderedSame
            return entry.role == role
                && normalizedSlug == normalizedID
                && nameMatches
        }
    }

    public static func validate(
        _ manifest: ConfirmedIdentityAssetManifestV1,
        dataRoot: URL
    ) throws {
        try requireIdentity(manifest, dataRoot: dataRoot)
        guard Set(manifest.entries.values.map(\.id)).count
                == manifest.entries.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for (path, entry) in manifest.entries {
            guard path == entry.path,
                  !entry.id.isEmpty,
                  !entry.identityName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  !entry.identitySlug.isEmpty,
                  entry.sha256.count == 64,
                  entry.originalSHA256.count == 64,
                  !entry.confirmedAt.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            _ = try ProjectLocalFile.resolve(
                entry.path,
                dataRoot: dataRoot
            )
            _ = try ProjectLocalFile.resolve(
                entry.originalPath,
                dataRoot: dataRoot
            )
        }
    }

    private static func requireIdentity(
        _ manifest: ConfirmedIdentityAssetManifestV1,
        dataRoot: URL
    ) throws {
        let project = FrameInventory.projectName(of: dataRoot)
            ?? dataRoot.lastPathComponent
        guard manifest.schema == ConfirmedIdentityAssetManifestV1.schemaVersion,
              manifest.project == project else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func isCurrent(
        _ entry: ConfirmedIdentityAssetV1,
        dataRoot: URL
    ) throws -> Bool {
        let current = try currentHash(path: entry.path, dataRoot: dataRoot)
        let original = try currentHash(
            path: entry.originalPath,
            dataRoot: dataRoot
        )
        return current == entry.sha256
            && original == entry.originalSHA256
            && entry.sha256 == entry.originalSHA256
    }

    private static func adoptedEntry(
        from source: ConfirmedIdentityAssetV1,
        destinationPath: String,
        destinationSHA256: String
    ) -> ConfirmedIdentityAssetV1 {
        let idData = Data(
            "\(source.id)\n\(destinationPath)\n\(destinationSHA256)".utf8
        )
        return ConfirmedIdentityAssetV1(
            id: "confirmed-identity-\(FileDigest.sha256(of: idData))",
            role: source.role,
            identityName: source.identityName,
            identitySlug: source.identitySlug,
            path: destinationPath,
            sha256: destinationSHA256,
            originalPath: source.originalPath,
            originalSHA256: source.originalSHA256,
            confirmedAt: source.confirmedAt
        )
    }

    private static func currentHash(path: String, dataRoot: URL) throws
        -> String {
        let url = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true,
              ProjectMediaExtensions.images.contains(
                url.pathExtension.lowercased()
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try FileDigest.sha256(of: url)
    }
}
