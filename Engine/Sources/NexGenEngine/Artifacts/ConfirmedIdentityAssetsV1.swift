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

public struct ConfirmedIdentityAdoptionV1: Codable, Sendable, Equatable {
    public let id: String
    public let sourceConfirmationID: String
    public let role: ConfirmedIdentityAssetRoleV1
    public let identityName: String
    public let identitySlug: String
    public let sourcePath: String
    public let sourceSHA256: String
    public let targetPath: String
    public let targetSHA256: String
    public let originalPath: String
    public let originalSHA256: String
    public let confirmedAt: String
    public let recordedAt: String
    public let recoveredFromLegacyEntryID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceConfirmationID = "source_confirmation_id"
        case role
        case identityName = "identity_name"
        case identitySlug = "identity_slug"
        case sourcePath = "source_path"
        case sourceSHA256 = "source_sha256"
        case targetPath = "target_path"
        case targetSHA256 = "target_sha256"
        case originalPath = "original_path"
        case originalSHA256 = "original_sha256"
        case confirmedAt = "confirmed_at"
        case recordedAt = "recorded_at"
        case recoveredFromLegacyEntryID = "recovered_from_legacy_entry_id"
    }

    public init(
        id: String,
        sourceConfirmationID: String,
        role: ConfirmedIdentityAssetRoleV1,
        identityName: String,
        identitySlug: String,
        sourcePath: String,
        sourceSHA256: String,
        targetPath: String,
        targetSHA256: String,
        originalPath: String,
        originalSHA256: String,
        confirmedAt: String,
        recordedAt: String,
        recoveredFromLegacyEntryID: String? = nil
    ) {
        self.id = id
        self.sourceConfirmationID = sourceConfirmationID
        self.role = role
        self.identityName = identityName
        self.identitySlug = identitySlug
        self.sourcePath = sourcePath
        self.sourceSHA256 = sourceSHA256
        self.targetPath = targetPath
        self.targetSHA256 = targetSHA256
        self.originalPath = originalPath
        self.originalSHA256 = originalSHA256
        self.confirmedAt = confirmedAt
        self.recordedAt = recordedAt
        self.recoveredFromLegacyEntryID = recoveredFromLegacyEntryID
    }
}

public struct ConfirmedIdentityAdoptionRecoveryV1: Codable, Sendable,
    Equatable {
    public let id: String
    public let legacyManifestSHA256: String
    public let recoveredManifestSHA256: String
    public let adoptedTargets: [String]
    public let discardedNonBibleTargets: [String]
    public let discardedStaleEntries: [ConfirmedIdentityDiscardedLegacyEntryV1]
    public let recoveredAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case legacyManifestSHA256 = "legacy_manifest_sha256"
        case recoveredManifestSHA256 = "recovered_manifest_sha256"
        case adoptedTargets = "adopted_targets"
        case discardedNonBibleTargets = "discarded_non_bible_targets"
        case discardedStaleEntries = "discarded_stale_entries"
        case recoveredAt = "recovered_at"
    }

    public init(
        id: String,
        legacyManifestSHA256: String,
        recoveredManifestSHA256: String,
        adoptedTargets: [String],
        discardedNonBibleTargets: [String],
        discardedStaleEntries: [ConfirmedIdentityDiscardedLegacyEntryV1],
        recoveredAt: String
    ) {
        self.id = id
        self.legacyManifestSHA256 = legacyManifestSHA256
        self.recoveredManifestSHA256 = recoveredManifestSHA256
        self.adoptedTargets = adoptedTargets
        self.discardedNonBibleTargets = discardedNonBibleTargets
        self.discardedStaleEntries = discardedStaleEntries
        self.recoveredAt = recoveredAt
    }
}

public struct ConfirmedIdentityDiscardedLegacyEntryV1: Codable, Sendable,
    Equatable {
    public let entry: ConfirmedIdentityAssetV1
    public let reason: String

    public init(entry: ConfirmedIdentityAssetV1, reason: String) {
        self.entry = entry
        self.reason = reason
    }
}

