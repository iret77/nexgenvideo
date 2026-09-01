import AVFoundation
import Foundation
import NexGenEngine

enum PipelineProductionInputsError: Error, Sendable, Equatable {
    case invalidArtifact(String)
    case publicationFailed(String)
    case publicationRollbackFailed(String)
    case persistedArtifactInvalid(String)
    case unsafePath(String)
}

enum PipelineProductionInputsWriter {
    private static let refreshableCoreSemanticJobs: Set<String> = [
        CoreReferenceSemanticJobIDV1.firstFrame,
        CoreReferenceSemanticJobIDV1.lastFrame,
        CoreReferenceSemanticJobIDV1.predecessorLastFrame,
        CoreReferenceSemanticJobIDV1.audioTiming,
    ]

    static func demandsPreservedAcrossRefresh(
        _ demands: [ReferenceDemandV1]
    ) -> [ReferenceDemandV1] {
        demands.filter {
            !refreshableCoreSemanticJobs.contains(
                ProductionIdentifierNormalizerV1.canonical($0.semanticJobID)
            )
        }
    }

    private struct Publication: Codable, Equatable {
        static let schemaVersion = "production-inputs-publication/v1"

        let schema: String
        let graphSHA256: String
        let demandSetSHA256ByShotID: [String: String]
        let inputTemplateSHA256ByShotID: [String: String]

        private enum CodingKeys: String, CodingKey {
            case schema
            case graphSHA256 = "graph_sha256"
            case demandSetSHA256ByShotID = "demand_set_sha256_by_shot_id"
            case inputTemplateSHA256ByShotID = "input_template_sha256_by_shot_id"
        }

        init(
            graphData: Data,
            demandDataByShotID: [String: Data],
            templateDataByShotID: [String: Data]
        ) {
            schema = Self.schemaVersion
            graphSHA256 = FileDigest.sha256(of: graphData)
            demandSetSHA256ByShotID = demandDataByShotID.mapValues {
                FileDigest.sha256(of: $0)
            }
            inputTemplateSHA256ByShotID = templateDataByShotID.mapValues {
                FileDigest.sha256(of: $0)
            }
        }
    }

    struct Snapshot {
        fileprivate let bytesByPath: [String: Data?]
    }

