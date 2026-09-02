import Foundation

public struct RenderShotProvenanceProofV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "render-shot-provenance-proof/v1"

    public let schema: String
    public let project: String
    public let phase: String
    public let shotID: String
    public let renderEntry: RenderEntry
    public let renderProofEntry: RenderProofEntry?
    public let routingProofEntry: Data?
    public let frames: ShotFrames?
    public let lastFrame: RenderLastFrameProofV1?
    public let outputs: [RenderPublishedArtifactV1]
    public let dependencies: [RenderPublishedArtifactV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case project
        case phase
        case shotID = "shot_id"
        case renderEntry = "render_entry"
        case renderProofEntry = "render_proof_entry"
        case routingProofEntry = "routing_proof_entry"
        case frames
        case lastFrame = "last_frame"
        case outputs
        case dependencies
    }

    public init(
        project: String,
        phase: String,
        shotID: String,
        renderEntry: RenderEntry,
        renderProofEntry: RenderProofEntry?,
        routingProofEntry: Data?,
        frames: ShotFrames?,
        lastFrame: RenderLastFrameProofV1?,
        outputs: [RenderPublishedArtifactV1],
        dependencies: [RenderPublishedArtifactV1] = []
    ) {
        schema = Self.schemaVersion
        self.project = project
        self.phase = phase
        self.shotID = shotID
        self.renderEntry = renderEntry
        self.renderProofEntry = renderProofEntry
        self.routingProofEntry = routingProofEntry
        self.frames = frames
        self.lastFrame = lastFrame
        self.outputs = outputs
        self.dependencies = dependencies
    }

    public static func artifactPath(
        phase: String,
        shotID: String,
        sha256: String
    ) -> String {
        "renders/provenance/\(phase)/\(shotID)/\(sha256).v1.json"
    }
}

public struct RenderShotProvenancePublicationV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "render-shot-provenance-publication/v1"

    public let schema: String
    public let transactionID: String
    public let project: String
    public let phase: String
    public let proofs: [String: RenderPublishedArtifactV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case transactionID = "transaction_id"
        case project
        case phase
        case proofs
    }

    public init(
        transactionID: String,
        project: String,
        phase: String,
        proofs: [String: RenderPublishedArtifactV1]
    ) {
        schema = Self.schemaVersion
        self.transactionID = transactionID
        self.project = project
        self.phase = phase
        self.proofs = proofs
    }

    public static func artifactPath(phase: String) -> String {
        "renders/provenance-publication-\(phase).v1.json"
    }
}

public enum RenderShotProvenanceValidationErrorV1: Error, Sendable, Equatable {
    case unsupportedSchema(String)
    case invalidIdentity
    case invalidRenderProof
    case invalidFramesProof
    case invalidLastFrameProof
    case invalidArtifactPath
    case invalidPublication
}

