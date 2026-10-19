import Foundation
import NexGenEngine

struct PipelineBlockoutRemovalSnapshot: Sendable {
    let draft: ShotPlanningDraftV1
    let storyboard: StoryboardBundleSnapshot
    let sha256: String
    let shotIDs: Set<String>

    static func load(dataRoot: URL, shotIDs requested: Set<String>? = nil) throws -> Self {
        let board = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(ShotPlanningDraftV1.currentPath, dataRoot: dataRoot))
        let draft = try JSONDecoder().decode(ShotPlanningDraftV1.self, from: bytes)
        try ShotPlanningValidatorV1.validate(draft, timing: board.timing)
        guard bytes == (try Data(contentsOf: ProjectLocalFile.resolve(ShotPlanningDraftV1.versionPath(draft.header.revision), dataRoot: dataRoot))),
              try PlanningWriterIO.nextRevision(directory: "shot-planning", suffix: ".v1.json", dataRoot: dataRoot) == draft.header.revision + 1,
              board.references.filter({ $0.role == "core.storyboard-bundle" }).allSatisfy({ ref in
                  draft.header.inputs.contains { $0.path == ref.path && $0.sha256 == ref.sha256 }
              }) else { throw changed() }
        let ids = requested ?? Set(draft.shots.filter { $0.camera.blockingReference != nil }.map(\.shotID))
        let after = try PipelineShotPlanningEditor.removingBlockouts(shotIDs: ids, from: draft)
        let receipts = draft.shots.filter { ids.contains($0.shotID) }.compactMap(\.camera.blockingReference)
        for ref in draft.header.inputs where !(try removable(ref, receipts: receipts)) {
            _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: dataRoot)
        }
        let inputs = try PipelineShotPlanningWriter.currentInputs(shots: after, storyboard: board, dataRoot: dataRoot)
        let validated = ShotPlanningDraftV1(header: .init(projectID: draft.header.projectID,
            revision: draft.header.revision, origin: .userRevision, inputs: inputs),
            storyboardRevision: draft.storyboardRevision, shots: after)
        try ShotPlanningValidatorV1.validate(validated, timing: board.timing)
        try validated.header.requireCurrentInputs(dataRoot: dataRoot)
        try PipelineShotPlanningWriter.requireSpatialInputs(validated, dataRoot: dataRoot)
        return .init(draft: draft, storyboard: board, sha256: FileDigest.sha256(of: bytes), shotIDs: ids)
    }

    static func removable(_ reference: CanonicalArtifactReferenceV1, receipts: [CanonicalArtifactReferenceV1]) throws -> Bool {
        var ids = Set<String>()
        for receipt in receipts {
            let name = (receipt.path as NSString).lastPathComponent
            guard name.hasSuffix(".v1.json"), receipt.role == "host.native-blockout" else { throw changed() }
            let id = String(name.dropLast(".v1.json".count))
            guard UUID(uuidString: id) != nil, receipt.path == "shot-planning/native-blockouts/" + id + ".v1.json" else { throw changed() }
            if reference == receipt { return true }
            ids.insert(id)
        }
        let parts = reference.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "execution", parts[1] == "blockout", UUID(uuidString: parts[2]) != nil,
              ids.contains(where: { parts[3] == "native-" + $0 }) else { return false }
        return (parts[4] == "blockout.mov" && ["host.plan-elevation-video", "core.shot-blockout-video"].contains(reference.role))
            || (parts[4] == "original.mov" && reference.role == "host.blockout-original")
            || (reference.role == "host.evaluated-geometry" && (["evaluated-geometry.v1.json", "evaluated-scene-operations.py",
                "evaluated-worker.py", "evaluated-runtime-lock.json", "evaluated-runtime-record.csv"].contains(parts[4])
                || parts[4].range(of: "^evaluated-command-(0|[1-9][0-9]*)\\.py\\z", options: .regularExpression) != nil
                || parts[4].range(of: "^evaluated-(bounds|verification)-(0|[1-9][0-9]*)\\.v1\\.json\\z", options: .regularExpression) != nil))
    }

    private static func changed() -> GateBlocked { GateBlocked("The blockout recovery snapshot changed. Reload Shot Planning before removing assignments.") }
}
