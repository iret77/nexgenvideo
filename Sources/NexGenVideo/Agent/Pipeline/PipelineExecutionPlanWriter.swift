import Foundation
import NexGenEngine

enum PipelineExecutionPlanError: Error, Sendable, Equatable {
    case creativeContextReferenceMismatch
    case extensionReferenceMismatch
    case referencedFileInvalid(String)
    case persistedArtifactInvalid(String)
    case projectMetadataInvalid(String)
    case projectMetadataMismatch(expected: String, actual: String)
    case publicationFailed(String)
    case publicationRollbackFailed(String)
    case unsafePublicationPath(String)
}

enum PipelineExecutionPlanWriter {
    private struct Publication: Codable, Equatable {
        static let schemaVersion = "execution-plan-publication/v1"

        let schema: String
        let contextSHA256: String
        let planSHA256: String

        private enum CodingKeys: String, CodingKey {
            case schema
            case contextSHA256 = "context_sha256"
            case planSHA256 = "plan_sha256"
        }

        init(contextData: Data, planData: Data) {
            schema = Self.schemaVersion
            contextSHA256 = FileDigest.sha256(of: contextData)
            planSHA256 = FileDigest.sha256(of: planData)
        }
    }

    static func write(
        plan: ExecutionPlanV1,
        context: ProjectCreativeContextV1,
        dataRoot: URL
    ) throws -> URL {
        try validate(plan: plan, context: context, dataRoot: dataRoot)

        let contextData = try ExecutionPlanCanonicalCodec.encode(context)
        let planData = try ExecutionPlanCanonicalCodec.encode(plan)
        let contextURL = PipelineLayout.url(PipelineLayout.creativeContextFile, in: dataRoot)
        let planURL = PipelineLayout.url(PipelineLayout.executionPlanFile, in: dataRoot)
        let publicationURL = PipelineLayout.url(
            ExecutionPlanV1.publicationArtifactPath,
            in: dataRoot
        )
        try requireSafePublicationLocations(dataRoot: dataRoot, allowMissingDirectory: true)
        try FileManager.default.createDirectory(
            at: planURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try requireSafePublicationLocations(dataRoot: dataRoot, allowMissingDirectory: false)

        try publish(
            contextData: contextData,
            to: contextURL,
            planData: planData,
            to: planURL,
            publicationURL: publicationURL
        )
        return planURL
    }

    static func requireCurrent(dataRoot: URL) throws {
        do {
            let (plan, context) = try load(dataRoot: dataRoot)
            try validate(plan: plan, context: context, dataRoot: dataRoot)
        } catch {
            throw GateBlocked(
                "The execution plan is missing, incomplete, stale, or no longer matches "
                    + "its project-local inputs. Rebuild it through the canonical writer."
            )
        }
    }

    static func lineageSnapshot(dataRoot: URL) throws -> PhaseLineageSnapshot {
        let (plan, context, planData, contextData) = try loadBytes(dataRoot: dataRoot)
        try validate(plan: plan, context: context, dataRoot: dataRoot)

        var inputs = [
            "context:\(FileDigest.sha256(of: contextData))",
        ]
        let projectURL = try ProjectLocalFile.resolve(
            PipelineLayout.projectFile,
            dataRoot: dataRoot
        )
        inputs.append("project:\(try FileDigest.sha256(of: projectURL))")
        for reference in context.artifacts.sorted(by: referenceOrder) {
            let url = try ProjectLocalFile.requireHash(
                reference.sha256,
                at: reference.path,
                dataRoot: dataRoot
            )
            inputs.append("artifact:\(reference.id):\(try FileDigest.sha256(of: url))")
        }
        for reference in context.media.sorted(by: mediaOrder) {
            let url = try ProjectLocalFile.requireHash(
                reference.sha256,
                at: reference.path,
                dataRoot: dataRoot
            )
            inputs.append("media:\(reference.id):\(try FileDigest.sha256(of: url))")
        }
        for reference in context.extensions.sorted(by: extensionOrder) {
            let url = try ProjectLocalFile.requireHash(
                reference.sha256,
                at: reference.path,
                dataRoot: dataRoot
            )
            inputs.append("extension:\(reference.id):\(try FileDigest.sha256(of: url))")
        }
        let inputData = Data(inputs.joined(separator: "\n").utf8)
        return PhaseLineageSnapshot(
            inputFingerprint: FileDigest.sha256(of: inputData),
            artifactFingerprint: FileDigest.sha256(of: planData)
        )
    }

    static func load(dataRoot: URL) throws -> (ExecutionPlanV1, ProjectCreativeContextV1) {
        let (plan, context, _, _) = try loadBytes(dataRoot: dataRoot)
        try validate(plan: plan, context: context, dataRoot: dataRoot)
        return (plan, context)
    }

    private static func validate(
        plan: ExecutionPlanV1,
        context: ProjectCreativeContextV1,
        dataRoot: URL
    ) throws {
        try ExecutionPlanValidator.validate(plan, against: context)

        let projectURL: URL
        let metadata: ProjectMeta
        do {
            projectURL = try ProjectLocalFile.resolve(
                PipelineLayout.projectFile,
                dataRoot: dataRoot
            )
            metadata = try YAMLCoding.decode(ProjectMeta.self, from: projectURL)
        } catch {
            throw PipelineExecutionPlanError.projectMetadataInvalid(
                error.localizedDescription
            )
        }
        guard metadata.project == plan.projectID else {
            throw PipelineExecutionPlanError.projectMetadataMismatch(
                expected: metadata.project,
                actual: plan.projectID
            )
        }

        let contextData = try ExecutionPlanCanonicalCodec.encode(context)
        guard plan.creativeContext.path == PipelineLayout.creativeContextFile,
              plan.creativeContext.sha256 == FileDigest.sha256(of: contextData) else {
            throw PipelineExecutionPlanError.creativeContextReferenceMismatch
        }

        let planExtensions = Dictionary(uniqueKeysWithValues: plan.extensionReferences.map {
            ($0.id, $0)
        })
        let contextExtensions = Dictionary(uniqueKeysWithValues: context.extensions.map {
            ($0.id, $0)
        })
        guard planExtensions == contextExtensions else {
            throw PipelineExecutionPlanError.extensionReferenceMismatch
        }

        for reference in context.artifacts {
            do {
                _ = try ProjectLocalFile.requireHash(
                    reference.sha256,
                    at: reference.path,
                    dataRoot: dataRoot
                )
            } catch {
                throw PipelineExecutionPlanError.referencedFileInvalid(reference.path)
            }
        }
        for reference in context.extensions {
            do {
                _ = try ProjectLocalFile.requireHash(
                    reference.sha256,
                    at: reference.path,
                    dataRoot: dataRoot
                )
            } catch {
                throw PipelineExecutionPlanError.referencedFileInvalid(reference.path)
            }
        }
        for reference in context.media {
            do {
                _ = try ProjectLocalFile.requireHash(
                    reference.sha256,
                    at: reference.path,
                    dataRoot: dataRoot
                )
            } catch {
                throw PipelineExecutionPlanError.referencedFileInvalid(reference.path)
            }
        }
    }

    private static func loadBytes(
        dataRoot: URL
    ) throws -> (ExecutionPlanV1, ProjectCreativeContextV1, Data, Data) {
        let planURL = PipelineLayout.url(PipelineLayout.executionPlanFile, in: dataRoot)
        let contextURL = PipelineLayout.url(PipelineLayout.creativeContextFile, in: dataRoot)
        let publicationURL = PipelineLayout.url(
            ExecutionPlanV1.publicationArtifactPath,
            in: dataRoot
        )
        do {
            try requireSafePublicationLocations(
                dataRoot: dataRoot,
                allowMissingDirectory: false
            )
            let publicationBefore = try Data(contentsOf: publicationURL)
            let planData = try Data(contentsOf: planURL)
            let contextData = try Data(contentsOf: contextURL)
            let publicationAfter = try Data(contentsOf: publicationURL)
            guard publicationBefore == publicationAfter else {
                throw PipelineExecutionPlanError.persistedArtifactInvalid(
                    "The execution-plan publication changed while it was being read."
                )
            }
            let publication = try JSONDecoder().decode(
                Publication.self,
                from: publicationAfter
            )
            guard publication.schema == Publication.schemaVersion,
                  publication.contextSHA256 == FileDigest.sha256(of: contextData),
                  publication.planSHA256 == FileDigest.sha256(of: planData) else {
                throw PipelineExecutionPlanError.persistedArtifactInvalid(
                    "The execution-plan publication does not match its committed bytes."
                )
            }
            return (
                try ExecutionPlanCanonicalCodec.decodePlan(planData),
                try ExecutionPlanCanonicalCodec.decodeContext(contextData),
                planData,
                contextData
            )
        } catch {
            throw PipelineExecutionPlanError.persistedArtifactInvalid(
                error.localizedDescription
            )
        }
    }

    private static func publish(
        contextData: Data,
        to contextURL: URL,
        planData: Data,
        to planURL: URL,
        publicationURL: URL
    ) throws {
        let fileManager = FileManager.default
        let previousContext = try existingBytes(at: contextURL)
        let previousPlan = try existingBytes(at: planURL)
        let previousPublication = try existingBytes(at: publicationURL)
        let publicationData = try encodePublication(
            Publication(contextData: contextData, planData: planData)
        )
        let stagingURL = planURL.deletingLastPathComponent()
            .appendingPathComponent(".execution-plan-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: stagingURL,
                withIntermediateDirectories: false
            )
            let stagedContext = stagingURL.appendingPathComponent("context.json")
            let stagedPlan = stagingURL.appendingPathComponent("plan.json")
            let stagedPublication = stagingURL.appendingPathComponent("publication.json")
            try contextData.write(to: stagedContext, options: .atomic)
            try planData.write(to: stagedPlan, options: .atomic)
            try publicationData.write(to: stagedPublication, options: .atomic)

            try Data(contentsOf: stagedContext).write(to: contextURL, options: .atomic)
            try Data(contentsOf: stagedPlan).write(to: planURL, options: .atomic)
            try Data(contentsOf: stagedPublication).write(
                to: publicationURL,
                options: .atomic
            )
            guard try Data(contentsOf: contextURL) == contextData,
                  try Data(contentsOf: planURL) == planData,
                  try Data(contentsOf: publicationURL) == publicationData else {
                throw PipelineExecutionPlanError.publicationFailed(
                    "Persisted execution-plan bytes differ from the canonical publication."
                )
            }
        } catch {
            do {
                try restore(previousContext, at: contextURL)
                try restore(previousPlan, at: planURL)
                try restore(previousPublication, at: publicationURL)
            } catch {
                try? fileManager.removeItem(at: stagingURL)
                throw PipelineExecutionPlanError.publicationRollbackFailed(
                    error.localizedDescription
                )
            }
            try? fileManager.removeItem(at: stagingURL)
            if let error = error as? PipelineExecutionPlanError {
                throw error
            }
            throw PipelineExecutionPlanError.publicationFailed(
                error.localizedDescription
            )
        }
        try? fileManager.removeItem(at: stagingURL)
    }