public enum RenderShotProvenanceValidatorV1 {
    public static func validate(_ proof: RenderShotProvenanceProofV1) throws {
        guard proof.schema == RenderShotProvenanceProofV1.schemaVersion else {
            throw RenderShotProvenanceValidationErrorV1.unsupportedSchema(
                proof.schema
            )
        }
        guard nonEmpty(proof.project),
              ["frames", "preview", "final"].contains(proof.phase),
              validPathSegment(proof.phase),
              validPathSegment(proof.shotID),
              Set(proof.outputs.map(\.path)).count == proof.outputs.count,
              proof.outputs.allSatisfy({
                  validArtifactPath($0.path) && validSHA256($0.sha256)
              }),
              proof.outputs == proof.outputs.sorted(by: {
                  if $0.path != $1.path { return $0.path < $1.path }
                  return $0.sha256 < $1.sha256
              }),
              Set(proof.dependencies.map(\.path)).count
                == proof.dependencies.count,
              proof.dependencies.allSatisfy({
                  validArtifactPath($0.path) && validSHA256($0.sha256)
              }),
              proof.dependencies == proof.dependencies.sorted(by: {
                  if $0.path != $1.path { return $0.path < $1.path }
                  return $0.sha256 < $1.sha256
              }),
              proof.renderEntry.shotId == proof.shotID,
              proof.renderEntry.phase == proof.phase,
              proof.renderEntry.status == .rendered,
              nonEmpty(proof.renderEntry.output),
              nonEmpty(proof.renderEntry.updatedAt) else {
            throw RenderShotProvenanceValidationErrorV1.invalidIdentity
        }

        if proof.phase == "frames" {
            guard proof.renderProofEntry == nil,
                  proof.routingProofEntry == nil,
                  proof.lastFrame == nil,
                  proof.dependencies.isEmpty,
                  let frames = proof.frames,
                  frames.shotId == proof.shotID,
                  !frames.frames.isEmpty,
                  Set(frames.frames.map(\.role)).count == frames.frames.count,
                  Set(proof.outputs.map(\.path))
                    == Set(frames.frames.map(\.path)),
                  frames.frames.allSatisfy({ frame in
                      proof.outputs.contains(where: { $0.path == frame.path })
                  }),
                  frames.frames.contains(where: {
                      $0.path == proof.renderEntry.output
                  }) else {
                throw RenderShotProvenanceValidationErrorV1.invalidFramesProof
            }
            return
        }

        guard proof.frames == nil,
              let renderProof = proof.renderProofEntry,
              let routingProof = proof.routingProofEntry,
              !routingProof.isEmpty,
              renderProof.shotId == proof.shotID,
              renderProof.output == proof.renderEntry.output,
              validSHA256(renderProof.outputSha256),
              proof.outputs.contains(RenderPublishedArtifactV1(
                  path: renderProof.output,
                  sha256: renderProof.outputSha256
              )),
              nonEmpty(renderProof.providerPrompt),
              nonEmpty(renderProof.generationModel) else {
            throw RenderShotProvenanceValidationErrorV1.invalidRenderProof
        }
        let directInputs = [
            renderProof.sourceVideo,
            renderProof.startFrame,
            renderProof.endFrame,
        ].compactMap { $0 }
            + renderProof.referenceImages
            + renderProof.referenceVideos
            + renderProof.referenceAudio
        guard directInputs.allSatisfy({ input in
            proof.dependencies.contains(where: {
                $0.path == input.path && $0.sha256 == input.sha256
            })
        }) else {
            throw RenderShotProvenanceValidationErrorV1.invalidRenderProof
        }
        if let lastFrame = proof.lastFrame {
            guard lastFrame.shotID == proof.shotID,
                  lastFrame.phase == proof.phase,
                  lastFrame.sourceOutput == renderProof.output,
                  lastFrame.sourceOutputSHA256 == renderProof.outputSha256,
                  proof.renderEntry.lastFramePath == lastFrame.path,
                  validSHA256(lastFrame.sha256),
                  proof.outputs.contains(RenderPublishedArtifactV1(
                      path: lastFrame.path,
                      sha256: lastFrame.sha256
                  )),
                  lastFrame.extractor == RenderLastFrameProofV1.extractorID,
                  nonEmpty(lastFrame.extractedAt) else {
                throw RenderShotProvenanceValidationErrorV1.invalidLastFrameProof
            }
        } else if proof.renderEntry.lastFramePath != nil {
            throw RenderShotProvenanceValidationErrorV1.invalidLastFrameProof
        }
        let expectedOutputPaths = Set(
            [renderProof.output] + [proof.lastFrame?.path].compactMap { $0 }
        )
        guard Set(proof.outputs.map(\.path)) == expectedOutputPaths else {
            throw RenderShotProvenanceValidationErrorV1.invalidRenderProof
        }
    }

    public static func validate(
        _ proof: RenderShotProvenanceProofV1,
        artifactPath: String,
        artifactSHA256: String
    ) throws {
        try validate(proof)
        guard validSHA256(artifactSHA256),
              artifactPath == RenderShotProvenanceProofV1.artifactPath(
                  phase: proof.phase,
                  shotID: proof.shotID,
                  sha256: artifactSHA256
              ) else {
            throw RenderShotProvenanceValidationErrorV1.invalidArtifactPath
        }
    }

    public static func validate(
        _ publication: RenderShotProvenancePublicationV1
    ) throws {
        guard publication.schema
                == RenderShotProvenancePublicationV1.schemaVersion,
              UUID(uuidString: publication.transactionID) != nil,
              nonEmpty(publication.project),
              ["frames", "preview", "final"].contains(publication.phase),
              publication.proofs.allSatisfy({ shotID, artifact in
                  validPathSegment(shotID)
                      && validSHA256(artifact.sha256)
                      && artifact.path == RenderShotProvenanceProofV1.artifactPath(
                          phase: publication.phase,
                          shotID: shotID,
                          sha256: artifact.sha256
                      )
              }) else {
            throw RenderShotProvenanceValidationErrorV1.invalidPublication
        }
    }

    private static func nonEmpty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validPathSegment(_ value: String) -> Bool {
        nonEmpty(value)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.contains("/")
            && value != "."
            && value != ".."
    }

    private static func validArtifactPath(_ value: String) -> Bool {
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return nonEmpty(value)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !NSString(string: value).isAbsolutePath
            && components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
            })
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy(\.isHexDigit)
            && value == value.lowercased()
    }
}