    static func write(
        graph: AssetGraphV1,
        demandSets: [ReferenceDemandSetV1],
        templates: [ProductionInputTemplateV1],
        dataRoot: URL,
        declaredPack: String? = nil,
        declaredBinding: ProjectPackBinding? = nil
    ) throws {
        try AssetGraphValidatorV1.validateProjectFiles(graph, dataRoot: dataRoot)
        let demandByShotID = try uniqueByShotID(demandSets, label: "demand set")
        let templateByShotID = try uniqueByShotID(templates, label: "input template")
        guard Set(demandByShotID.keys) == Set(templateByShotID.keys),
              demandSets.allSatisfy({ $0.projectID == graph.projectID }),
              templates.allSatisfy({
                  $0.schema == productionInputTemplateV1Schema
                      && $0.projectID == graph.projectID
                      && nonEmpty($0.id)
              }) else {
            throw PipelineProductionInputsError.invalidArtifact(
                "Demand sets and input templates must cover the same project shots."
            )
        }

        let graphData = try AssetGraphCanonicalCodecV1.encode(graph)
        let graphReference = CanonicalArtifactReferenceV1(
            id: graph.id,
            role: AssetGraphV1.artifactRole,
            path: PipelineLayout.assetGraphFile,
            sha256: FileDigest.sha256(of: graphData)
        )
        for demandSet in demandSets {
            guard demandSet.assetGraph == graphReference else {
                throw PipelineProductionInputsError.invalidArtifact(
                    "Demand set \(demandSet.shotID) does not bind the exact AssetGraph."
                )
            }
            try AssetGraphValidatorV1.validate(demandSet, against: graph)
        }

        let demandData = try Dictionary(uniqueKeysWithValues: demandSets.map {
            ($0.shotID, try AssetGraphCanonicalCodecV1.encode($0))
        })
        let templateData = try Dictionary(uniqueKeysWithValues: templates.map {
            ($0.shotID, try encode($0))
        })
        let publicationData = try encode(
            Publication(
                graphData: graphData,
                demandDataByShotID: demandData,
                templateDataByShotID: templateData
            )
        )
        let paths = publicationPaths(shotIDs: Set(demandByShotID.keys))
        let previous = try snapshot(
            shotIDs: Set(demandByShotID.keys),
            dataRoot: dataRoot
        )
        let obsoletePaths = Set(previous.bytesByPath.keys).subtracting(paths)
        try requireSafe(paths: paths.union(obsoletePaths), dataRoot: dataRoot)
        try requirePackMutation(
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )

        do {
            try write(graphData, to: PipelineLayout.assetGraphFile, dataRoot: dataRoot)
            for shotID in demandByShotID.keys.sorted() {
                try write(
                    demandData[shotID]!,
                    to: PipelineLayout.referenceDemandSetFile(shotID: shotID),
                    dataRoot: dataRoot
                )
                try write(
                    templateData[shotID]!,
                    to: PipelineLayout.productionInputTemplateFile(shotID: shotID),
                    dataRoot: dataRoot
                )
            }
            for path in obsoletePaths.sorted() {
                let url = PipelineLayout.url(path, in: dataRoot)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            try write(
                publicationData,
                to: PipelineLayout.productionInputsPublicationFile,
                dataRoot: dataRoot
            )
            try verifyPersisted(
                graphData: graphData,
                demandDataByShotID: demandData,
                templateDataByShotID: templateData,
                publicationData: publicationData,
                dataRoot: dataRoot
            )
        } catch {
            do {
                try restore(previous, dataRoot: dataRoot)
            } catch {
                throw PipelineProductionInputsError.publicationRollbackFailed(
                    error.localizedDescription
                )
            }
            if let error = error as? PipelineProductionInputsError {
                throw error
            }
            throw PipelineProductionInputsError.publicationFailed(error.localizedDescription)
        }
    }

    static func load(
        shotID: String,
        dataRoot: URL
    ) throws -> (AssetGraphV1, ReferenceDemandSetV1, ProductionInputTemplateV1) {
        do {
            let publicationPath = PipelineLayout.productionInputsPublicationFile
            let publicationBefore = try read(publicationPath, dataRoot: dataRoot)
            let publication = try JSONDecoder().decode(
                Publication.self,
                from: publicationBefore
            )
            guard publication.schema == Publication.schemaVersion,
                  let demandSHA = publication.demandSetSHA256ByShotID[shotID],
                  let templateSHA = publication.inputTemplateSHA256ByShotID[shotID],
                  Set(publication.demandSetSHA256ByShotID.keys)
                    == Set(publication.inputTemplateSHA256ByShotID.keys) else {
                throw PipelineProductionInputsError.persistedArtifactInvalid(
                    "The production-input publication does not cover shot \(shotID)."
                )
            }
            let graphData = try read(PipelineLayout.assetGraphFile, dataRoot: dataRoot)
            let demandData = try read(
                PipelineLayout.referenceDemandSetFile(shotID: shotID),
                dataRoot: dataRoot
            )
            let templateData = try read(
                PipelineLayout.productionInputTemplateFile(shotID: shotID),
                dataRoot: dataRoot
            )
            let publicationAfter = try read(publicationPath, dataRoot: dataRoot)
            guard publicationBefore == publicationAfter,
                  publication.graphSHA256 == FileDigest.sha256(of: graphData),
                  demandSHA == FileDigest.sha256(of: demandData),
                  templateSHA == FileDigest.sha256(of: templateData) else {
                throw PipelineProductionInputsError.persistedArtifactInvalid(
                    "The committed production-input bytes changed or do not match publication."
                )
            }
            let graph = try AssetGraphCanonicalCodecV1.decodeGraph(graphData)
            let demandSet = try AssetGraphCanonicalCodecV1.decodeDemandSet(
                demandData,
                graph: graph
            )
            let template = try JSONDecoder().decode(
                ProductionInputTemplateV1.self,
                from: templateData
            )
            guard template.shotID == shotID,
                  template.projectID == graph.projectID else {
                throw PipelineProductionInputsError.persistedArtifactInvalid(
                    "The input template identity does not match its publication."
                )
            }
            try AssetGraphValidatorV1.validateProjectFiles(graph, dataRoot: dataRoot)
            return (graph, demandSet, template)
        } catch let error as PipelineProductionInputsError {
            throw error
        } catch {
            throw PipelineProductionInputsError.persistedArtifactInvalid(
                error.localizedDescription
            )
        }
    }

    @MainActor
    static func refresh(
        shotID: String,
        phase: String,
        dataRoot: URL,
        declaredPack: String? = nil,
        declaredBinding: ProjectPackBinding? = nil
    ) async throws {
        try requirePackMutation(
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
        var stagedAudioDirectories: [URL] = []
        var publishedAudioURLs: [URL] = []
        var createdAudioDirectories: [URL] = []
        var publicationCompleted = false
        defer {
            for directory in stagedAudioDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            if !publicationCompleted {
                for url in publishedAudioURLs {
                    try? FileManager.default.removeItem(at: url)
                }
                for directory in createdAudioDirectories.reversed() {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
        }
        let (plan, context) = try PipelineExecutionPlanWriter.load(dataRoot: dataRoot)
        try PipelineExecutionPlanWriter.requireCurrentShotlistBinding(dataRoot: dataRoot)
        guard let shotIndex = plan.shots.firstIndex(where: { $0.id == shotID }),
              let requirement = plan.shots[shotIndex].generationRequirement,
              let shotlist = try loadShotlist(dataRoot: dataRoot),
              let shot = shotlist.shots.first(where: { $0.id == shotID }) else {
            throw PipelineProductionInputsError.invalidArtifact(
                "Shot \(shotID) has no current production requirement."
            )
        }
        let (graph, demandSets, templates) = try loadAll(
            dataRoot: dataRoot,
            validateProjectFiles: false
        )
        guard let template = templates.first(where: { $0.shotID == shotID }),
              var currentDemandSet = demandSets.first(where: { $0.shotID == shotID }) else {
            throw PipelineProductionInputsError.invalidArtifact(
                "Shot \(shotID) has no published input template."
            )
        }
        let immediatePredecessor = ChainContinuity.executionPredecessor(
            plan,
            shotID: shotID
        )
        let chained = template.coreInputs.predecessorLastFrameModeID != nil
        try ProductionInputTemplateValidatorV1.validate(
            template,
            requirement: requirement,
            chainedFromPredecessor: chained
        )
        guard !chained || immediatePredecessor != nil else {
            throw PipelineProductionInputsError.invalidArtifact(
                "The first shot cannot use a predecessor frame."
            )
        }

        let originalPathByAssetID = Dictionary(uniqueKeysWithValues: graph.assets.map {
            ($0.id, $0.path)
        })
        var assetsByPath = try refreshingProofBindings(
            graph.assets,
            phase: phase,
            dataRoot: dataRoot
        )
        var normalizedDemandSets = demandSets.map { demandSet in
            guard demandSet.shotID == shotID else { return demandSet }
            ReferenceDemandSetV1(
                id: demandSet.id,
                projectID: demandSet.projectID,
                shotID: demandSet.shotID,
                assetGraph: demandSet.assetGraph,
                demands: demandsPreservedAcrossRefresh(demandSet.demands)
            )
        }
        currentDemandSet = normalizedDemandSets.first(where: { $0.shotID == shotID })!
        var currentDemands = currentDemandSet.demands

        if let modeID = template.coreInputs.firstFrameModeID {
            let frame = try approvedFrame(
                shotID: shotID,
                role: "start",
                dataRoot: dataRoot
            )
            let asset = try upsertingAsset(
                path: frame.path,
                modality: .image,
                semanticJobID: CoreReferenceSemanticJobIDV1.firstFrame,
                provenance: AssetProvenanceV1(
                    kindID: CoreAssetProvenanceKindIDV1.approvedFrame,
                    sourceShotID: shotID,
                    sourceRoleID: CoreReferenceSemanticJobIDV1.firstFrame,
                    sourceProofPath: frame.proofPath,
                    sourceProofSHA256: frame.proofSHA256,
                    recordedAt: frame.recordedAt
                ),
                assetsByPath: &assetsByPath,
                dataRoot: dataRoot
            )
            currentDemands.append(ReferenceDemandV1(
                id: "core-first-frame-\(shotID)",
                assetID: asset.id,
                modality: .image,
                semanticJobID: CoreReferenceSemanticJobIDV1.firstFrame,
                isRequired: true,
                priority: 0,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame,
                modeID: modeID
            ))
        }
        if let modeID = template.coreInputs.lastFrameModeID {
            let frame = try approvedFrame(
                shotID: shotID,
                role: "end",
                dataRoot: dataRoot
            )
            let asset = try upsertingAsset(
                path: frame.path,
                modality: .image,
                semanticJobID: CoreReferenceSemanticJobIDV1.lastFrame,
                provenance: AssetProvenanceV1(
                    kindID: CoreAssetProvenanceKindIDV1.approvedFrame,
                    sourceShotID: shotID,
                    sourceRoleID: CoreReferenceSemanticJobIDV1.lastFrame,
                    sourceProofPath: frame.proofPath,
                    sourceProofSHA256: frame.proofSHA256,
                    recordedAt: frame.recordedAt
                ),
                assetsByPath: &assetsByPath,
                dataRoot: dataRoot
            )
            currentDemands.append(ReferenceDemandV1(
                id: "core-last-frame-\(shotID)",
                assetID: asset.id,
                modality: .image,
                semanticJobID: CoreReferenceSemanticJobIDV1.lastFrame,
                isRequired: true,
                priority: 0,
                inputSlotID: CoreReferenceInputSlotIDV1.lastFrame,
                modeID: modeID
            ))
        }
        if let modeID = template.coreInputs.predecessorLastFrameModeID,
           let predecessorShotID = immediatePredecessor {
            let predecessor = try predecessorLastFrame(
                shotID: predecessorShotID,
                phase: phase,
                projectID: plan.projectID,
                dataRoot: dataRoot
            )
            let asset = try upsertingAsset(
                path: predecessor.path,
                modality: .image,
                semanticJobID: CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                provenance: AssetProvenanceV1(
                    kindID: CoreAssetProvenanceKindIDV1.renderFrame,
                    sourceShotID: predecessorShotID,
                    sourceRoleID: CoreReferenceSemanticJobIDV1.lastFrame,
                    sourceProofPath: predecessor.proofPath,
                    sourceProofSHA256: predecessor.proofSHA256,
                    recordedAt: predecessor.recordedAt
                ),
                assetsByPath: &assetsByPath,
                dataRoot: dataRoot
            )
            currentDemands.append(ReferenceDemandV1(
                id: "core-predecessor-last-frame-\(shotID)",
                assetID: asset.id,
                modality: .image,
                semanticJobID: CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                isRequired: true,
                priority: 0,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame,
                modeID: modeID,
                expectedSourceShotID: predecessorShotID
            ))
        }
        if let modeID = template.coreInputs.audioTimingModeID {
            let segment = try await materializeAudioTimingSegment(
                shot: shot,
                songAudioPath: shotlist.song.audioPath,
                dataRoot: dataRoot
            )
            stagedAudioDirectories.append(segment.stagedURL.deletingLastPathComponent())
            try requirePackMutation(
                dataRoot: dataRoot,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
            )
            let outputURL = PipelineLayout.url(segment.path, in: dataRoot)
            let outputDirectory = outputURL.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: outputURL.path) {
                guard try FileDigest.sha256(of: outputURL)
                    == FileDigest.sha256(of: segment.stagedURL) else {
                    throw PipelineProductionInputsError.publicationFailed(
                        "The shot audio timing segment path is occupied by different bytes."
                    )
                }
            } else {
                let directoryExisted = FileManager.default.fileExists(
                    atPath: outputDirectory.path
                )
                try FileManager.default.createDirectory(
                    at: outputDirectory,
                    withIntermediateDirectories: true
                )
                if !directoryExisted {
                    createdAudioDirectories.append(outputDirectory)
                }
                let commitURL = outputDirectory.appendingPathComponent(
                    ".publish-\(UUID().uuidString).m4a"
                )
                defer { try? FileManager.default.removeItem(at: commitURL) }
                try FileManager.default.copyItem(at: segment.stagedURL, to: commitURL)
                try FileManager.default.moveItem(at: commitURL, to: outputURL)
                publishedAudioURLs.append(outputURL)
            }
            let asset = try upsertingAsset(
                path: segment.path,
                modality: .audio,
                semanticJobID: CoreReferenceSemanticJobIDV1.audioTiming,
                provenance: AssetProvenanceV1(
                    kindID: "core.audio-timing-segment",
                    sourceAssetID: segment.sourceAssetID,
                    recordedAt: shotlist.generated
                ),
                durationSeconds: segment.durationSeconds,
                assetsByPath: &assetsByPath,
                dataRoot: dataRoot
            )
            currentDemands.append(ReferenceDemandV1(
                id: "core-audio-timing-\(shotID)",
                assetID: asset.id,
                modality: .audio,
                semanticJobID: CoreReferenceSemanticJobIDV1.audioTiming,
                isRequired: true,
                priority: 0,
                inputSlotID: CoreReferenceInputSlotIDV1.audioTiming,
                modeID: modeID,
                durationSeconds: segment.durationSeconds
            ))
        }

        normalizedDemandSets = try normalizedDemandSets.map { demandSet in
            ReferenceDemandSetV1(
                id: demandSet.id,
                projectID: demandSet.projectID,
                shotID: demandSet.shotID,
                assetGraph: demandSet.assetGraph,
                demands: try remapDemands(
                    demandSet.shotID == shotID ? currentDemands : demandSet.demands,
                    originalPathByAssetID: originalPathByAssetID,
                    assetsByPath: assetsByPath
                )
            )
        }
        let referencedAssetIDs = Set(normalizedDemandSets.flatMap(\.demands).map(\.assetID))
        let refreshedAssets = assetsByPath.values
            .filter { referencedAssetIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
        let refreshedGraph = AssetGraphV1(
            id: try AssetGraphContentAddressV1.graphID(
                projectID: graph.projectID,
                assets: refreshedAssets
            ),
            projectID: graph.projectID,
            assets: refreshedAssets
        )
        let graphData = try AssetGraphCanonicalCodecV1.encode(refreshedGraph)
        let graphReference = CanonicalArtifactReferenceV1(
            id: refreshedGraph.id,
            role: AssetGraphV1.artifactRole,
            path: PipelineLayout.assetGraphFile,
            sha256: FileDigest.sha256(of: graphData)
        )
        normalizedDemandSets = normalizedDemandSets.map { demandSet in
            ReferenceDemandSetV1(
                id: demandSet.id,
                projectID: demandSet.projectID,
                shotID: demandSet.shotID,
                assetGraph: graphReference,
                demands: demandSet.demands
            )
        }
        guard let prospectiveDemandSet = normalizedDemandSets.first(where: {
            $0.shotID == shotID
        }) else {
            throw PipelineProductionInputsError.invalidArtifact(
                "Shot \(shotID) disappeared while refreshing its production inputs."
            )
        }
        try ProductionInputTemplateValidatorV1.validate(
            template,
            requirement: requirement,
            chainedFromPredecessor: chained
        )
        try ExecutionPlanValidator.validate(
            plan,
            against: context,
            assetGraph: refreshedGraph,
            demandSet: prospectiveDemandSet,
            forShotID: shotID
        )
        try write(
            graph: refreshedGraph,
            demandSets: normalizedDemandSets,
            templates: templates,
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
        let refreshed = try load(shotID: shotID, dataRoot: dataRoot)
        try ProductionInputTemplateValidatorV1.validate(
            refreshed.2,
            requirement: requirement,
            chainedFromPredecessor: chained
        )
        try ExecutionPlanValidator.validate(
            plan,
            against: context,
            assetGraph: refreshed.0,
            demandSet: refreshed.1,
            forShotID: shotID
        )
        publicationCompleted = true
    }

    static func snapshot(shotIDs: Set<String>, dataRoot: URL) throws -> Snapshot {
        var allShotIDs = shotIDs
        if let data = try? read(
            PipelineLayout.productionInputsPublicationFile,
            dataRoot: dataRoot
        ), let publication = try? JSONDecoder().decode(Publication.self, from: data) {
            allShotIDs.formUnion(publication.demandSetSHA256ByShotID.keys)
            allShotIDs.formUnion(publication.inputTemplateSHA256ByShotID.keys)
        }
        return try snapshot(
            paths: publicationPaths(shotIDs: allShotIDs),
            dataRoot: dataRoot
        )
    }

    static func restore(_ snapshot: Snapshot, dataRoot: URL) throws {
        var failures: [String] = []
        for path in snapshot.bytesByPath.keys.sorted() {
            do {
                let url = PipelineLayout.url(path, in: dataRoot)
                if let data = snapshot.bytesByPath[path] ?? nil {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: url, options: .atomic)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                failures.append("\(path): \(error.localizedDescription)")
            }
        }
        guard failures.isEmpty else {
            throw PipelineProductionInputsError.publicationRollbackFailed(
                failures.joined(separator: "; ")
            )
        }
    }

    private static func requirePackMutation(
        dataRoot: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding?
    ) throws {
        _ = try ProjectPackGate.requireMutation(
            projectURL: FrameInventory.projectHome(of: dataRoot),
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
    }

    private struct ApprovedFrame {
        let path: String
        let proofPath: String
        let proofSHA256: String
        let recordedAt: String
    }

    private struct PredecessorFrame {
        let path: String
        let proofPath: String
        let proofSHA256: String
        let recordedAt: String
    }

    private struct AudioTimingSegment {
        let path: String
        let sourceAssetID: String
        let durationSeconds: Double
        let stagedURL: URL
    }

    private struct AudioTimingIdentity: Encodable {
        let sourcePath: String
        let sourceSHA256: String
        let startMicroseconds: Int64
        let durationMicroseconds: Int64
        let encoder: String
    }

    private static func loadAll(
        dataRoot: URL,
        validateProjectFiles: Bool = true
    ) throws -> (AssetGraphV1, [ReferenceDemandSetV1], [ProductionInputTemplateV1]) {
        do {
            let publicationData = try read(
                PipelineLayout.productionInputsPublicationFile,
                dataRoot: dataRoot
            )
            let publication = try JSONDecoder().decode(
                Publication.self,
                from: publicationData
            )
            guard publication.schema == Publication.schemaVersion,
                  Set(publication.demandSetSHA256ByShotID.keys)
                    == Set(publication.inputTemplateSHA256ByShotID.keys) else {
                throw PipelineProductionInputsError.persistedArtifactInvalid(
                    "The production-input publication is malformed."
                )
            }
            let graphData = try read(PipelineLayout.assetGraphFile, dataRoot: dataRoot)
            guard publication.graphSHA256 == FileDigest.sha256(of: graphData) else {
                throw PipelineProductionInputsError.persistedArtifactInvalid(
                    "The AssetGraph does not match its publication."
                )
            }
            let graph = try AssetGraphCanonicalCodecV1.decodeGraph(graphData)
            var demandSets: [ReferenceDemandSetV1] = []
            var templates: [ProductionInputTemplateV1] = []
            for shotID in publication.demandSetSHA256ByShotID.keys.sorted() {
                let demandData = try read(
                    PipelineLayout.referenceDemandSetFile(shotID: shotID),
                    dataRoot: dataRoot
                )
                let templateData = try read(
                    PipelineLayout.productionInputTemplateFile(shotID: shotID),
                    dataRoot: dataRoot
                )
                guard publication.demandSetSHA256ByShotID[shotID]
                        == FileDigest.sha256(of: demandData),
                      publication.inputTemplateSHA256ByShotID[shotID]
                        == FileDigest.sha256(of: templateData) else {
                    throw PipelineProductionInputsError.persistedArtifactInvalid(
                        "The production inputs for \(shotID) do not match publication."
                    )
                }
                demandSets.append(try AssetGraphCanonicalCodecV1.decodeDemandSet(
                    demandData,
                    graph: graph
                ))
                templates.append(try JSONDecoder().decode(
                    ProductionInputTemplateV1.self,
                    from: templateData
                ))
            }
            guard try read(
                PipelineLayout.productionInputsPublicationFile,
                dataRoot: dataRoot
            ) == publicationData else {
                throw PipelineProductionInputsError.persistedArtifactInvalid(
                    "The production-input publication changed while being read."
                )
            }
            if validateProjectFiles {
                try AssetGraphValidatorV1.validateProjectFiles(graph, dataRoot: dataRoot)
            }
            return (graph, demandSets, templates)
        } catch let error as PipelineProductionInputsError {
            throw error
        } catch {
            throw PipelineProductionInputsError.persistedArtifactInvalid(
                error.localizedDescription
            )
        }
    }

    @MainActor
    private static func approvedFrame(
        shotID: String,
        role: String,
        dataRoot: URL
    ) throws -> ApprovedFrame {
        let provenance = try PipelineRenderRecordWriter.requireCurrentShotProvenance(
            dataRoot: dataRoot,
            phase: "frames",
            shotID: shotID
        )
        guard let frame = provenance.proof.frames?.frames.first(where: {
            $0.role == role
        }),
              frame.approved,
              let recordedAt = provenance.proof.renderEntry.updatedAt,
              !recordedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineProductionInputsError.invalidArtifact(
                "Shot \(shotID) has no approved \(role) frame."
            )
        }
        let frameURL = try ProjectLocalFile.resolve(frame.path, dataRoot: dataRoot)
        _ = try FileDigest.sha256(of: frameURL)
        return ApprovedFrame(
            path: frame.path,
            proofPath: provenance.artifact.path,
            proofSHA256: provenance.artifact.sha256,
            recordedAt: recordedAt
        )
    }

    @MainActor
    private static func predecessorLastFrame(
        shotID: String,
        phase: String,
        projectID: String,
        dataRoot: URL
    ) throws -> PredecessorFrame {
        let provenance = try PipelineRenderRecordWriter.requireCurrentShotProvenance(
            dataRoot: dataRoot,
            phase: phase,
            shotID: shotID
        )
        guard provenance.proof.project == projectID,
              let proofEntry = provenance.proof.renderProofEntry,
              let lastFrameProof = provenance.proof.lastFrame,
              lastFrameProof.shotID == shotID,
              lastFrameProof.phase == phase,
              lastFrameProof.sourceOutput == proofEntry.output,
              lastFrameProof.sourceOutputSHA256 == proofEntry.outputSha256,
              lastFrameProof.extractor == RenderLastFrameProofV1.extractorID else {
            throw PipelineProductionInputsError.invalidArtifact(
                "The predecessor render for \(shotID) has no exact current proof."
            )
        }
        return PredecessorFrame(
            path: lastFrameProof.path,
            proofPath: provenance.artifact.path,
            proofSHA256: provenance.artifact.sha256,
            recordedAt: lastFrameProof.extractedAt
        )
    }

    private static func materializeAudioTimingSegment(
        shot: Shot,
        songAudioPath: String,
        dataRoot: URL
    ) async throws -> AudioTimingSegment {
        guard shot.timeStart.isFinite,
              shot.timeStart >= 0,
              shot.durationS.isFinite,
              shot.durationS > 0 else {
            throw PipelineProductionInputsError.invalidArtifact(
                "Shot \(shot.id) has an invalid audio timing range."
            )
        }
        let sourceURL = try ProjectLocalFile.resolve(songAudioPath, dataRoot: dataRoot)
        let sourceSHA256 = try FileDigest.sha256(of: sourceURL)
        let asset = AVURLAsset(url: sourceURL)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw PipelineProductionInputsError.invalidArtifact(
                "The project song has no audio track."
            )
        }
        let start = CMTime(seconds: shot.timeStart, preferredTimescale: 1_000_000)
        let duration = CMTime(seconds: shot.durationS, preferredTimescale: 1_000_000)
        let range = CMTimeRange(start: start, duration: duration)
        let sourceDuration = try await asset.load(.duration)
        guard sourceDuration.seconds.isFinite,
              shot.timeStart + shot.durationS <= sourceDuration.seconds + 0.001 else {
            throw PipelineProductionInputsError.invalidArtifact(
                "Shot \(shot.id) extends beyond the project song."
            )
        }

        let identity = AudioTimingIdentity(
            sourcePath: songAudioPath,
            sourceSHA256: sourceSHA256,
            startMicroseconds: Int64((shot.timeStart * 1_000_000).rounded()),
            durationMicroseconds: Int64((shot.durationS * 1_000_000).rounded()),
            encoder: "avfoundation-apple-m4a/v1"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sliceID = FileDigest.sha256(of: try encoder.encode(identity))

        let composition = AVMutableComposition()
        guard let outputTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PipelineProductionInputsError.publicationFailed(
                "Couldn't create the shot audio timing track."
            )
        }
        try outputTrack.insertTimeRange(range, of: sourceTrack, at: .zero)
        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw PipelineProductionInputsError.publicationFailed(
                "The shot audio timing encoder is unavailable."
            )
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ngv-audio-timing-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let temporaryURL = temporaryDirectory.appendingPathComponent("segment.m4a")
        do {
            try await session.export(to: temporaryURL, as: .m4a)
            let outputAsset = AVURLAsset(url: temporaryURL)
            let outputDuration = try await outputAsset.load(.duration).seconds
            guard outputDuration.isFinite,
                  abs(outputDuration - shot.durationS) <= 0.05 else {
                throw PipelineProductionInputsError.publicationFailed(
                    "The shot audio timing segment has the wrong duration."
                )
            }
            let outputSHA256 = try FileDigest.sha256(of: temporaryURL)
            let outputPath = "execution/audio-timing/\(shot.id)-\(sliceID)-\(outputSHA256).m4a"
            return AudioTimingSegment(
                path: outputPath,
                sourceAssetID: "song-audio-\(sourceSHA256)",
                durationSeconds: shot.durationS,
                stagedURL: temporaryURL
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    static func upsertingAsset(
        path: String,
        modality: AssetPhysicalModalityV1,
        semanticJobID: String,
        provenance: AssetProvenanceV1,
        durationSeconds: Double? = nil,
        assetsByPath: inout [String: AssetGraphNodeV1],
        dataRoot: URL
    ) throws -> AssetGraphNodeV1 {
        let url = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
        let canonicalPath = try canonicalRelativePath(url, dataRoot: dataRoot)
        let sha256 = try FileDigest.sha256(of: url)
        if let existing = assetsByPath[canonicalPath] {
            guard existing.modality == modality,
                  existing.sha256 == sha256,
                  existing.approval == .approved,
                  existing.provenance.kindID == provenance.kindID,
                  existing.provenance.sourceShotID == provenance.sourceShotID,
                  existing.provenance.sourceRoleID == provenance.sourceRoleID,
                  existing.durationSeconds == durationSeconds else {
                throw PipelineProductionInputsError.invalidArtifact(
                    "Asset \(canonicalPath) conflicts with the published AssetGraph."
                )
            }
            let refreshedProvenance = existing.provenance != provenance
            let updated = try AssetGraphContentAddressV1.reidentified(AssetGraphNodeV1(
                id: "pending",
                version: existing.version + (refreshedProvenance ? 1 : 0),
                path: existing.path,
                sha256: existing.sha256,
                modality: existing.modality,
                entityID: existing.entityID,
                canonIDs: existing.canonIDs,
                stateID: existing.stateID,
                viewID: existing.viewID,
                approval: existing.approval,
                provenance: provenance,
                allowedUseIDs: Set(existing.allowedUseIDs + [semanticJobID]).sorted(),
                durationSeconds: durationSeconds
            ))
            assetsByPath[canonicalPath] = updated
            return updated
        }
        let node = try AssetGraphContentAddressV1.reidentified(AssetGraphNodeV1(
            id: "pending",
            version: 1,
            path: canonicalPath,
            sha256: sha256,
            modality: modality,
            approval: .approved,
            provenance: provenance,
            allowedUseIDs: [semanticJobID],
            durationSeconds: durationSeconds
        ))
        assetsByPath[canonicalPath] = node
        return node
    }

    @MainActor
    private static func refreshingProofBindings(
        _ assets: [AssetGraphNodeV1],
        phase: String,
        dataRoot: URL
    ) throws -> [String: AssetGraphNodeV1] {
        var result: [String: AssetGraphNodeV1] = [:]
        for asset in assets {
            var refreshed = asset
            let immutableBinding: (
                artifact: RenderPublishedArtifactV1,
                recordedAt: String
            )?
            switch asset.provenance.kindID {
            case CoreAssetProvenanceKindIDV1.approvedFrame:
                guard let sourceShotID = asset.provenance.sourceShotID,
                      let sourceRoleID = asset.provenance.sourceRoleID,
                      let role = frameRole(for: sourceRoleID) else {
                    throw PipelineProductionInputsError.invalidArtifact(
                        "Approved frame \(asset.id) has incomplete provenance."
                    )
                }
                let shotProof = try PipelineRenderRecordWriter
                    .requireCurrentShotProvenance(
                        dataRoot: dataRoot,
                        phase: "frames",
                        shotID: sourceShotID
                    )
                guard shotProof.proof.frames?.frames.contains(where: {
                    $0.role == role && $0.approved && $0.path == asset.path
                }) == true,
                      let recordedAt = shotProof.proof.renderEntry.updatedAt else {
                    throw PipelineProductionInputsError.invalidArtifact(
                        "Approved frame \(asset.id) no longer matches its immutable proof."
                    )
                }
                immutableBinding = (shotProof.artifact, recordedAt)
            case CoreAssetProvenanceKindIDV1.renderFrame:
                guard let sourceShotID = asset.provenance.sourceShotID else {
                    throw PipelineProductionInputsError.invalidArtifact(
                        "Render frame \(asset.id) has incomplete provenance."
                    )
                }
                let proofPhase = renderProofPhase(
                    sourceProofPath: asset.provenance.sourceProofPath,
                    fallback: phase
                )
                let shotProof = try PipelineRenderRecordWriter
                    .requireCurrentShotProvenance(
                        dataRoot: dataRoot,
                        phase: proofPhase,
                        shotID: sourceShotID
                    )
                guard let lastFrame = shotProof.proof.lastFrame,
                      lastFrame.path == asset.path,
                      lastFrame.sha256 == asset.sha256 else {
                    throw PipelineProductionInputsError.invalidArtifact(
                        "Render frame \(asset.id) no longer matches its immutable proof."
                    )
                }
                immutableBinding = (shotProof.artifact, lastFrame.extractedAt)
            default:
                immutableBinding = nil
                if let proofPath = asset.provenance.sourceProofPath,
                   let proofSHA256 = asset.provenance.sourceProofSHA256 {
                    _ = try ProjectLocalFile.requireHash(
                        proofSHA256,
                        at: proofPath,
                        dataRoot: dataRoot
                    )
                }
            }
            if let immutableBinding {
                let provenance = AssetProvenanceV1(
                    kindID: asset.provenance.kindID,
                    sourceAssetID: asset.provenance.sourceAssetID,
                    modelID: asset.provenance.modelID,
                    promptSHA256: asset.provenance.promptSHA256,
                    sourceShotID: asset.provenance.sourceShotID,
                    sourceRoleID: asset.provenance.sourceRoleID,
                    sourceProofPath: immutableBinding.artifact.path,
                    sourceProofSHA256: immutableBinding.artifact.sha256,
                    recordedAt: immutableBinding.recordedAt
                )
                if provenance != asset.provenance {
                    refreshed = try AssetGraphContentAddressV1.reidentified(
                        AssetGraphNodeV1(
                            id: "pending",
                            version: asset.version + 1,
                            path: asset.path,
                            sha256: asset.sha256,
                            modality: asset.modality,
                            entityID: asset.entityID,
                            canonIDs: asset.canonIDs,
                            stateID: asset.stateID,
                            viewID: asset.viewID,
                            approval: asset.approval,
                            provenance: provenance,
                            allowedUseIDs: asset.allowedUseIDs,
                            durationSeconds: asset.durationSeconds
                        )
                    )
                }
            }
            guard result.updateValue(refreshed, forKey: refreshed.path) == nil else {
                throw PipelineProductionInputsError.invalidArtifact(
                    "The AssetGraph contains duplicate paths."
                )
            }
        }
        return result
    }

    private static func renderProofPhase(
        sourceProofPath: String?,
        fallback: String
    ) -> String {
        guard let sourceProofPath else { return fallback }
        let components = sourceProofPath.split(separator: "/")
        if components.count == 5,
           components[0] == "renders",
           components[1] == "provenance" {
            return String(components[2])
        }
        let prefix = "renders/proof-"
        let suffix = ".json"
        if sourceProofPath.hasPrefix(prefix), sourceProofPath.hasSuffix(suffix) {
            return String(
                sourceProofPath.dropFirst(prefix.count).dropLast(suffix.count)
            )
        }
        return fallback
    }

    private static func frameRole(for semanticJobID: String) -> String? {
        if ProductionIdentifierNormalizerV1.matches(
            semanticJobID,
            CoreReferenceSemanticJobIDV1.firstFrame
        ) {
            return "start"
        }
        if ProductionIdentifierNormalizerV1.matches(
            semanticJobID,
            CoreReferenceSemanticJobIDV1.lastFrame
        ) {
            return "end"
        }
        return nil
    }

    private static func remapDemands(
        _ demands: [ReferenceDemandV1],
        originalPathByAssetID: [String: String],
        assetsByPath: [String: AssetGraphNodeV1]
    ) throws -> [ReferenceDemandV1] {
        let currentByID = Dictionary(uniqueKeysWithValues: assetsByPath.values.map {
            ($0.id, $0)
        })
        return try demands.map { demand in
            let asset: AssetGraphNodeV1?
            if let current = currentByID[demand.assetID] {
                asset = current
            } else if let path = originalPathByAssetID[demand.assetID] {
                asset = assetsByPath[path]
            } else {
                asset = nil
            }
            guard let asset else {
                throw PipelineProductionInputsError.invalidArtifact(
                    "Demand \(demand.id) references an unknown asset."
                )
            }
            return ReferenceDemandV1(
                id: demand.id,
                assetID: asset.id,
                modality: demand.modality,
                semanticJobID: demand.semanticJobID,
                isRequired: demand.isRequired,
                priority: demand.priority,
                preservationScopeIDs: demand.preservationScopeIDs,
                exclusionDemandIDs: demand.exclusionDemandIDs,
                inputSlotID: demand.inputSlotID,
                modeID: demand.modeID,
                durationSeconds: demand.durationSeconds,
                expectedSourceShotID: demand.expectedSourceShotID
            )
        }
    }

    private static func canonicalRelativePath(_ url: URL, dataRoot: URL) throws -> String {
        let file = url.standardizedFileURL
        let data = dataRoot.standardizedFileURL
        if file.path.hasPrefix(data.path + "/") {
            return String(file.path.dropFirst(data.path.count + 1))
        }
        let project = FrameInventory.projectHome(of: dataRoot).standardizedFileURL
        guard file.path.hasPrefix(project.path + "/") else {
            throw PipelineProductionInputsError.unsafePath(url.path)
        }
        return String(file.path.dropFirst(project.path.count + 1))
    }

    private static func uniqueByShotID<T>(
        _ values: [T],
        label: String
    ) throws -> [String: T] where T: ShotScopedProductionInput {
        var result: [String: T] = [:]
        for value in values {
            guard validShotID(value.shotID), result[value.shotID] == nil else {
                throw PipelineProductionInputsError.invalidArtifact(
                    "Duplicate or unsafe \(label) shot id \(value.shotID)."
                )
            }
            result[value.shotID] = value
        }
        return result
    }

    private static func snapshot(paths: Set<String>, dataRoot: URL) throws -> Snapshot {
        try requireSafe(paths: paths, dataRoot: dataRoot)
        var bytes: [String: Data?] = [:]
        for path in paths {
            let url = PipelineLayout.url(path, in: dataRoot)
            let data: Data? = FileManager.default.fileExists(atPath: url.path)
                ? try Data(contentsOf: url)
                : nil
            bytes.updateValue(data, forKey: path)
        }
        return Snapshot(bytesByPath: bytes)
    }

    private static func publicationPaths(shotIDs: Set<String>) -> Set<String> {
        var paths: Set<String> = [
            PipelineLayout.assetGraphFile,
            PipelineLayout.productionInputsPublicationFile,
        ]
        for shotID in shotIDs {
            paths.insert(PipelineLayout.referenceDemandSetFile(shotID: shotID))
            paths.insert(PipelineLayout.productionInputTemplateFile(shotID: shotID))
        }
        return paths
    }

    private static func requireSafe(paths: Set<String>, dataRoot: URL) throws {
        let root = dataRoot.standardizedFileURL
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: root.path)) == nil else {
            throw PipelineProductionInputsError.unsafePath(root.path)
        }
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !NSString(string: path).isAbsolutePath,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw PipelineProductionInputsError.unsafePath(path)
            }
            var current = root
            for component in components {
                current.appendPathComponent(String(component))
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                    throw PipelineProductionInputsError.unsafePath(path)
                }
            }
        }
    }

    private static func verifyPersisted(
        graphData: Data,
        demandDataByShotID: [String: Data],
        templateDataByShotID: [String: Data],
        publicationData: Data,
        dataRoot: URL
    ) throws {
        guard try read(PipelineLayout.assetGraphFile, dataRoot: dataRoot) == graphData,
              try read(
                  PipelineLayout.productionInputsPublicationFile,
                  dataRoot: dataRoot
              ) == publicationData else {
            throw PipelineProductionInputsError.publicationFailed(
                "Persisted AssetGraph or publication bytes differ from canonical bytes."
            )
        }
        for shotID in demandDataByShotID.keys {
            guard try read(
                PipelineLayout.referenceDemandSetFile(shotID: shotID),
                dataRoot: dataRoot
            ) == demandDataByShotID[shotID],
                  try read(
                      PipelineLayout.productionInputTemplateFile(shotID: shotID),
                      dataRoot: dataRoot
                  ) == templateDataByShotID[shotID] else {
                throw PipelineProductionInputsError.publicationFailed(
                    "Persisted production-input bytes differ for shot \(shotID)."
                )
            }
        }
    }

    private static func write(_ data: Data, to path: String, dataRoot: URL) throws {
        let url = PipelineLayout.url(path, in: dataRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func read(_ path: String, dataRoot: URL) throws -> Data {
        try Data(contentsOf: PipelineLayout.url(path, in: dataRoot))
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func validShotID(_ value: String) -> Bool {
        nonEmpty(value) && !value.contains("/") && value != "." && value != ".."
    }

    private static func nonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private protocol ShotScopedProductionInput {
    var shotID: String { get }
}

extension ReferenceDemandSetV1: ShotScopedProductionInput {}
extension ProductionInputTemplateV1: ShotScopedProductionInput {}
