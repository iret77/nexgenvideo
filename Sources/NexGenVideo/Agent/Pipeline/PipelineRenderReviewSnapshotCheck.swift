import Darwin
import Foundation
import NexGenEngine

struct PipelineRenderReviewSnapshotCheck: Sendable {
    private struct File: Sendable {
        let reference: CanonicalArtifactReferenceV1
        let url: URL
        let stamp: [Int64]
    }

    private let root: URL
    private let projectKey: String
    private let fence: PipelineSpatialSceneAuthority.SourceFence
    private let files: [File]

    static func capture(_ snapshot: PipelineRenderReviewWriter.Snapshot, root: URL) throws -> Self {
        let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: root, additionalCanonicalPaths: snapshot.absentPaths)
        let files = try snapshot.references.map { reference in
            let url = try ProjectLocalFile.resolve(reference.path, dataRoot: root)
            return File(reference: reference, url: url, stamp: try stamp(url))
        }
        try PipelineRenderReviewWriter.requireSnapshot(snapshot, root: root)
        let result = Self(root: root, projectKey: snapshot.projectKey, fence: fence, files: files)
        try result.requireCurrent()
        return result
    }

    func requireCurrent() throws {
        try Task.checkCancellation()
        guard ProjectIdentity.existingUUID(for: FrameInventory.projectHome(of: root)) == projectKey else { throw Self.changed() }
        try fence.requireUnchanged()
        for file in files {
            try Task.checkCancellation()
            guard try ProjectLocalFile.resolve(file.reference.path, dataRoot: root) == file.url,
                  try Self.stamp(file.url) == file.stamp else { throw Self.changed() }
        }
    }

    private static func stamp(_ url: URL) throws -> [Int64] {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw changed() }
        return [Int64(value.st_dev), Int64(bitPattern: value.st_ino), value.st_size,
            Int64(value.st_mode), Int64(value.st_nlink), Int64(value.st_uid),
            Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
            Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)]
    }

    private static func changed() -> GateBlocked { GateBlocked("The review inputs changed. Prepare the current inputs again.") }
}
