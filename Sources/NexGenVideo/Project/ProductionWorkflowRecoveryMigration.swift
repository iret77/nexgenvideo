import Foundation
import NexGenEngine

@MainActor
enum ProductionWorkflowRecoveryMigration {
    enum Source: Codable, Equatable, Sendable {
        case pack(ProjectPackBinding)
        case legacyPack(String)
        case core
    }

    enum Target: Codable, Equatable, Sendable {
        case pack(ProjectPackBinding)
        case core
    }

    struct File: Codable, Equatable, Sendable {
        let path: String
        let sha256: String
    }

    struct StartupProof: Codable, Equatable, Sendable {
        let phase: String
        let gate: Gate
        let inputFingerprint: String
        let artifactFingerprint: String
    }

    struct Intent: Codable, Equatable, Sendable {
        let projectName: String
        let source: Source
        let target: Target
        let files: [File]
        let savedFiles: [File]
        let archivePaths: [String]
        let startupProofs: [StartupProof]
        let namespaceID: String
        let fingerprint: String

        var explanation: String {
            "Brief and every later production approval will reset. Existing story material must be confirmed again; Script, Storyboard sketches, timing and production planning start as new proposals. "
                + "The current timeline, imported files, historical Takes, generated media and their paths stay intact. "
                + "Project Init and Audio Analysis are retained only when their original evidence and the new workflow checks both pass. The saved project changes only on Save."
        }
    }

    struct History: Codable, Equatable, Sendable {
        let schema: String
        let intent: Intent
        let retainedStartupPhases: [String]
        let completed: Bool
    }

    struct OutputNamespace: Codable, Equatable, Sendable {
        nonisolated static let relativePath = "production-output-namespace.v1.json"
        let schema: String
        let id: String
        let sourceFingerprint: String
        let protectedPaths: [String]
    }

    enum MigrationError: LocalizedError {
        case changedSource
        case invalidSource
        case invalidArchive
        case confirmationRequired

        var errorDescription: String? {
            switch self {
            case .changedSource: "The project changed after the upgrade preview. Review the upgrade again."
            case .invalidSource: "The production workflow cannot be upgraded from these project settings."
            case .invalidArchive: "The production history or retained project bytes failed verification."
            case .confirmationRequired: "Review and confirm the production approval reset before upgrading."
            }
        }
    }

    nonisolated static func isProductionTarget(_ target: ProjectPackBinding) -> Bool {
        target.id == "musicvideo" && target.version == HostWorkflowKey.musicvideoV2Version
            && target.projectSchema == HostWorkflowKey.musicvideoV2Schema
    }

    static func preview(projectURL: URL, sourceRoot: URL? = nil, source: Source, target: Target) throws -> Intent {
        let root = sourceRoot ?? projectURL
        try requireBinding(source, at: root)
        let files = try inventory(root)
        let saved = try inventory(projectURL)
        let paths = files.map(\.path).filter(isCanonicalPlanningMetadata)
        let proofs = try startupProofs(source: source, root: root)
        let name = projectURL.deletingPathExtension().lastPathComponent
        let namespaceID = UUID().uuidString.lowercased()
        let identity = try encode(PreviewIdentity(namespaceID: namespaceID, projectName: name, source: source, target: target, files: files, savedFiles: saved,
                                                  archivePaths: paths, startupProofs: proofs))
        let result = Intent(projectName: name, source: source, target: target, files: files, savedFiles: saved, archivePaths: paths,
                      startupProofs: proofs, namespaceID: namespaceID, fingerprint: FileDigest.sha256(of: identity))
        try requireSourceCurrent(result, root: root)
        try requireSavedSource(result, projectURL: projectURL)
        return result
    }

    nonisolated static func requireSavedSource(_ intent: Intent, projectURL: URL) throws {
        guard try inventory(projectURL) == intent.savedFiles else { throw MigrationError.changedSource }
    }

