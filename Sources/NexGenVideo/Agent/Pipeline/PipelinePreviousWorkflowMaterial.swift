import Foundation
import ImageIO
import NexGenEngine

enum PreviousWorkflowMaterialRole: String, Codable, Equatable, Hashable, Sendable {
    case script, character, location
}

struct PreviousWorkflowMaterialScope: Codable, Equatable, Hashable, Sendable {
    let projectID: String
    let workingRoot: URL
    let workingCopyKey: String
    let workingCopyGeneration: UUID
    let dialogID: String
    let role: PreviousWorkflowMaterialRole
}

struct PreviousWorkflowMaterialSelection: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let relativePath: String
        let sha256: String
    }
    let materialID: String
    let historyFingerprint: String
    let role: PreviousWorkflowMaterialRole
    let scope: PreviousWorkflowMaterialScope
    let expectedFiles: [File]
    let displayName: String
}

struct PreviousWorkflowMaterial: Identifiable, Equatable, Sendable {
    enum Preview: Equatable, Sendable {
        case text(String)
        case image(Data)
    }
    let id: String
    let displayName: String
    let subline: String
    let identityName: String?
    let role: PreviousWorkflowMaterialRole
    let selection: PreviousWorkflowMaterialSelection
    let preview: Preview
}

struct PreviousWorkflowMaterialCatalog: Sendable {
    let items: [PreviousWorkflowMaterial]
    let unavailableCount: Int
}

enum PipelinePreviousWorkflowMaterial {
    private struct Subject {
        let role: PreviousWorkflowMaterialRole
        let slug: String
        let name: String
        var paths: [String]
        var sourceIDs: Set<String> = []
    }

