import Foundation

public struct DerivedIdentityAssetV1: Codable, Sendable, Equatable {
    public let phase: String
    public let sourcePath: String
    public let sourceSHA256: String
    public let destinationPath: String
    public let destinationSHA256: String
    public let role: ConfirmedIdentityAssetRoleV1
    public let identityName: String
    public let identitySlug: String

    public init(phase: String, source: ConfirmedIdentityAssetV1, destinationPath: String) {
        self.phase = phase
        sourcePath = source.originalPath
        sourceSHA256 = source.originalSHA256
        self.destinationPath = destinationPath
        destinationSHA256 = source.originalSHA256
        role = source.role
        identityName = source.identityName
        identitySlug = source.identitySlug
    }
}

public struct DerivedIdentityAssetManifestV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "derived-identity-assets/v1"
    public let schema: String
    public let project: String
    public let projectID: String
    public let phase: String
    public var entries: [String: DerivedIdentityAssetV1]

    public init(project: String, projectID: String, phase: String, entries: [String: DerivedIdentityAssetV1] = [:]) {
        schema = Self.schemaVersion
        self.project = project
        self.projectID = projectID
        self.phase = phase
        self.entries = entries
    }
}

public enum DerivedIdentityAssetStoreV1 {
    public static func relativePath(phase: String) throws -> String {
        guard ["production_design", "bible"].contains(phase) else {
            throw GateBlocked("Identity aliases belong only to Production Design or Bible.")
        }
        return "\(phase)/derived-identity-assets.v1.json"
    }

    public static func owningPhase(destination: String) throws -> String {
        let components = destination.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              destination == destination.trimmingCharacters(in: .whitespacesAndNewlines),
              ProjectMediaExtensions.images.contains(URL(fileURLWithPath: destination).pathExtension.lowercased()) else {
            throw ProjectLocalFileError.invalidPath(destination)
        }
        if destination.hasPrefix("production_design/refs/") || destination == "production_design/lighting_anchor.png" {
            return "production_design"
        }
        if destination.hasPrefix("bible/") { return "bible" }
        throw ProjectLocalFileError.invalidPath(destination)
    }

    public static func projectID(dataRoot: URL) throws -> String {
        let home = FrameInventory.projectHome(of: dataRoot)
        let url = home.appendingPathComponent("ngv.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile).project
        }
        let safe = try ProjectLocalFile.resolve("ngv.json", dataRoot: home)
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: safe)) as? [String: Any],
              let id = json["id"] as? String, let uuid = UUID(uuidString: id) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return uuid.uuidString
    }

    public static func load(phase: String, dataRoot: URL) throws -> DerivedIdentityAssetManifestV1 {
        let path = try relativePath(phase: phase)
        let url = dataRoot.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            let safe = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
            guard safe.standardizedFileURL == url.standardizedFileURL else {
                throw ProjectLocalFileError.invalidPath(path)
            }
            return try JSONDecoder().decode(DerivedIdentityAssetManifestV1.self, from: Data(contentsOf: safe))
        }
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile).project
        return DerivedIdentityAssetManifestV1(project: project, projectID: try projectID(dataRoot: dataRoot), phase: phase)
    }

    public static func validate(_ manifest: DerivedIdentityAssetManifestV1, dataRoot: URL) throws {
        _ = try relativePath(phase: manifest.phase)
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile).project
        guard manifest.schema == DerivedIdentityAssetManifestV1.schemaVersion,
              manifest.project == project, manifest.projectID == (try projectID(dataRoot: dataRoot)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for (path, entry) in manifest.entries {
            guard path == entry.destinationPath, entry.phase == manifest.phase,
                  try owningPhase(destination: path) == manifest.phase,
                  entry.sourcePath.hasPrefix("import/"),
                  entry.sourceSHA256 == entry.destinationSHA256,
                  let source = try ConfirmedIdentityAssetStoreV1.currentEntry(entry.sourcePath, dataRoot: dataRoot),
                  source.path == source.originalPath,
                  entry.sourceSHA256 == source.sha256,
                  entry.role == source.role, entry.identityName == source.identityName,
                  entry.identitySlug == source.identitySlug else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let sourceURL = try ProjectLocalFile.requireHash(entry.sourceSHA256, at: entry.sourcePath, dataRoot: dataRoot)
            let destinationURL = try ProjectLocalFile.requireHash(entry.destinationSHA256, at: path, dataRoot: dataRoot)
            guard sourceURL.standardizedFileURL == dataRoot.appendingPathComponent(entry.sourcePath).standardizedFileURL,
                  destinationURL.standardizedFileURL == dataRoot.appendingPathComponent(path).standardizedFileURL else {
                throw ProjectLocalFileError.invalidPath(path)
            }
        }
    }

    public static func save(_ manifest: DerivedIdentityAssetManifestV1, dataRoot: URL) throws {
        try validate(manifest, dataRoot: dataRoot)
        let path = try relativePath(phase: manifest.phase)
        _ = try ProjectLocalFile.ensureDirectory(manifest.phase, dataRoot: dataRoot)
        let url = dataRoot.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            _ = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
        }
        try JSONArtifactStore(dataRoot: dataRoot).save(manifest, to: path)
    }

    @discardableResult
    public static func record(phase: String, from sourcePath: String, to destinationPath: String, dataRoot: URL) throws -> Bool {
        _ = try relativePath(phase: phase)
        guard try owningPhase(destination: destinationPath) == phase else {
            throw ProjectLocalFileError.invalidPath(destinationPath)
        }
        let confirmed = try ConfirmedIdentityAssetStoreV1.load(dataRoot: dataRoot)
        guard confirmed.entries[sourcePath] != nil else { return false }
        guard sourcePath.hasPrefix("import/") else { throw ProjectLocalFileError.invalidPath(sourcePath) }
        guard let source = try ConfirmedIdentityAssetStoreV1.currentEntry(sourcePath, dataRoot: dataRoot) else {
            throw GateBlocked("The confirmed source image changed after intake.")
        }
        guard source.path == source.originalPath else { throw CocoaError(.fileReadCorruptFile) }
        _ = try ProjectLocalFile.requireHash(source.sha256, at: destinationPath, dataRoot: dataRoot)
        var manifest = try load(phase: phase, dataRoot: dataRoot)
        try validate(manifest, dataRoot: dataRoot)
        let entry = DerivedIdentityAssetV1(phase: phase, source: source, destinationPath: destinationPath)
        if let existing = manifest.entries[destinationPath], existing != entry {
            throw GateBlocked("The phase identity destination already belongs to another confirmed import.")
        }
        manifest.entries[destinationPath] = entry
        try save(manifest, dataRoot: dataRoot)
        return true
    }

    public static func matchesCurrent(_ path: String, role: ConfirmedIdentityAssetRoleV1, identityID: String, identityName: String, dataRoot: URL) throws -> Bool {
        if try ConfirmedIdentityAssetStoreV1.matchesCurrent(path, role: role, identityID: identityID, identityName: identityName, dataRoot: dataRoot) { return true }
        if path.hasPrefix("import/") { return false }
        let phase = try owningPhase(destination: path)
        let manifest = try load(phase: phase, dataRoot: dataRoot)
        try validate(manifest, dataRoot: dataRoot)
        guard let entry = manifest.entries[path], entry.role == role else { return false }
        return try ConfirmedIdentityAssetStoreV1.matchesCurrent(entry.sourcePath, role: role, identityID: identityID, identityName: identityName, dataRoot: dataRoot)
    }
}