    static func requireSourceCurrent(_ intent: Intent, root: URL) throws {
        try requireBinding(intent.source, at: root)
        guard try inventory(root) == intent.files else { throw MigrationError.changedSource }
    }

    static func initializeOutputNamespace(dataRoot: URL, workflow: HostWorkflowKey) throws {
        guard workflow.isProductionV2 else { throw MigrationError.invalidSource }
        let home = FrameInventory.projectHome(of: dataRoot)
        let expectedPack = workflow.packID.flatMap { id in workflow.packVersion.flatMap {
            ProjectPackBinding(id: id, version: $0, projectSchema: workflow.projectSchema)
        } }
        guard try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot, expectedPack: expectedPack,
            expectedProductionContract: workflow.packID == nil ? .current : nil) == workflow else { throw MigrationError.invalidSource }
        let url = dataRoot.appendingPathComponent(OutputNamespace.relativePath)
        if FileManager.default.fileExists(atPath: url.path) { _ = try outputNamespace(dataRoot: dataRoot); return }
        let namespace = OutputNamespace(schema: "production-output-namespace/v1", id: UUID().uuidString.lowercased(),
            sourceFingerprint: "", protectedPaths: try inventory(home).map(\.path))
        try JSONArtifactStore(dataRoot: dataRoot).save(namespace, to: OutputNamespace.relativePath)
    }

    nonisolated static func outputPath(area: String, leaf: String, dataRoot: URL) throws -> String {
        guard outputAreas.contains(area), validRelativePath(leaf) else { throw MigrationError.invalidArchive }
        let namespace = try outputNamespace(dataRoot: dataRoot)
        let path = area + "/" + namespace.id + "/" + leaf
        try requireNewOutput(path, dataRoot: dataRoot)
        return path
    }

    static func requireOutputNamespace(dataRoot: URL) throws {
        _ = try outputNamespace(dataRoot: dataRoot)
    }

    nonisolated static func requireNewOutput(_ path: String, dataRoot: URL) throws {
        let namespace = try outputNamespace(dataRoot: dataRoot)
        guard validRelativePath(path), outputAreas.contains(where: { path.hasPrefix($0 + "/" + namespace.id + "/") }),
              !namespace.protectedPaths.contains(DataRootResolver.pipelineDirname + "/" + path) else { throw MigrationError.invalidArchive }
        let destination = dataRoot.appendingPathComponent(path).standardizedFileURL
        guard destination.resolvingSymlinksInPath() == destination,
              !FileManager.default.fileExists(atPath: destination.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil else { throw MigrationError.invalidArchive }
    }

    nonisolated private static let outputAreas = ["production_design/refs", "production_design/lighting", "storyboard/sketches",
                                      "bible", "frames", "renders", "execution/resources", "execution/blockout"]

    nonisolated private static func outputNamespace(dataRoot: URL) throws -> OutputNamespace {
        let namespace = try JSONDecoder().decode(OutputNamespace.self,
            from: Data(contentsOf: ProjectLocalFile.resolve(OutputNamespace.relativePath, dataRoot: dataRoot)))
        guard namespace.schema == "production-output-namespace/v1", let id = UUID(uuidString: namespace.id),
              id.uuidString.lowercased() == namespace.id, namespace.protectedPaths.allSatisfy(validRelativePath) else {
            throw MigrationError.invalidArchive
        }
        if !namespace.sourceFingerprint.isEmpty {
            let path = "migration-history/" + namespace.sourceFingerprint + "/manifest.v1.json"
            let history = try JSONDecoder().decode(History.self, from: Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
            guard history.completed, history.schema == "production-workflow-migration/v1",
                  history.intent.fingerprint == namespace.sourceFingerprint && history.intent.namespaceID == namespace.id,
                  namespace.protectedPaths == history.intent.files.filter({ !history.intent.archivePaths.contains($0.path) }).map(\.path) else {
                throw MigrationError.invalidArchive
            }
        }
        return namespace
    }

    nonisolated private static func validRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\")
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func archiveAndReset(_ intent: Intent, staging: URL) throws {
        try requireBinding(intent.source, at: staging)
        guard try inventory(staging) == intent.files, UUID(uuidString: intent.namespaceID) != nil,
              try FileDigest.sha256(of: encode(PreviewIdentity(namespaceID: intent.namespaceID, projectName: intent.projectName, source: intent.source, target: intent.target,
                files: intent.files, savedFiles: intent.savedFiles, archivePaths: intent.archivePaths,
                startupProofs: intent.startupProofs))) == intent.fingerprint else { throw MigrationError.changedSource }
        let dataRoot: URL
        if let existing = DataRootResolver.dataRoot(of: staging) {
            guard existing.standardizedFileURL == staging.appendingPathComponent(DataRootResolver.pipelineDirname).standardizedFileURL else {
                throw MigrationError.invalidSource
            }
            dataRoot = existing
        } else {
            guard intent.source == .core else { throw MigrationError.invalidSource }
            dataRoot = try ProjectScaffold.initProject(home: staging, name: intent.projectName,
                                                      mode: .generic)
        }
        let archiveRoot = try ProjectLocalFile.ensureDirectory("migration-history/" + intent.fingerprint, dataRoot: dataRoot)
        for path in intent.archivePaths {
            guard let original = intent.files.first(where: { $0.path == path }) else { throw MigrationError.invalidArchive }
            let source = staging.appendingPathComponent(path)
            guard try exactDigest(source) == original.sha256 else { throw MigrationError.changedSource }
            let destination = archiveRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw MigrationError.invalidArchive }
            if path == ProjectPluginSettings.filename { try FileManager.default.copyItem(at: source, to: destination) }
            else { try FileManager.default.moveItem(at: source, to: destination) }
            guard try exactDigest(destination) == original.sha256 else { throw MigrationError.invalidArchive }
        }
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        let phases: [String]
        switch intent.target {
        case .pack: phases = ProductionWorkflowV2.musicvideoPhases
        case .core: phases = ProductionWorkflowV2.corePhases
        }
        try YAMLArtifactStore(dataRoot: dataRoot).save(
            Gates(project: project.project, gates: Dictionary(uniqueKeysWithValues: phases.map { ($0, Gate()) })),
            to: PipelineLayout.gatesFile)
        try JSONArtifactStore(dataRoot: dataRoot).save(PipelineLineage(project: project.project), to: PipelineLayout.lineageFile)
        let namespace = OutputNamespace(schema: "production-output-namespace/v1", id: intent.namespaceID,
            sourceFingerprint: intent.fingerprint, protectedPaths: intent.files.filter { !intent.archivePaths.contains($0.path) }.map(\.path))
        try JSONArtifactStore(dataRoot: dataRoot).save(namespace, to: OutputNamespace.relativePath)
        try encode(History(schema: "production-workflow-migration/v1", intent: intent, retainedStartupPhases: [], completed: false))
            .write(to: archiveRoot.appendingPathComponent("manifest.v1.json"), options: .atomic)
    }

    static func finish(_ intent: Intent, staging: URL, saveGates: (Gates, URL) throws -> Void = { gates, root in
        try YAMLArtifactStore(dataRoot: root).save(gates, to: PipelineLayout.gatesFile)
    }) throws {
        let root = try dataRoot(staging)
        let workflow: HostWorkflowKey
        switch intent.target {
        case .pack(let target):
            guard ProjectPluginSettings.bindingResolution(projectURL: staging) == .bound(target),
                  let contract = try PhaseContractRuntime.contract(activePack: target.id) else { throw MigrationError.invalidSource }
            workflow = try HostWorkflowKey.resolve(binding: target, contract: contract)
        case .core:
            guard ProjectPluginSettings.productionContractResolution(projectURL: staging) == .bound(.current) else {
                throw MigrationError.invalidSource
            }
            workflow = try .core(.current)
        }
        let contract = try PhaseContractRuntime.contract(workflow: workflow)
        let registry = PackCatalog.registry(activePack: workflow.packID)
        var gates = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
        var retained: [String] = []
        for phase in contract.order.prefix(while: { $0 == "project_init" || $0 == "analysis" }) {
            guard let original = intent.startupProofs.first(where: { $0.phase == phase }),
                  let declaration = contract.phase(phase), let provider = declaration.nativeLineageProvider else { break }
            let previousLineage = try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.lineageFile, dataRoot: root))
            do {
                let snapshot = try provider(root)
                guard snapshot.inputFingerprint == original.inputFingerprint,
                      snapshot.artifactFingerprint == original.artifactFingerprint else {
                    throw MigrationError.changedSource
                }
                try PipelineLineageStore.record(phase: phase, snapshot: snapshot, dataRoot: root)
                guard let requirement = try PhaseContractRuntime.gateRequirement(workflow: workflow, phase: phase, registry: registry) else {
                    throw MigrationError.invalidArchive
                }
                try requirement(root)
                var candidate = gates
                candidate.set(phase, original.gate)
                try saveGates(candidate, root)
                gates = candidate
                retained.append(phase)
            } catch {
                try previousLineage.write(to: root.appendingPathComponent(PipelineLayout.lineageFile), options: .atomic)
                break
            }
        }
        try saveGates(gates, root)
        let archive = root.appendingPathComponent("migration-history/" + intent.fingerprint)
        try encode(History(schema: "production-workflow-migration/v1", intent: intent, retainedStartupPhases: retained, completed: true))
            .write(to: archive.appendingPathComponent("manifest.v1.json"), options: .atomic)
        try requireCompleted(intent, staging: staging)
    }

    nonisolated static func requireCompleted(_ intent: Intent, staging: URL) throws {
        let root = try dataRoot(staging)
        let archive = root.appendingPathComponent("migration-history/" + intent.fingerprint)
        let history = try JSONDecoder().decode(History.self, from: Data(contentsOf: archive.appendingPathComponent("manifest.v1.json")))
        try requireCommittedHistory(intent, staging: staging)
        let replaceable = Set(["pipeline/" + PipelineLayout.gatesFile, "pipeline/" + PipelineLayout.lineageFile, ProjectPluginSettings.filename])
        try ProductionMigrationPreflight.perform { control in
            for (index, original) in intent.files.enumerated() {
                let archived = intent.archivePaths.contains(original.path)
                let url = archived ? archive.appendingPathComponent(original.path) : staging.appendingPathComponent(original.path)
                if !archived, replaceable.contains(original.path) { continue }
                guard try control.digest(url) == original.sha256 else { throw MigrationError.invalidArchive }
                if archived, !replaceable.contains(original.path),
                   FileManager.default.fileExists(atPath: staging.appendingPathComponent(original.path).path) { throw MigrationError.invalidArchive }
                control.progress(index + 1, intent.files.count)
            }
        }
        let gates = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
        let expectedPhases: [String]
        switch intent.target {
        case .pack(let target):
            guard ProjectPluginSettings.bindingResolution(projectURL: staging) == .bound(target),
                  ProjectPluginSettings.productionContractResolution(projectURL: staging) == .absent else { throw MigrationError.invalidArchive }
            expectedPhases = ProductionWorkflowV2.musicvideoPhases
        case .core:
            guard ProjectPluginSettings.bindingResolution(projectURL: staging) == .absent,
                  ProjectPluginSettings.productionContractResolution(projectURL: staging) == .bound(.current) else { throw MigrationError.invalidArchive }
            expectedPhases = ProductionWorkflowV2.corePhases
        }
        let lineage = try PipelineLineageStore.loadIfPresent(dataRoot: root)
        guard gates.gates.filter({ $0.value.approved }).keys.sorted() == history.retainedStartupPhases.sorted(),
              Set(gates.gates.keys) == Set(expectedPhases),
              Set(lineage?.phases.keys.map { $0 } ?? []) == Set(history.retainedStartupPhases),
              history.retainedStartupPhases.allSatisfy({ ["project_init", "analysis"].contains($0) }) else { throw MigrationError.invalidArchive }
        let namespace = try JSONArtifactStore(dataRoot: root).load(OutputNamespace.self, at: OutputNamespace.relativePath)
        guard namespace.schema == "production-output-namespace/v1", namespace.id == intent.namespaceID,
              namespace.sourceFingerprint == intent.fingerprint,
              namespace.protectedPaths == intent.files.filter({ !intent.archivePaths.contains($0.path) }).map(\.path) else {
            throw MigrationError.invalidArchive
        }
    }

    nonisolated static func requireCommittedHistory(_ intent: Intent, staging: URL) throws {
        let root = try dataRoot(staging)
        let historyPath = "migration-history/" + intent.fingerprint + "/manifest.v1.json"
        let history = try JSONDecoder().decode(History.self,
            from: Data(contentsOf: ProjectLocalFile.resolve(historyPath, dataRoot: root)))
        guard history.intent == intent else { throw MigrationError.invalidArchive }
        try requireHistoryArchive(history, staging: staging)
        let namespace = try JSONDecoder().decode(OutputNamespace.self,
            from: Data(contentsOf: ProjectLocalFile.resolve(OutputNamespace.relativePath, dataRoot: root)))
        guard namespace.id == intent.namespaceID && namespace.sourceFingerprint == intent.fingerprint,
              namespace.protectedPaths == intent.files.filter({ !intent.archivePaths.contains($0.path) }).map(\.path) else {
            throw MigrationError.invalidArchive
        }
    }

    nonisolated static func readCommittedHistories(staging: URL) throws -> [History] {
        let root = try dataRoot(staging)
        let directory = root.appendingPathComponent("migration-history")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard directory.resolvingSymlinksInPath() == directory.standardizedFileURL else { throw MigrationError.invalidArchive }
        var result: [History] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let manifest = "migration-history/" + url.lastPathComponent + "/manifest.v1.json"
            let history = try JSONDecoder().decode(History.self,
                from: Data(contentsOf: ProjectLocalFile.resolve(manifest, dataRoot: root)))
            guard url.lastPathComponent == history.intent.fingerprint else { throw MigrationError.invalidArchive }
            try requireHistoryArchive(history, staging: staging)
            result.append(history)
        }
        return result.sorted { $0.intent.fingerprint < $1.intent.fingerprint }
    }

    nonisolated static func requireHistoryArchive(_ history: History, staging: URL) throws {
        let intent = history.intent
        let root = try dataRoot(staging)
        let identity = PreviewIdentity(namespaceID: intent.namespaceID, projectName: intent.projectName, source: intent.source, target: intent.target,
            files: intent.files, savedFiles: intent.savedFiles, archivePaths: intent.archivePaths, startupProofs: intent.startupProofs)
        guard history.schema == "production-workflow-migration/v1", history.completed,
              FileDigest.sha256(of: try encode(identity)) == intent.fingerprint,
              UUID(uuidString: intent.namespaceID) != nil,
              Set(intent.files.map(\.path)).count == intent.files.count,
              Set(intent.archivePaths).count == intent.archivePaths.count,
              intent.files.allSatisfy({ validRelativePath($0.path) }),
              intent.archivePaths.allSatisfy(validRelativePath) else { throw MigrationError.invalidArchive }
        for path in intent.archivePaths {
            guard let original = intent.files.first(where: { $0.path == path }) else { throw MigrationError.invalidArchive }
            _ = try ProjectLocalFile.requireHash(original.sha256, at: "migration-history/" + intent.fingerprint + "/" + path,
                                                 dataRoot: root)
        }
        guard let projectID = ProjectIdentity.existingUUID(for: staging), intent.archivePaths.contains(ProjectPluginSettings.filename) else {
            throw MigrationError.invalidArchive
        }
        let archivedSettings = try Data(contentsOf: ProjectLocalFile.resolve(
            "migration-history/" + intent.fingerprint + "/" + ProjectPluginSettings.filename, dataRoot: root))
        guard let settings = try JSONSerialization.jsonObject(with: archivedSettings) as? [String: Any],
              settings["id"] as? String == projectID else { throw MigrationError.invalidArchive }
    }

    nonisolated static func authorizesCoreRecovery(projectURL: URL, recoveryURL: URL) -> Bool {
        guard ProjectIdentity.existingKey(for: projectURL) == ProjectIdentity.existingKey(for: recoveryURL),
              ProjectIdentity.existingKey(for: projectURL) != nil,
              ProjectPluginSettings.bindingResolution(projectURL: projectURL) == .absent,
              ProjectPluginSettings.bindingResolution(projectURL: recoveryURL) == .absent,
              ProjectPluginSettings.productionContractResolution(projectURL: projectURL) == .absent,
              ProjectPluginSettings.productionContractResolution(projectURL: recoveryURL) == .bound(.current) else { return false }
        do {
            let root = try dataRoot(recoveryURL)
            let namespace = try JSONDecoder().decode(OutputNamespace.self,
                from: Data(contentsOf: ProjectLocalFile.resolve(OutputNamespace.relativePath, dataRoot: root)))
            guard namespace.sourceFingerprint.count == 64, namespace.sourceFingerprint.allSatisfy(\.isHexDigit) else { return false }
            let history = try JSONDecoder().decode(History.self, from: Data(contentsOf: ProjectLocalFile.resolve(
                "migration-history/" + namespace.sourceFingerprint + "/manifest.v1.json", dataRoot: root)))
            guard history.intent.source == .core && history.intent.target == .core else { return false }
            try requireSavedSource(history.intent, projectURL: projectURL)
            try requireCommittedHistory(history.intent, staging: recoveryURL)
            return true
        } catch { return false }
    }

    private struct PreviewIdentity: Codable, Sendable {
        let namespaceID: String
        let projectName: String
        let source: Source
        let target: Target
        let files: [File]
        let savedFiles: [File]
        let archivePaths: [String]
        let startupProofs: [StartupProof]
    }

    private static func startupProofs(source: Source, root: URL) throws -> [StartupProof] {
        guard case .pack(let binding) = source, PluginLoader.liveBinding(id: binding.id) == binding,
              let dataRoot = DataRootResolver.dataRoot(of: root),
              let contract = try PhaseContractRuntime.contract(activePack: binding.id), contract.packVersion == binding.version else { return [] }
        let registry = PackCatalog.registry(activePack: binding.id)
        let gates = try YAMLArtifactStore(dataRoot: dataRoot).load(Gates.self, at: PipelineLayout.gatesFile)
        var result: [StartupProof] = []
        for phase in contract.order.prefix(while: { $0 == "project_init" || $0 == "analysis" }) {
            guard gates.get(phase).approved, let declaration = contract.phase(phase),
                  let provider = declaration.nativeLineageProvider else { break }
            do {
                let steps = contract.hardSteps.steps(for: phase)
                guard IntakePlanner.pending(steps, dataRoot: dataRoot, ledger: IntakeLedger.load(dataRoot: dataRoot)).isEmpty else { break }
                if let gate = try PhaseContractRuntime.gateRequirement(activePack: binding.id, phase: phase, registry: registry) { try gate(dataRoot) }
                let snapshot = try provider(dataRoot)
                if declaration.nativeLineageRequiresRecord {
                    try PipelineLineageStore.requireCurrent(phase: phase, snapshot: snapshot, dataRoot: dataRoot)
                }
                result.append(.init(phase: phase, gate: gates.get(phase), inputFingerprint: snapshot.inputFingerprint,
                                    artifactFingerprint: snapshot.artifactFingerprint))
            } catch { break }
        }
        return result
    }

    private static func requireBinding(_ source: Source, at root: URL) throws {
        switch source {
        case .pack(let binding):
            guard ProjectPluginSettings.bindingResolution(projectURL: root) == .bound(binding) else { throw MigrationError.invalidSource }
        case .legacyPack(let id):
            guard ProjectPluginSettings.bindingResolution(projectURL: root) == .legacy(id) else { throw MigrationError.invalidSource }
        case .core:
            guard ProjectPluginSettings.bindingResolution(projectURL: root) == .absent,
                  ProjectPluginSettings.productionContractResolution(projectURL: root) == .absent else { throw MigrationError.invalidSource }
        }
    }

    nonisolated private static func inventory(_ root: URL) throws -> [File] {
        try ProductionMigrationPreflight.perform { control in
            let root = root.standardizedFileURL
            guard root.resolvingSymlinksInPath() == root else { throw MigrationError.invalidSource }
            var failure: Error?
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], errorHandler: { _, error in failure = error; return false }) else {
                throw MigrationError.invalidSource
            }
            var urls: [(URL, String)] = []
            for case let url as URL in enumerator {
                try control.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw MigrationError.invalidSource }
                guard values.isRegularFile == true else { continue }
                let path = String(url.path.dropFirst(root.path.count + 1))
                if !ProjectWorkingCopy.isPackageRuntimePath(path) { urls.append((url, path)) }
            }
            if let failure { throw failure }
            return try urls.sorted { $0.1 < $1.1 }.enumerated().map { index, file in
                let digest = try control.digest(file.0)
                control.progress(index + 1, urls.count)
                return File(path: file.1, sha256: digest)
            }
        }
    }

    private static func isCanonicalPlanningMetadata(_ path: String) -> Bool {
        if path == ProjectPluginSettings.filename { return true }
        guard path.hasPrefix("pipeline/") else { return false }
        let path = String(path.dropFirst("pipeline/".count))
        if [PipelineLayout.briefFile, PipelineLayout.gatesFile, PipelineLayout.lineageFile, PipelineLayout.ledgerFile,
            PipelineLayout.productionDesignFile, ResolvedProductionStyleV1.relativePath, PipelineLayout.bibleFile,
            PipelineLayout.confirmedIdentityAdoptionsFile, PipelineLayout.bibleIdentityVariantsFile,
            PipelineLayout.confirmedIdentityAssetsFile, PipelineLayout.framesManifestFile, PipelineLayout.sanityReportFile,
            "bible/provenance.json", "production_design/provenance.json"].contains(path) { return true }
        if ["brief/", "treatment/", "storyboard/", "script/", "shot-planning/", "shotlist/", "render-review/"].contains(where: path.hasPrefix) {
            return ["json", "yaml", "yml", "md"].contains((path as NSString).pathExtension)
                && !path.hasPrefix("storyboard/sketches/")
        }
        if path.hasPrefix("frames/") { return path.hasSuffix(".audit.yaml") || path.hasSuffix(".acceptance.json") }
        if path.hasPrefix("renders/") { return path.hasSuffix(".json") }
        if path.hasPrefix("execution/") {
            return path.hasSuffix(".json") && !path.hasPrefix("execution/blockout/") && !path.hasPrefix("execution/resources/")
        }
        return false
    }

    nonisolated private static func dataRoot(_ project: URL) throws -> URL {
        guard let root = DataRootResolver.dataRoot(of: project) else { throw MigrationError.invalidSource }
        return root
    }

    nonisolated private static func exactDigest(_ url: URL) throws -> String {
        try FileDigest.$readinessCache.withValue(nil) { try FileDigest.sha256(of: url) }
    }

    nonisolated private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