public struct ConfirmedIdentityAdoptionManifestV1: Codable, Sendable,
    Equatable {
    public static let schemaVersion = "confirmed-identity-adoptions/v1"

    public let schema: String
    public let project: String
    public var entries: [String: ConfirmedIdentityAdoptionV1]
    public var recoveries: [ConfirmedIdentityAdoptionRecoveryV1]

    public init(
        schema: String = schemaVersion,
        project: String,
        entries: [String: ConfirmedIdentityAdoptionV1] = [:],
        recoveries: [ConfirmedIdentityAdoptionRecoveryV1] = []
    ) {
        self.schema = schema
        self.project = project
        self.entries = entries
        self.recoveries = recoveries
    }
}

public struct ConfirmedIdentityLegacyRecoveryStatusV1: Sendable, Equatable {
    public let affectedTargets: [String]
    public let discardedTargets: [String]
    public let eligible: Bool
    public let blocker: String?

    public init(
        affectedTargets: [String],
        discardedTargets: [String] = [],
        eligible: Bool,
        blocker: String?
    ) {
        self.affectedTargets = affectedTargets
        self.discardedTargets = discardedTargets
        self.eligible = eligible
        self.blocker = blocker
    }
}

public struct ConfirmedIdentityLegacyRecoveryResultV1: Sendable, Equatable {
    public let recoveredTargets: [String]
    public let discardedNonBibleTargets: [String]
    public let discardedStaleTargets: [String]
    public let legacyManifestSHA256: String
    public let recoveredManifestSHA256: String
    public let receiptID: String

