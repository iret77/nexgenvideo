import Foundation
import NexGenEngine

struct PipelineRenderTakeV1: Codable, Sendable, Equatable {
    let schema: String
    let id: String
    let project: String
    let phase: String
    let shotID: String
    let plannedGenerationID: String
    let promptRevisionID: String
    let generationEventID: String
    let generationInput: GenerationInput
    let provenance: RenderPublishedArtifactV1
    let output: RenderPublishedArtifactV1
    let recordedAt: String
}

struct PipelineTakeSelectionV1: Codable, Sendable, Equatable {
    let id: String
    let shotID: String
    let takeID: String?
    let reason: String
    let recordedAt: String
}

struct PipelineTakeIndexV1: Codable, Sendable, Equatable {
    let schema: String
    let project: String
    let phase: String
    var takeIDs: [String]
    var decisions: [PipelineTakeSelectionV1]

    var selected: [String: String] {
        var result: [String: String] = [:]
        for decision in decisions { result[decision.shotID] = decision.takeID }
        return result
    }
}

enum PipelineRenderTakeStore {
    struct Completed: Sendable {
        let eventID: String
        let generationInput: GenerationInput
        let reviewedSelection: Bool
        init(eventID: String, generationInput: GenerationInput, reviewedSelection: Bool = false) {
            self.eventID = eventID
            self.generationInput = generationInput
            self.reviewedSelection = reviewedSelection
        }
    }
    struct Prepared {
        let files: [(path: String, data: Data)]
        let takeID: String?
    }

    static func indexPath(phase: String) -> String { "renders/takes/index-\(phase).v1.json" }
    static func takePath(id: String, phase: String) -> String { "renders/takes/\(phase)/\(id).v1.json" }

