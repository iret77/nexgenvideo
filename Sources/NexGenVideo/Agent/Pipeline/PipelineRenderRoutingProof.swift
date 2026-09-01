import Foundation
import NexGenEngine

struct PipelineRenderRoutingProofEntryV1: Codable, Sendable, Equatable {
    let shotID: String
    let output: String
    let outputSHA256: String
    let generation: ProductionGenerationRoutingProofV1

    private enum CodingKeys: String, CodingKey {
        case shotID = "shot_id"
        case output
        case outputSHA256 = "output_sha256"
        case generation
    }
}

struct PipelineRenderRoutingProofManifestV1: Codable, Sendable, Equatable {
    static let schemaVersion = "render-routing-proof/v1"

    let schema: String
    let project: String
    let phase: String
    var entries: [String: PipelineRenderRoutingProofEntryV1]

    init(
        project: String,
        phase: String,
        entries: [String: PipelineRenderRoutingProofEntryV1] = [:]
    ) {
        schema = Self.schemaVersion
        self.project = project
        self.phase = phase
        self.entries = entries
    }
}

enum PipelineRenderRoutingProofStore {
    static func load(
        dataRoot: URL,
        phase: String
    ) throws -> PipelineRenderRoutingProofManifestV1 {
        let path = PipelineLayout.renderRoutingProofFile(phase: phase)
        let url = PipelineLayout.url(path, in: dataRoot)
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(
            ProjectMeta.self,
            at: PipelineLayout.projectFile
        ).project
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PipelineRenderRoutingProofManifestV1(
                project: project,
                phase: phase
            )
        }
        let manifest = try JSONArtifactStore(dataRoot: dataRoot).load(
            PipelineRenderRoutingProofManifestV1.self,
            at: path
        )
        try validate(manifest, project: project, phase: phase)
        return manifest
    }

    static func save(
        _ manifest: PipelineRenderRoutingProofManifestV1,
        dataRoot: URL
    ) throws {
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(
            ProjectMeta.self,
            at: PipelineLayout.projectFile
        ).project
        try validate(manifest, project: project, phase: manifest.phase)
        try JSONArtifactStore(dataRoot: dataRoot).save(
            manifest,
            to: PipelineLayout.renderRoutingProofFile(phase: manifest.phase)
        )
    }

    private static func validate(
        _ manifest: PipelineRenderRoutingProofManifestV1,
        project: String,
        phase: String
    ) throws {
        guard manifest.schema == PipelineRenderRoutingProofManifestV1.schemaVersion,
              manifest.project == project,
              manifest.phase == phase,
              !manifest.phase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.entries.allSatisfy({ item in
                  let entry = item.value
                  return item.key == entry.shotID
                      && entry.generation.shotID == item.key
                      && entry.generation.projectID == project
                      && entry.generation.schema
                          == ProductionGenerationRoutingProofV1.schemaVersion
                      && !entry.output.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty
                      && entry.outputSHA256.count == 64
                      && entry.outputSHA256.allSatisfy(\.isHexDigit)
              }) else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "The \(phase) render-routing proof has invalid identity."
            )
        }
    }
}