    public init(
        recoveredTargets: [String],
        discardedNonBibleTargets: [String],
        discardedStaleTargets: [String],
        legacyManifestSHA256: String,
        recoveredManifestSHA256: String,
        receiptID: String
    ) {
        self.recoveredTargets = recoveredTargets
        self.discardedNonBibleTargets = discardedNonBibleTargets
        self.discardedStaleTargets = discardedStaleTargets
        self.legacyManifestSHA256 = legacyManifestSHA256
        self.recoveredManifestSHA256 = recoveredManifestSHA256
        self.receiptID = receiptID
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
    private struct LegacyRecoveryPlan {
        let intake: ConfirmedIdentityAssetManifestV1
        let adoptions: ConfirmedIdentityAdoptionManifestV1
        let result: ConfirmedIdentityLegacyRecoveryResultV1
        let adoptionManifestSHA256: String?
    }

    public static func load(dataRoot: URL) throws
        -> ConfirmedIdentityAssetManifestV1 {
        try loadIntakeSnapshot(dataRoot: dataRoot).manifest
    }

    private static func loadIntakeSnapshot(
        dataRoot: URL
    ) throws -> (
        manifest: ConfirmedIdentityAssetManifestV1,
        sha256: String?
    ) {
        let url = PipelineLayout.url(
            PipelineLayout.confirmedIdentityAssetsFile,
            in: dataRoot
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (
                ConfirmedIdentityAssetManifestV1(
                    project: FrameInventory.projectName(of: dataRoot)
                        ?? dataRoot.lastPathComponent
                ),
                nil
            )
        }
        _ = try ProjectLocalFile.resolve(
            PipelineLayout.confirmedIdentityAssetsFile,
            dataRoot: dataRoot
        )
        let data = try Data(contentsOf: url)
        return (
            try JSONDecoder().decode(
                ConfirmedIdentityAssetManifestV1.self,
                from: data
            ),
            FileDigest.sha256(of: data)
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
        guard legacyAdoptions(in: manifest).isEmpty else {
            throw GateBlocked(
                "Confirmed identity provenance uses the legacy mixed layout. "
                    + "Run the explicit identity-provenance recovery before changing intake."
            )
        }
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
    public static func prepareAdoption(
        from sourcePath: String,
        to destinationPath: String,
        dataRoot: URL
    ) throws -> Bool {
        guard destinationPath.hasPrefix("bible/") else { return false }
        let manifest = try load(dataRoot: dataRoot)
        try requireIdentity(manifest, dataRoot: dataRoot)
        guard legacyAdoptions(in: manifest).isEmpty else {
            throw GateBlocked(
                "Confirmed identity provenance uses the legacy mixed layout. "
                    + "Run the explicit identity-provenance recovery first."
            )
        }
        guard let source = manifest.entries[sourcePath] else { return false }
        guard source.path == source.originalPath,
              try isCurrent(source, dataRoot: dataRoot) else {
            throw GateBlocked(
                "The confirmed identity source at \(sourcePath) no longer matches "
                    + "its original confirmation. Reconfirm it before staging a Bible reference."
            )
        }
        return true
    }

    @discardableResult
    public static func adopt(
        from sourcePath: String,
        to destinationPath: String,
        dataRoot: URL
    ) throws -> Bool {
        let manifest = try load(dataRoot: dataRoot)
        try requireIdentity(manifest, dataRoot: dataRoot)
        guard legacyAdoptions(in: manifest).isEmpty else {
            throw GateBlocked(
                "Confirmed identity provenance uses the legacy mixed layout. "
                    + "Run the explicit identity-provenance recovery first."
            )
        }
        guard let source = manifest.entries[sourcePath],
              source.path == source.originalPath,
              try isCurrent(source, dataRoot: dataRoot) else {
            return false
        }
        guard destinationPath.hasPrefix("bible/") else { return false }
        let destinationSHA256 = try currentHash(
            path: destinationPath,
            dataRoot: dataRoot
        )
        guard destinationSHA256 == source.sha256 else { return false }
        var adoptions = try loadAdoptions(dataRoot: dataRoot)
        let existing = adoptions.entries[destinationPath]
        let entryID = adoptionID(
            sourceConfirmationID: source.id,
            targetPath: destinationPath,
            targetSHA256: destinationSHA256
        )
        let preservesExistingProof = existing?.id == entryID
        let entry = adoption(
            source: source,
            destinationPath: destinationPath,
            destinationSHA256: destinationSHA256,
            recordedAt: preservesExistingProof
                ? existing?.recordedAt ?? currentTimestamp()
                : currentTimestamp(),
            recoveredFromLegacyEntryID: preservesExistingProof
                ? existing?.recoveredFromLegacyEntryID
                : nil
        )
        if existing == entry,
           try isCurrent(entry, intake: manifest, dataRoot: dataRoot) {
            return true
        }
        adoptions.entries[destinationPath] = entry
        try saveAdoptions(adoptions, dataRoot: dataRoot)
        return true
    }

    @discardableResult
    public static func removeAdoption(
        at destinationPath: String,
        dataRoot: URL
    ) throws -> Bool {
        var manifest = try loadAdoptions(dataRoot: dataRoot)
        guard manifest.entries.removeValue(forKey: destinationPath) != nil else {
            return false
        }
        try saveAdoptionStructure(manifest, dataRoot: dataRoot)
        return true
    }

    public static func loadAdoptions(
        dataRoot: URL
    ) throws -> ConfirmedIdentityAdoptionManifestV1 {
        try loadAdoptionSnapshot(dataRoot: dataRoot).manifest
    }

    private static func loadAdoptionSnapshot(
        dataRoot: URL
    ) throws -> (
        manifest: ConfirmedIdentityAdoptionManifestV1,
        sha256: String?
    ) {
        let path = PipelineLayout.confirmedIdentityAdoptionsFile
        let url = PipelineLayout.url(path, in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (
                ConfirmedIdentityAdoptionManifestV1(
                    project: projectName(dataRoot: dataRoot)
                ),
                nil
            )
        }
        _ = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(
            ConfirmedIdentityAdoptionManifestV1.self,
            from: data
        )
        try validateAdoptionStructure(manifest, dataRoot: dataRoot)
        return (manifest, FileDigest.sha256(of: data))
    }

    public static func legacyRecoveryStatus(
        dataRoot: URL
    ) -> ConfirmedIdentityLegacyRecoveryStatusV1? {
        do {
            let snapshot = try loadIntakeSnapshot(dataRoot: dataRoot)
            let manifest = snapshot.manifest
            let aliases = legacyAdoptions(in: manifest)
            guard !aliases.isEmpty,
                  let legacyManifestSHA256 = snapshot.sha256 else {
                return nil
            }
            let plan = try makeRecoveryPlan(
                manifest: manifest,
                legacyManifestSHA256: legacyManifestSHA256,
                recoveredAt: "recovery-readiness",
                dataRoot: dataRoot
            )
            return ConfirmedIdentityLegacyRecoveryStatusV1(
                affectedTargets: aliases.map(\.path).sorted(),
                discardedTargets: (
                    plan.result.discardedNonBibleTargets
                        + plan.result.discardedStaleTargets
                ).sorted(),
                eligible: true,
                blocker: nil
            )
        } catch {
            let paths = (try? load(dataRoot: dataRoot))
                .map { legacyAdoptions(in: $0).map(\.path).sorted() } ?? []
            guard !paths.isEmpty else { return nil }
            return ConfirmedIdentityLegacyRecoveryStatusV1(
                affectedTargets: paths,
                discardedTargets: [],
                eligible: false,
                blocker: error.localizedDescription
            )
        }
    }

    public static func recoverLegacyAdoptions(
        dataRoot: URL,
        recoveredAt: String = currentTimestamp()
    ) throws -> ConfirmedIdentityLegacyRecoveryResultV1? {
        let snapshot = try loadIntakeSnapshot(dataRoot: dataRoot)
        let manifest = snapshot.manifest
        guard !legacyAdoptions(in: manifest).isEmpty,
              let legacyManifestSHA256 = snapshot.sha256 else { return nil }
        let plan = try makeRecoveryPlan(
            manifest: manifest,
            legacyManifestSHA256: legacyManifestSHA256,
            recoveredAt: recoveredAt,
            dataRoot: dataRoot
        )
        let intakeURL = PipelineLayout.url(
            PipelineLayout.confirmedIdentityAssetsFile,
            in: dataRoot
        )
        let adoptionURL = PipelineLayout.url(
            PipelineLayout.confirmedIdentityAdoptionsFile,
            in: dataRoot
        )
        try ArtifactTransaction.perform(
            paths: [intakeURL, adoptionURL],
            dataRoot: dataRoot
        ) {
            guard try fileSHAIfPresent(intakeURL)
                    == plan.result.legacyManifestSHA256,
                  try fileSHAIfPresent(adoptionURL)
                    == plan.adoptionManifestSHA256 else {
                throw GateBlocked(
                    "Confirmed identity provenance changed during recovery. Refresh project state before retrying."
                )
            }
            for path in plan.result.recoveredTargets {
                guard let entry = plan.adoptions.entries[path],
                      try isCurrent(
                        entry,
                        intake: plan.intake,
                        dataRoot: dataRoot
                      ) else {
                    throw GateBlocked(
                        "Confirmed identity reference changed during recovery at \(path). Refresh project state before retrying."
                    )
                }
            }
            try save(plan.intake, dataRoot: dataRoot)
            try saveAdoptions(
                plan.adoptions,
                dataRoot: dataRoot
            )
        }
        return plan.result
    }

    public static func isCurrent(
        _ path: String,
        dataRoot: URL
    ) throws -> Bool {
        try currentEntry(path, dataRoot: dataRoot) != nil
    }

    public static func currentEntry(
        _ path: String,
        dataRoot: URL
    ) throws -> ConfirmedIdentityAssetV1? {
        let manifest = try load(dataRoot: dataRoot)
        try requireIdentity(manifest, dataRoot: dataRoot)
        if let entry = manifest.entries[path],
           try isCurrent(entry, dataRoot: dataRoot) {
            return entry
        }
        let adoptions = try loadAdoptions(dataRoot: dataRoot)
        guard let adoption = adoptions.entries[path],
              try isCurrent(
                adoption,
                intake: manifest,
                dataRoot: dataRoot
              ) else { return nil }
        return ConfirmedIdentityAssetV1(
            id: adoption.id,
            role: adoption.role,
            identityName: adoption.identityName,
            identitySlug: adoption.identitySlug,
            path: adoption.targetPath,
            sha256: adoption.targetSHA256,
            originalPath: adoption.originalPath,
            originalSHA256: adoption.originalSHA256,
            confirmedAt: adoption.confirmedAt
        )
    }

    public static func matchesCurrent(
        _ path: String,
        role: ConfirmedIdentityAssetRoleV1,
        identityID: String,
        identityName: String,
        dataRoot: URL
    ) throws -> Bool {
        guard let entry = try currentEntry(path, dataRoot: dataRoot),
              entry.role == role else { return false }
        let normalizedID = identityID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let normalizedSlug = entry.identitySlug
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let nameMatches = entry.identityName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(identityName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )) == .orderedSame
        return normalizedSlug == normalizedID && nameMatches
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
                  entry.path == entry.originalPath,
                  !entry.id.isEmpty,
                  !entry.identityName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  !entry.identitySlug.isEmpty,
                  entry.sha256.count == 64,
                  entry.originalSHA256.count == 64,
                  entry.sha256 == entry.originalSHA256,
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

    private static func requireIdentity(
        _ manifest: ConfirmedIdentityAdoptionManifestV1,
        dataRoot: URL
    ) throws {
        guard manifest.schema == ConfirmedIdentityAdoptionManifestV1.schemaVersion,
              manifest.project == projectName(dataRoot: dataRoot) else {
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

    private static func isCurrent(
        _ adoption: ConfirmedIdentityAdoptionV1,
        intake: ConfirmedIdentityAssetManifestV1,
        dataRoot: URL
    ) throws -> Bool {
        guard try isSourceCurrent(
            adoption,
            intake: intake,
            dataRoot: dataRoot
        ) else { return false }
        return try currentHash(
            path: adoption.targetPath,
            dataRoot: dataRoot
        ) == adoption.targetSHA256
    }

    private static func isSourceCurrent(
        _ adoption: ConfirmedIdentityAdoptionV1,
        intake: ConfirmedIdentityAssetManifestV1,
        dataRoot: URL
    ) throws -> Bool {
        guard let source = intake.entries[adoption.sourcePath],
              source.path == source.originalPath,
              source.id == adoption.sourceConfirmationID,
              source.role == adoption.role,
              source.identityName == adoption.identityName,
              source.identitySlug == adoption.identitySlug,
              source.sha256 == adoption.sourceSHA256,
              source.originalPath == adoption.originalPath,
              source.originalSHA256 == adoption.originalSHA256,
              source.confirmedAt == adoption.confirmedAt,
              adoption.targetPath.hasPrefix("bible/"),
              adoption.targetSHA256 == adoption.sourceSHA256,
              adoption.id == adoptionID(
                sourceConfirmationID: adoption.sourceConfirmationID,
                targetPath: adoption.targetPath,
                targetSHA256: adoption.targetSHA256
              ),
              try isCurrent(source, dataRoot: dataRoot) else {
            return false
        }
        return true
    }

    private static func saveAdoptions(
        _ manifest: ConfirmedIdentityAdoptionManifestV1,
        dataRoot: URL
    ) throws {
        try saveAdoptionStructure(manifest, dataRoot: dataRoot)
    }

    private static func saveAdoptionStructure(
        _ manifest: ConfirmedIdentityAdoptionManifestV1,
        dataRoot: URL
    ) throws {
        try validateAdoptionStructure(manifest, dataRoot: dataRoot)
        try JSONArtifactStore(dataRoot: dataRoot).save(
            manifest,
            to: PipelineLayout.confirmedIdentityAdoptionsFile
        )
    }

    private static func legacyAdoptions(
        in manifest: ConfirmedIdentityAssetManifestV1
    ) -> [ConfirmedIdentityAssetV1] {
        manifest.entries.values.filter {
            $0.path != $0.originalPath
        }.sorted { $0.path < $1.path }
    }

    private static func validateAdoptionStructure(
        _ manifest: ConfirmedIdentityAdoptionManifestV1,
        dataRoot: URL
    ) throws {
        try requireIdentity(manifest, dataRoot: dataRoot)
        guard Set(manifest.entries.values.map(\.id)).count
                == manifest.entries.count,
              Set(manifest.recoveries.map(\.id)).count
                == manifest.recoveries.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for (path, entry) in manifest.entries {
            guard path == entry.targetPath,
                  entry.targetPath.hasPrefix("bible/"),
                  isNormalizedProjectRelativePath(entry.targetPath),
                  isNormalizedProjectRelativePath(entry.sourcePath),
                  isNormalizedProjectRelativePath(entry.originalPath),
                  entry.sourceSHA256.count == 64,
                  entry.targetSHA256.count == 64,
                  entry.originalSHA256.count == 64,
                  entry.targetSHA256 == entry.sourceSHA256,
                  !entry.sourceConfirmationID.isEmpty,
                  !entry.sourcePath.isEmpty,
                  !entry.originalPath.isEmpty,
                  !entry.identityName.isEmpty,
                  !entry.identitySlug.isEmpty,
                  !entry.confirmedAt.isEmpty,
                  !entry.recordedAt.isEmpty,
                  entry.id == adoptionID(
                    sourceConfirmationID: entry.sourceConfirmationID,
                    targetPath: entry.targetPath,
                    targetSHA256: entry.targetSHA256
                  ) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        for recovery in manifest.recoveries {
            guard recovery.legacyManifestSHA256.count == 64,
                  recovery.recoveredManifestSHA256.count == 64,
                  !recovery.recoveredAt.isEmpty,
                  recovery.adoptedTargets
                    == Array(Set(recovery.adoptedTargets)).sorted(),
                  recovery.discardedNonBibleTargets
                    == Array(Set(
                        recovery.discardedNonBibleTargets
                    )).sorted(),
                  recovery.adoptedTargets.allSatisfy({
                    $0.hasPrefix("bible/")
                  }),
                  recovery.discardedNonBibleTargets.allSatisfy({
                    isProductionDesignAsset($0)
                  }),
                  recovery.discardedStaleEntries.map(\.entry.path)
                    == recovery.discardedStaleEntries.map(\.entry.path)
                        .sorted(),
                  Set(recovery.discardedStaleEntries.map(\.entry.path)).count
                    == recovery.discardedStaleEntries.count,
                  recovery.discardedStaleEntries.allSatisfy({
                    !$0.reason.isEmpty
                        && $0.entry.path != $0.entry.originalPath
                        && $0.entry.sha256.count == 64
                        && $0.entry.originalSHA256.count == 64
                  }),
                  recovery.id == recoveryID(
                    legacyManifestSHA256:
                        recovery.legacyManifestSHA256,
                    recoveredManifestSHA256:
                        recovery.recoveredManifestSHA256,
                    adoptedTargets: recovery.adoptedTargets,
                    discardedNonBibleTargets:
                        recovery.discardedNonBibleTargets,
                    discardedStaleEntries:
                        recovery.discardedStaleEntries
                  ) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    private static func makeRecoveryPlan(
        manifest: ConfirmedIdentityAssetManifestV1,
        legacyManifestSHA256: String,
        recoveredAt: String,
        dataRoot: URL
    ) throws -> LegacyRecoveryPlan {
        try requireIdentity(manifest, dataRoot: dataRoot)
        let aliases = legacyAdoptions(in: manifest)
        guard !aliases.isEmpty else {
            throw GateBlocked("No legacy identity-provenance entries need recovery.")
        }
        let intakeEntries = manifest.entries.filter {
            $0.value.path == $0.value.originalPath
        }
        let intake = ConfirmedIdentityAssetManifestV1(
            project: manifest.project,
            entries: intakeEntries
        )
        try validate(intake, dataRoot: dataRoot)

        let adoptionSnapshot = try loadAdoptionSnapshot(dataRoot: dataRoot)
        var adoptions = adoptionSnapshot.manifest
        var recovered: [String] = []
        var discarded: [String] = []
        var discardedStale: [ConfirmedIdentityDiscardedLegacyEntryV1] = []
        for legacy in aliases {
            if let reason = legacyDiscardReason(
                legacy,
                intake: intake,
                dataRoot: dataRoot
            ) {
                discardedStale.append(
                    ConfirmedIdentityDiscardedLegacyEntryV1(
                        entry: legacy,
                        reason: reason
                    )
                )
                continue
            }
            let source = intake.entries[legacy.originalPath]!
            if legacy.path.hasPrefix("bible/") {
                let existing = adoptions.entries[legacy.path]
                let entry = adoption(
                    source: source,
                    destinationPath: legacy.path,
                    destinationSHA256: legacy.sha256,
                    recordedAt: existing?.recordedAt ?? recoveredAt,
                    recoveredFromLegacyEntryID:
                        existing?.recoveredFromLegacyEntryID ?? legacy.id
                )
                if let existing,
                   existing != entry {
                    if try isCurrent(
                        existing,
                        intake: intake,
                        dataRoot: dataRoot
                    ) {
                        discardedStale.append(
                            ConfirmedIdentityDiscardedLegacyEntryV1(
                                entry: legacy,
                                reason: "superseded_by_current_adoption"
                            )
                        )
                        continue
                    }
                }
                adoptions.entries[legacy.path] = entry
                recovered.append(legacy.path)
            } else if isProductionDesignAsset(legacy.path) {
                discarded.append(legacy.path)
            } else {
                discardedStale.append(
                    ConfirmedIdentityDiscardedLegacyEntryV1(
                        entry: legacy,
                        reason: "unsupported_target"
                    )
                )
            }
        }
        discardedStale.sort { $0.entry.path < $1.entry.path }

        let recoveredData = try encoded(intake)
        let legacySHA = legacyManifestSHA256
        let recoveredSHA = FileDigest.sha256(of: recoveredData)
        let receipt = ConfirmedIdentityAdoptionRecoveryV1(
            id: recoveryID(
                legacyManifestSHA256: legacySHA,
                recoveredManifestSHA256: recoveredSHA,
                adoptedTargets: recovered.sorted(),
                discardedNonBibleTargets: discarded.sorted(),
                discardedStaleEntries: discardedStale
            ),
            legacyManifestSHA256: legacySHA,
            recoveredManifestSHA256: recoveredSHA,
            adoptedTargets: recovered.sorted(),
            discardedNonBibleTargets: discarded.sorted(),
            discardedStaleEntries: discardedStale,
            recoveredAt: recoveredAt
        )
        if !adoptions.recoveries.contains(where: { $0.id == receipt.id }) {
            adoptions.recoveries.append(receipt)
        }
        try validateAdoptionStructure(adoptions, dataRoot: dataRoot)
        for path in recovered {
            guard let entry = adoptions.entries[path],
                  try isCurrent(
                    entry,
                    intake: intake,
                    dataRoot: dataRoot
                  ) else {
                throw GateBlocked(
                    "Recovered confirmed-reference adoption is no longer current at \(path)."
                )
            }
        }
        return LegacyRecoveryPlan(
            intake: intake,
            adoptions: adoptions,
            result: ConfirmedIdentityLegacyRecoveryResultV1(
                recoveredTargets: recovered.sorted(),
                discardedNonBibleTargets: discarded.sorted(),
                discardedStaleTargets: discardedStale.map(\.entry.path),
                legacyManifestSHA256: legacySHA,
                recoveredManifestSHA256: recoveredSHA,
                receiptID: receipt.id
            ),
            adoptionManifestSHA256: adoptionSnapshot.sha256
        )
    }

    private static func legacyDiscardReason(
        _ legacy: ConfirmedIdentityAssetV1,
        intake: ConfirmedIdentityAssetManifestV1,
        dataRoot: URL
    ) -> String? {
        guard legacy.path.hasPrefix("bible/")
                || isProductionDesignAsset(legacy.path) else {
            return "unsupported_target"
        }
        guard let source = intake.entries[legacy.originalPath],
              legacy.role == source.role,
              legacy.identityName == source.identityName,
              legacy.identitySlug == source.identitySlug,
              legacy.sha256 == source.sha256,
              legacy.originalSHA256 == source.originalSHA256,
              legacy.confirmedAt == source.confirmedAt,
              legacy.id == legacyAdoptionID(
                sourceConfirmationID: source.id,
                targetPath: legacy.path,
                targetSHA256: legacy.sha256
              ) else {
            return "source_confirmation_changed_or_proof_invalid"
        }
        do {
            guard try isCurrent(source, dataRoot: dataRoot) else {
                return "source_bytes_changed"
            }
        } catch {
            return "source_missing_or_unsafe"
        }
        do {
            guard try currentHash(
                path: legacy.path,
                dataRoot: dataRoot
            ) == legacy.sha256 else {
                return "target_bytes_changed"
            }
        } catch {
            return "target_missing_or_unsafe"
        }
        return nil
    }

    private static func adoption(
        source: ConfirmedIdentityAssetV1,
        destinationPath: String,
        destinationSHA256: String,
        recordedAt: String,
        recoveredFromLegacyEntryID: String?
    ) -> ConfirmedIdentityAdoptionV1 {
        ConfirmedIdentityAdoptionV1(
            id: adoptionID(
                sourceConfirmationID: source.id,
                targetPath: destinationPath,
                targetSHA256: destinationSHA256
            ),
            sourceConfirmationID: source.id,
            role: source.role,
            identityName: source.identityName,
            identitySlug: source.identitySlug,
            sourcePath: source.path,
            sourceSHA256: source.sha256,
            targetPath: destinationPath,
            targetSHA256: destinationSHA256,
            originalPath: source.originalPath,
            originalSHA256: source.originalSHA256,
            confirmedAt: source.confirmedAt,
            recordedAt: recordedAt,
            recoveredFromLegacyEntryID: recoveredFromLegacyEntryID
        )
    }

    private static func adoptionID(
        sourceConfirmationID: String,
        targetPath: String,
        targetSHA256: String
    ) -> String {
        let data = Data(
            "\(sourceConfirmationID)\n\(targetPath)\n\(targetSHA256)".utf8
        )
        return "confirmed-identity-adoption-\(FileDigest.sha256(of: data))"
    }

    private static func legacyAdoptionID(
        sourceConfirmationID: String,
        targetPath: String,
        targetSHA256: String
    ) -> String {
        let data = Data(
            "\(sourceConfirmationID)\n\(targetPath)\n\(targetSHA256)".utf8
        )
        return "confirmed-identity-\(FileDigest.sha256(of: data))"
    }

    private static func recoveryID(
        legacyManifestSHA256: String,
        recoveredManifestSHA256: String,
        adoptedTargets: [String],
        discardedNonBibleTargets: [String],
        discardedStaleEntries: [ConfirmedIdentityDiscardedLegacyEntryV1]
    ) -> String {
        let lines = [
            legacyManifestSHA256,
            recoveredManifestSHA256,
        ] + adoptedTargets.map { "adopted:\($0)" }
            + discardedNonBibleTargets.map { "non-bible:\($0)" }
            + discardedStaleEntries.map {
                "stale:\($0.entry.id):\($0.entry.path):\($0.reason)"
            }
        let data = Data(lines.joined(separator: "\n").utf8)
        return "confirmed-identity-recovery-\(FileDigest.sha256(of: data))"
    }

    private static func isProductionDesignAsset(_ path: String) -> Bool {
        path.hasPrefix("production_design/refs/")
            || path == "production_design/lighting_anchor.png"
    }

    private static func isNormalizedProjectRelativePath(_ path: String) -> Bool {
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return !path.isEmpty
            && path == path.trimmingCharacters(in: .whitespacesAndNewlines)
            && !NSString(string: path).isAbsolutePath
            && components.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private static func fileSHAIfPresent(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return FileDigest.sha256(of: try Data(contentsOf: url))
    }

    private static func projectName(dataRoot: URL) -> String {
        FrameInventory.projectName(of: dataRoot) ?? dataRoot.lastPathComponent
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