    static func load(scope: PreviousWorkflowMaterialScope) throws -> PreviousWorkflowMaterialCatalog {
        try Task.checkCancellation()
        guard ProjectIdentity.existingUUID(for: scope.workingRoot) == scope.projectID,
              let root = DataRootResolver.dataRoot(of: scope.workingRoot),
              root.standardizedFileURL == scope.workingRoot.appendingPathComponent(DataRootResolver.pipelineDirname).standardizedFileURL else {
            throw changed()
        }
        let histories = try ProductionWorkflowRecoveryMigration.readCommittedHistories(staging: scope.workingRoot)
        let confirmed: Set<String>
        if scope.role == .script { confirmed = [] }
        else { confirmed = try currentSubjects(dataRoot: root) }
        var items: [PreviousWorkflowMaterial] = []
        var unavailable = 0
        for history in histories {
            try Task.checkCancellation()
            let intent = history.intent
            let prefix = "migration-history/" + intent.fingerprint + "/"
            let archive = root.appendingPathComponent(prefix + DataRootResolver.pipelineDirname)
            if scope.role == .script {
                let treatment = "pipeline/treatment/current.md"
                let versions = intent.archivePaths.filter { $0.hasPrefix("pipeline/treatment/v") && $0.hasSuffix(".md") }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                let path = intent.archivePaths.contains(treatment) ? treatment
                    : versions.last ?? intent.files.first(where: { $0.path == "pipeline/import/script.md" })?.path
                guard let path else {
                    if intent.archivePaths.contains(where: { $0.hasPrefix("pipeline/treatment/") || $0.hasPrefix("pipeline/script/") }) { unavailable += 1 }
                    continue
                }
                do {
                    let file = try sourceFile(path, history: history)
                    let bytes = try verifiedBytes(file, scope: scope)
                    guard ["md", "txt", "markdown"].contains((path as NSString).pathExtension.lowercased()),
                          let text = String(data: bytes, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        unavailable += 1
                        continue
                    }
                    let name: String
                    let preview: String
                    if path.hasPrefix("pipeline/treatment/") {
                        let treatment = try Treatment.parsing(text)
                        guard treatment.meta.schema == treatmentSchemaVersion else { throw changed() }
                        let title = treatment.meta.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        name = title.isEmpty ? "Previous treatment" : title
                        preview = treatment.bodyMarkdown
                    } else {
                        name = (path as NSString).lastPathComponent
                        preview = text
                    }
                    items.append(material(scope: scope, history: intent.fingerprint, key: path, name: name,
                        identityName: nil, files: [file], preview: .text(preview)))
                } catch is CancellationError { throw CancellationError() }
                catch { unavailable += 1 }
                continue
            }
            var subjects: [String: Subject] = [:]
            var invalidSubjects: Set<String> = []
            var intake: ConfirmedIdentityAssetManifestV1?
            var adoptions: ConfirmedIdentityAdoptionManifestV1?
            let manifestPath = DataRootResolver.pipelineDirname + "/" + PipelineLayout.confirmedIdentityAssetsFile
            if intent.archivePaths.contains(manifestPath) {
                let manifest = try JSONArtifactStore(dataRoot: archive).load(ConfirmedIdentityAssetManifestV1.self,
                    at: PipelineLayout.confirmedIdentityAssetsFile)
                guard manifest.schema == ConfirmedIdentityAssetManifestV1.schemaVersion,
                      manifest.project == FrameInventory.projectName(of: root) else { throw changed() }
                intake = manifest
                for entry in manifest.entries.values {
                    let role: PreviousWorkflowMaterialRole = entry.role == .character ? .character : .location
                    guard role == scope.role else { continue }
                    let key = "confirmation:" + role.rawValue + ":" + entry.identitySlug
                    guard intent.files.contains(where: { $0.path == "pipeline/" + entry.originalPath && $0.sha256 == entry.originalSHA256 }) else {
                        invalidSubjects.insert(key)
                        continue
                    }
                    if subjects[key] == nil { subjects[key] = Subject(role: role, slug: entry.identitySlug, name: entry.identityName, paths: []) }
                    subjects[key]?.paths.append(entry.originalPath)
                    subjects[key]?.sourceIDs.insert("confirmation:" + entry.id)
                }
            }
            let adoptionPath = DataRootResolver.pipelineDirname + "/" + PipelineLayout.confirmedIdentityAdoptionsFile
            if intent.archivePaths.contains(adoptionPath) {
                let stored = try JSONArtifactStore(dataRoot: archive).load(ConfirmedIdentityAdoptionManifestV1.self,
                    at: PipelineLayout.confirmedIdentityAdoptionsFile)
                guard stored.schema == ConfirmedIdentityAdoptionManifestV1.schemaVersion,
                      stored.project == FrameInventory.projectName(of: root) else { throw changed() }
                adoptions = stored
            }
            let biblePath = DataRootResolver.pipelineDirname + "/" + PipelineLayout.bibleFile
            if intent.archivePaths.contains(biblePath) {
                do {
                    let bible = try YAMLArtifactStore(dataRoot: archive).load(Bible.self, at: PipelineLayout.bibleFile)
                    let declared: [Subject] = scope.role == .character
                        ? bible.characters.map { Subject(role: .character, slug: $0.id, name: $0.name, paths: $0.referenceImages + $0.sheets.values.sorted()) }
                        : bible.locations.map { Subject(role: .location, slug: $0.id, name: $0.name, paths: $0.referenceImages + $0.sheets.values.sorted()) }
                    for subject in declared {
                        let bibleID = "bible:" + subject.role.rawValue + ":" + subject.slug
                        if let bound = try confirmedSubject(for: subject, intake: intake, adoptions: adoptions,
                            history: history, scope: scope), subjects[bound.key] != nil {
                            subjects[bound.key]?.paths.append(contentsOf: bound.paths)
                            subjects[bound.key]?.sourceIDs.insert(bibleID)
                        } else {
                            var distinct = subject
                            distinct.sourceIDs = [bibleID]
                            subjects[bibleID] = distinct
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { unavailable += 1 }
            }
            for key in subjects.keys.sorted() {
                try Task.checkCancellation()
                guard let subject = subjects[key] else { continue }
                let proposedKey = subject.role.rawValue + ":" + AgentService.identitySlug(subject.name)
                guard !confirmed.contains(proposedKey) else { continue }
                do {
                    guard !invalidSubjects.contains(key) else { throw changed() }
                    let paths = Array(Set(subject.paths)).sorted()
                    guard !paths.isEmpty, !subject.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw changed() }
                    let files = try paths.map { path -> PreviousWorkflowMaterialSelection.File in
                        guard ProjectMediaExtensions.images.contains((path as NSString).pathExtension.lowercased()) else { throw changed() }
                        return try sourceFile(DataRootResolver.pipelineDirname + "/" + path, history: history)
                    }
                    var first: Data?
                    for file in files {
                        let bytes = try verifiedBytes(file, scope: scope)
                        guard let image = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(image) > 0 else { throw changed() }
                        if first == nil { first = bytes }
                    }
                    guard let first else { throw changed() }
                    items.append(material(scope: scope, history: intent.fingerprint, key: subject.sourceIDs.sorted().joined(separator: "\n"), name: subject.name,
                        identityName: subject.name, files: files, preview: .image(first)))
                } catch is CancellationError { throw CancellationError() }
                catch { unavailable += 1 }
            }
            unavailable += invalidSubjects.subtracting(subjects.keys).count
        }
        return .init(items: items, unavailableCount: unavailable)
    }

    private static func confirmedSubject(for subject: Subject, intake: ConfirmedIdentityAssetManifestV1?,
                                         adoptions: ConfirmedIdentityAdoptionManifestV1?,
                                         history: ProductionWorkflowRecoveryMigration.History,
                                         scope: PreviousWorkflowMaterialScope) throws -> (key: String, paths: [String])? {
        guard let intake else { return nil }
        var keys: Set<String> = []
        var paths = Set(subject.paths)
        for path in subject.paths {
            guard let source = boundSource(path: path, intake: intake, adoptions: adoptions),
                  source.role.rawValue == subject.role.rawValue,
                  !normalizedIdentity(source.identitySlug).isEmpty,
                  normalizedIdentity(source.identitySlug) == normalizedIdentity(subject.slug),
                  source.identityName.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(subject.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else { continue }
            do {
                let original = try sourceFile("pipeline/" + source.originalPath, history: history)
                let target = try sourceFile("pipeline/" + path, history: history)
                guard original.sha256 == source.originalSHA256, target.sha256 == source.sha256 else { continue }
                _ = try verifiedBytes(original, scope: scope)
                _ = try verifiedBytes(target, scope: scope)
                keys.insert("confirmation:" + subject.role.rawValue + ":" + source.identitySlug)
                paths.remove(path)
                paths.insert(source.originalPath)
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        guard keys.count == 1, let key = keys.first else { return nil }
        return (key, paths.sorted())
    }

    private static func boundSource(path: String, intake: ConfirmedIdentityAssetManifestV1,
                                    adoptions: ConfirmedIdentityAdoptionManifestV1?) -> ConfirmedIdentityAssetV1? {
        if let direct = intake.entries[path], !direct.id.isEmpty, direct.path == path, direct.originalPath == path,
           direct.sha256 == direct.originalSHA256 { return direct }
        if let proof = adoptions?.entries[path], let source = intake.entries[proof.sourcePath],
           !source.id.isEmpty, source.path == source.originalPath, source.sha256 == source.originalSHA256,
           proof.sourceConfirmationID == source.id, proof.role == source.role,
           proof.identityName == source.identityName, proof.identitySlug == source.identitySlug,
           proof.sourcePath == source.path, proof.sourceSHA256 == source.sha256,
           proof.originalPath == source.originalPath, proof.originalSHA256 == source.originalSHA256,
           proof.confirmedAt == source.confirmedAt, proof.targetPath == path, path.hasPrefix("bible/"),
           proof.targetSHA256 == source.sha256,
           proof.id == "confirmed-identity-adoption-" + FileDigest.sha256(of: Data((source.id + "\n" + path + "\n" + proof.targetSHA256).utf8)) {
            return source
        }
        if let legacy = intake.entries[path], let source = intake.entries[legacy.originalPath],
           !source.id.isEmpty, source.path == legacy.originalPath, source.path == source.originalPath, source.sha256 == source.originalSHA256,
           legacy.path == path, path.hasPrefix("bible/"), legacy.path != legacy.originalPath,
           legacy.role == source.role, legacy.identityName == source.identityName,
           legacy.identitySlug == source.identitySlug, legacy.sha256 == source.sha256,
           legacy.originalSHA256 == source.originalSHA256, legacy.confirmedAt == source.confirmedAt,
           legacy.id == "confirmed-identity-" + FileDigest.sha256(of: Data((source.id + "\n" + path + "\n" + legacy.sha256).utf8)) {
            return source
        }
        return nil
    }

    private static func normalizedIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
    }

    static func resolve(_ selection: PreviousWorkflowMaterialSelection,
                        scope: PreviousWorkflowMaterialScope) throws -> PreviousWorkflowMaterial {
        guard selection.scope == scope, selection.role == scope.role,
              let material = try load(scope: scope).items.first(where: { $0.id == selection.materialID }),
              material.selection.historyFingerprint == selection.historyFingerprint,
              material.selection.expectedFiles == selection.expectedFiles else { throw changed() }
        return material
    }

    static func verifiedURLs(_ selection: PreviousWorkflowMaterialSelection) throws -> [URL] {
        try selection.expectedFiles.map { file in
            _ = try verifiedBytes(file, scope: selection.scope)
            return try ProjectLocalFile.requireHash(file.sha256, at: file.relativePath, dataRoot: selection.scope.workingRoot)
        }
    }

    static func verifiedBytes(_ file: PreviousWorkflowMaterialSelection.File, scope: PreviousWorkflowMaterialScope) throws -> Data {
        try Task.checkCancellation()
        let url = try ProjectLocalFile.resolve(file.relativePath, dataRoot: scope.workingRoot)
        guard url.standardizedFileURL == scope.workingRoot.appendingPathComponent(file.relativePath).standardizedFileURL else { throw changed() }
        let bytes = try Data(contentsOf: url)
        guard FileDigest.sha256(of: bytes) == file.sha256 else { throw changed() }
        return bytes
    }

    private static func sourceFile(_ path: String, history: ProductionWorkflowRecoveryMigration.History) throws -> PreviousWorkflowMaterialSelection.File {
        guard let original = history.intent.files.first(where: { $0.path == path }) else { throw changed() }
        let relative = history.intent.archivePaths.contains(path)
            ? "pipeline/migration-history/" + history.intent.fingerprint + "/" + path : path
        return .init(relativePath: relative, sha256: original.sha256)
    }

    private static func currentSubjects(dataRoot: URL) throws -> Set<String> {
        let manifest = try ConfirmedIdentityAssetStoreV1.load(dataRoot: dataRoot)
        let adoptions = try ConfirmedIdentityAssetStoreV1.loadAdoptions(dataRoot: dataRoot)
        guard manifest.schema == ConfirmedIdentityAssetManifestV1.schemaVersion,
              manifest.project == FrameInventory.projectName(of: dataRoot) else { throw changed() }
        var result: Set<String> = []
        for path in Set(manifest.entries.keys).union(adoptions.entries.keys) {
            try Task.checkCancellation()
            do {
                if let entry = try ConfirmedIdentityAssetStoreV1.currentEntry(path, dataRoot: dataRoot) {
                    result.insert(entry.role.rawValue + ":" + entry.identitySlug)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return result
    }

    private static func material(scope: PreviousWorkflowMaterialScope, history: String, key: String, name: String,
                                 identityName: String?, files: [PreviousWorkflowMaterialSelection.File],
                                 preview: PreviousWorkflowMaterial.Preview) -> PreviousWorkflowMaterial {
        let id = FileDigest.sha256(of: Data((history + "\n" + scope.role.rawValue + "\n" + key).utf8))
        let selection = PreviousWorkflowMaterialSelection(materialID: id, historyFingerprint: history, role: scope.role,
            scope: scope, expectedFiles: files, displayName: name)
        return .init(id: id, displayName: name, subline: identityName == nil ? "Previous workflow · Story" : "Previous workflow · \(files.count) reference image\(files.count == 1 ? "" : "s")",
            identityName: identityName, role: scope.role, selection: selection, preview: preview)
    }

    static func changed() -> ToolError {
        ToolError("The previous workflow material changed or is unavailable. Choose it again or attach another source.")
    }
}
