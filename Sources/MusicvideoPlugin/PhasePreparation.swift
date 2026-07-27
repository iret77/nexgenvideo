import Foundation
import NexGenEngine

enum MusicvideoPhasePreparation {
    static func frames(dataRoot: URL) throws {
        guard let shotlist = try loadShotlist(dataRoot: dataRoot) else {
            throw GateBlocked(
                "Can't prepare Frames: the approved shot list is missing."
            )
        }
        let url = PipelineLayout.url(
            PipelineLayout.framesManifestFile,
            in: dataRoot
        )
        let manifest: FramesManifest
        if FileManager.default.fileExists(atPath: url.path) {
            manifest = try loadFramesManifest(dataRoot: dataRoot)
        } else {
            manifest = FramesManifest(
                project: shotlist.project,
                generated: currentTimestamp()
            )
        }
        guard manifest.schema == framesSchemaVersion else {
            throw GateBlocked(
                "Can't prepare Frames: unsupported manifest schema "
                    + "\"\(manifest.schema)\"."
            )
        }
        try saveFramesManifest(
            try manifest.reconciled(with: shotlist),
            dataRoot: dataRoot
        )
    }

    static func render(dataRoot: URL) throws {
        guard let shotlist = try loadShotlist(dataRoot: dataRoot) else {
            throw GateBlocked(
                "Can't prepare Render: the approved shot list is missing."
            )
        }
        var manifest = try loadRenderManifest(
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
        manifest.entries = manifest.entries.filter {
            required.contains($0.key)
        }
        var proof = try loadRenderProofManifest(
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
        proof.entries = proof.entries.filter {
            required.contains($0.key)
        }
        try saveRenderManifest(manifest, dataRoot: dataRoot)
        try saveRenderProofManifest(proof, dataRoot: dataRoot)
    }
}