    private static func existingBytes(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private static func requireSafePublicationLocations(
        dataRoot: URL,
        allowMissingDirectory: Bool
    ) throws {
        let fileManager = FileManager.default
        let directory = PipelineLayout.url(PipelineLayout.executionDir, in: dataRoot)
        if (try? fileManager.destinationOfSymbolicLink(atPath: dataRoot.path)) != nil {
            throw PipelineExecutionPlanError.unsafePublicationPath(dataRoot.path)
        }
        if (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) != nil {
            throw PipelineExecutionPlanError.unsafePublicationPath(directory.path)
        }
        if fileManager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw PipelineExecutionPlanError.unsafePublicationPath(directory.path)
            }
        } else if !allowMissingDirectory {
            throw PipelineExecutionPlanError.unsafePublicationPath(directory.path)
        }

        for relativePath in [
            PipelineLayout.creativeContextFile,
            PipelineLayout.executionPlanFile,
            ExecutionPlanV1.publicationArtifactPath,
        ] {
            let url = PipelineLayout.url(relativePath, in: dataRoot)
            if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw PipelineExecutionPlanError.unsafePublicationPath(url.path)
            }
        }
    }

    private static func encodePublication(_ publication: Publication) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(publication)
    }

    private static func restore(_ data: Data?, at url: URL) throws {
        if let data {
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func referenceOrder(
        _ lhs: CanonicalArtifactReferenceV1,
        _ rhs: CanonicalArtifactReferenceV1
    ) -> Bool {
        lhs.id == rhs.id ? lhs.path < rhs.path : lhs.id < rhs.id
    }

    private static func extensionOrder(
        _ lhs: PackArtifactExtensionReferenceV1,
        _ rhs: PackArtifactExtensionReferenceV1
    ) -> Bool {
        lhs.id == rhs.id ? lhs.path < rhs.path : lhs.id < rhs.id
    }

    private static func mediaOrder(
        _ lhs: ProjectMediaReferenceV1,
        _ rhs: ProjectMediaReferenceV1
    ) -> Bool {
        lhs.id == rhs.id ? lhs.path < rhs.path : lhs.id < rhs.id
    }
}