    static func isRecoveryPath(_ path: String, phase: String) -> Bool {
        guard ["preview", "final"].contains(phase) else { return false }
        if path == indexPath(phase: phase) { return true }
        let prefix = "renders/takes/\(phase)/"
        let suffix = ".v1.json"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return false }
        let id = path.dropFirst(prefix.count).dropLast(suffix.count)
        return id.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func load(dataRoot: URL, project: String, phase: String) throws -> PipelineTakeIndexV1 {
        guard ["frames", "preview", "final"].contains(phase) else { throw ToolError("Unknown render phase.") }
        if phase == "frames" { return .init(schema: "take-index/v1", project: project, phase: phase, takeIDs: [], decisions: []) }
        let path = indexPath(phase: phase)
        let url = dataRoot.appendingPathComponent(path)
        let archivedIDs = try archivedTakeIDs(dataRoot: dataRoot, phase: phase)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { throw ToolError("Take index cannot be a symbolic link.") }
            guard archivedIDs.isEmpty else { throw ToolError("The take index is missing while immutable takes remain. Restore the index before continuing.") }
            return .init(schema: "take-index/v1", project: project, phase: phase, takeIDs: [], decisions: [])
        }
        let value = try JSONDecoder().decode(PipelineTakeIndexV1.self, from: Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
        guard value.schema == "take-index/v1", value.project == project, value.phase == phase,
              Set(value.takeIDs) == archivedIDs, Set(value.takeIDs).count == value.takeIDs.count,
              Set(value.decisions.map(\.id)).count == value.decisions.count else {
            throw ToolError("Take history has invalid identity or duplicate entries.")
        }
        var shots: [String: String] = [:]
        for id in value.takeIDs {
            let record = try take(id: id, dataRoot: dataRoot, phase: phase)
            guard record.project == project, record.phase == phase else { throw ToolError("Take history crosses project or phase boundaries.") }
            shots[id] = record.shotID
        }
        for decision in value.decisions {
            guard !decision.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError("Take decisions need a reason.") }
            if let id = decision.takeID, shots[id] != decision.shotID { throw ToolError("Take selection references a different or missing shot.") }
        }
        return value
    }

    static func take(id: String, dataRoot: URL, phase: String? = nil) throws -> PipelineRenderTakeV1 {
        try safeID(id)
        let phases = phase.map { [$0] } ?? ["preview", "final"]
        guard phases.allSatisfy({ ["preview", "final"].contains($0) }) else { throw ToolError("Only video render phases have takes.") }
        let paths = phases.map { takePath(id: id, phase: $0) }.filter {
            FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent($0).path)
        }
        guard paths.count == 1, let path = paths.first else { throw ToolError("The take is missing or recorded in more than one phase. Restore its original history before continuing.") }
        let value = try JSONDecoder().decode(PipelineRenderTakeV1.self,
            from: Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
        guard value.schema == "render-take/v1", value.id == id, phases.contains(value.phase),
              value.id == identity(eventID: value.generationEventID, outputSHA256: value.output.sha256) else {
            throw ToolError("Take identity does not match its generation event and output.")
        }
        let proofURL = try ProjectLocalFile.requireHash(value.provenance.sha256, at: value.provenance.path, dataRoot: dataRoot)
        let proof = try JSONDecoder().decode(RenderShotProvenanceProofV1.self, from: Data(contentsOf: proofURL))
        let routing = try proof.routingProofEntry.map { try JSONDecoder().decode(PipelineRenderRoutingProofEntryV1.self, from: $0) }
        guard proof.project == value.project, proof.phase == value.phase, proof.shotID == value.shotID,
              proof.outputs.contains(value.output), proof.renderProofEntry?.providerPrompt == value.generationInput.prompt,
              proof.renderProofEntry?.generationModel == value.generationInput.model,
              value.generationInput.promptShotId == value.shotID,
              routing?.generation == value.generationInput.productionRouting,
              value.promptRevisionID == (try promptRevision(value.generationInput)),
              value.plannedGenerationID == plannedIdentity(input: value.generationInput, project: value.project, shotID: value.shotID) else {
            throw ToolError("Take metadata does not match its immutable source proof.")
        }
        return value
    }

    static func prepare(completed: Completed?, provenance: RenderPublishedArtifactV1?, shotProof: RenderShotProvenanceProofV1?,
                        manifest: RenderManifest, shotID: String, dataRoot: URL) throws -> Prepared {
        var index = try load(dataRoot: dataRoot, project: manifest.project, phase: manifest.phase)
        var files: [(path: String, data: Data)] = []
        var takeID: String?
        if let completed {
            guard !completed.eventID.isEmpty, let provenance, let proof = shotProof,
                  let entry = manifest.entries[shotID], entry.status == .rendered, let output = entry.output,
                  completed.generationInput.promptShotId == shotID,
                  completed.generationInput.promptShotFingerprint?.isEmpty == false else {
                throw ToolError("A take needs the completed generation event and exact shot compile identity.")
            }
            guard let outputProof = proof.outputs.first(where: { $0.path == output }), proof.shotID == shotID,
                  proof.project == manifest.project, proof.phase == manifest.phase,
                  proof.renderProofEntry?.providerPrompt == completed.generationInput.prompt,
                  proof.renderProofEntry?.generationModel == completed.generationInput.model else {
                throw ToolError("Take output is absent from the immutable render proof.")
            }
            let id = identity(eventID: completed.eventID, outputSHA256: outputProof.sha256)
            takeID = id
            if !index.takeIDs.contains(id) {
                let record = PipelineRenderTakeV1(schema: "render-take/v1", id: id, project: manifest.project,
                    phase: manifest.phase, shotID: shotID,
                    plannedGenerationID: plannedIdentity(input: completed.generationInput, project: manifest.project, shotID: shotID),
                    promptRevisionID: try promptRevision(completed.generationInput), generationEventID: completed.eventID,
                    generationInput: completed.generationInput, provenance: provenance, output: outputProof, recordedAt: currentTimestamp())
                let otherPhase = manifest.phase == "preview" ? "final" : "preview"
                guard !FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(takePath(id: id, phase: otherPhase)).path) else {
                    throw ToolError("This generation is already recorded in \(otherPhase). Keep that take in its original phase. Final production needs its own generation or an explicitly planned edit/upscale; recording the same event again is not an upgrade.")
                }
                let path = takePath(id: id, phase: manifest.phase)
                guard !FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(path).path) else {
                    throw ToolError("An unindexed immutable take already occupies this event identity. Restore the take index before retrying.")
                }
                files.append((path, try canonical(record)))
                index.takeIDs.append(id)
            } else {
                let prior = try take(id: id, dataRoot: dataRoot)
                guard prior.shotID == shotID, prior.output == outputProof,
                      prior.generationInput == completed.generationInput else {
                    throw ToolError("A recorded generation event cannot be rebound to different inputs.")
                }
            }
        }
        if index.selected[shotID] != takeID {
            index.decisions.append(.init(id: UUID().uuidString.lowercased(), shotID: shotID, takeID: takeID,
                reason: takeID == nil ? "Render result cleared; historical takes retained."
                    : completed?.reviewedSelection == true ? "Selected the reviewed take." : "Recorded candidate; quality review remains pending.", recordedAt: currentTimestamp()))
        }
        if !files.isEmpty || !index.takeIDs.isEmpty { files.append((indexPath(phase: manifest.phase), try canonical(index))) }
        return Prepared(files: files, takeID: takeID)
    }

    static func identity(eventID: String, outputSHA256: String) -> String {
        FileDigest.sha256(of: Data((eventID + "\n" + outputSHA256).utf8))
    }

    private static func plannedIdentity(input: GenerationInput, project: String, shotID: String) -> String {
        FileDigest.sha256(of: Data([project, shotID, input.promptShotFingerprint ?? "",
            input.productionRouting?.requirementSHA256 ?? "frame"].joined(separator: "\n").utf8))
    }

    private static func promptRevision(_ input: GenerationInput) throws -> String {
        var revision = input
        revision.createdAt = nil; revision.spendTransactionId = nil; revision.imageURLs = nil
        revision.referenceImageURLs = nil; revision.referenceVideoURLs = nil; revision.referenceAudioURLs = nil
        return FileDigest.sha256(of: try canonical(revision))
    }

    private static func archivedTakeIDs(dataRoot: URL, phase: String) throws -> Set<String> {
        let directory = dataRoot.appendingPathComponent("renders/takes/\(phase)")
        guard directory.resolvingSymlinksInPath() == dataRoot.resolvingSymlinksInPath().appendingPathComponent("renders/takes/\(phase)") else {
            throw ToolError("Take history cannot traverse symbolic links.")
        }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var ids: Set<String> = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            guard name.hasSuffix(".v1.json"), !name.hasPrefix("index-") else { continue }
            let id = String(name.dropLast(".v1.json".count))
            let record = try take(id: id, dataRoot: dataRoot, phase: phase)
            if record.phase == phase { ids.insert(id) }
        }
        return ids
    }

    private static func safeID(_ id: String) throws {
        guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ToolError("Invalid take path identity.")
        }
    }

    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
