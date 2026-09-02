import Foundation
import NexGenEngine

enum MusicvideoPhasePreparation {
    static func frames(dataRoot: URL) throws {
        guard let shotlist = try loadShotlist(dataRoot: dataRoot) else {
            throw GateBlocked(
                "Can't prepare Frames: the approved shot list is missing."
            )
        }
        let manifest = try loadFramesManifest(dataRoot: dataRoot)
        let renderManifest = try loadRenderManifest(
            dataRoot: dataRoot,
            phase: "frames"
        )
        let reconciled = try manifest.reconciled(
            with: shotlist,
            generated: manifest.generated
        )
        let frameShotIDs = Set(manifest.shots.compactMap { shot in
            shot.frames.isEmpty ? nil : shot.shotId
        })
        let renderedShotIDs = Set(renderManifest.entries.compactMap { item in
            item.value.status == .rendered ? item.key : nil
        })
        guard manifest.schema == framesSchemaVersion,
              manifest == reconciled,
              renderManifest.project == shotlist.project,
              renderManifest.phase == "frames",
              frameShotIDs == renderedShotIDs,
              renderManifest.entries.allSatisfy({ item in
                  item.value.status != .rendered
                      || (item.value.output.map { output in
                          manifest.shot(item.key)?.frames.contains {
                              $0.path == output
                          } == true
                      } == true)
              }) else {
            throw GateBlocked(
                "Can't prepare Frames: the host reconciliation is incomplete."
            )
        }
        _ = try requirePublication(
            phase: "frames",
            project: shotlist.project,
            dataRoot: dataRoot
        )
    }

    static func render(dataRoot: URL) throws {
        guard let shotlist = try loadShotlist(dataRoot: dataRoot) else {
            throw GateBlocked(
                "Can't prepare Render: the approved shot list is missing."
            )
        }
        let manifest = try loadRenderManifest(
            dataRoot: dataRoot,
            phase: "final"
        )
        guard manifest.schema_ == renderManifestSchemaVersion,
              manifest.phase == "final",
              manifest.project == shotlist.project else {
            throw GateBlocked(
                "Can't prepare Render: the final manifest has invalid identity."
            )
        }
        let required = Set(
            shotlist.shots
                .filter { $0.sourceMode != .imported }
                .map(\.id)
        )
        let proof = try loadRenderProofManifest(
            dataRoot: dataRoot,
            phase: "final"
        )
        guard proof.schema == renderProofSchemaVersion,
              proof.phase == "final",
              proof.project == shotlist.project else {
            throw GateBlocked(
                "Can't prepare Render: the final provenance has invalid identity."
            )
        }
        let rendered = Set(manifest.entries.compactMap { item in
            item.value.status == .rendered ? item.key : nil
        })
        guard Set(manifest.entries.keys).isSubset(of: required),
              Set(proof.entries.keys) == rendered else {
            throw GateBlocked(
                "Can't prepare Render: the host reconciliation is incomplete."
            )
        }
        _ = try requirePublication(
            phase: "final",
            project: shotlist.project,
            dataRoot: dataRoot
        )
    }

    private static func requirePublication(
        phase: String,
        project: String,
        dataRoot: URL
    ) throws -> RenderRecordPublicationV1 {
        let path = RenderRecordPublicationV1.artifactPath(phase: phase)
        let url = PipelineLayout.url(path, in: dataRoot)
        let data = try Data(contentsOf: url)
        let publication = try JSONDecoder().decode(
            RenderRecordPublicationV1.self,
            from: data
        )
        guard publication.schema == RenderRecordPublicationV1.schemaVersion,
              publication.project == project,
              publication.phase == phase,
              publication.renderManifest.path
                == PipelineLayout.renderManifestFile(phase: phase),
              publication.renderProof?.path
                == (phase == "frames"
                    ? nil
                    : PipelineLayout.renderProofFile(phase: phase)),
              publication.renderRoutingProof?.path
                == (phase == "frames"
                    ? nil
                    : PipelineLayout.renderRoutingProofFile(phase: phase)),
              publication.framesManifest?.path
                == (phase == "frames" ? PipelineLayout.framesManifestFile : nil)
        else {
            throw GateBlocked(
                "Can't prepare \(phase): the host publication has invalid identity."
            )
        }
        var artifacts = [publication.renderManifest]
        if let proof = publication.renderProof { artifacts.append(proof) }
        if let routing = publication.renderRoutingProof { artifacts.append(routing) }
        if let frames = publication.framesManifest { artifacts.append(frames) }
        for artifact in artifacts {
            let artifactData = try Data(
                contentsOf: PipelineLayout.url(artifact.path, in: dataRoot)
            )
            guard artifact.sha256 == FileDigest.sha256(of: artifactData) else {
                throw GateBlocked(
                    "Can't prepare \(phase): \(artifact.path) is outside its publication."
                )
            }
        }
        return publication
    }
}
