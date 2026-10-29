import Foundation
import NexGenEngine

enum PipelineGenerationEvidenceSnapshot {
    enum Area: String, Sendable { case storyboard, frames }

    struct Snapshot: Sendable {
        let outputReceipt: CanonicalArtifactReferenceV1
        let package: CanonicalArtifactReferenceV1
        let output: CanonicalArtifactReferenceV1
        let files: [(path: String, bytes: Data)]
        var references: [CanonicalArtifactReferenceV1] { [outputReceipt, package, output] }

        func unpublishedFiles(dataRoot: URL) throws -> [(path: String, bytes: Data)] {
            var seen = Set<String>()
            return try files.filter { file in
                guard seen.insert(file.path).inserted else { return false }
                let url = dataRoot.appendingPathComponent(file.path)
                if FileManager.default.fileExists(atPath: url.path)
                    || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                    _ = try PipelineGenerationEvidenceSnapshot.requireExact(FileDigest.sha256(of: file.bytes), path: file.path, root: dataRoot)
                    return false
                }
                return true
            }
        }
    }

    static func capture(completed: GenerationOutputReceipt, receipt: CanonicalArtifactReferenceV1,
                        home: URL, area: Area) throws -> Snapshot {
        guard try GenerationOutputReceipt.load(assetID: completed.assetID, home: home) == completed,
              receipt.path == GenerationOutputReceipt.path(assetID: completed.assetID) else {
            throw GateBlocked("The source generation receipt changed before its pipeline evidence was captured.")
        }
        let originals = [receipt, completed.package, completed.output]
        let mirrors = originals.map { reference(mirroring: $0, area: area) }
        let files = try zip(originals, mirrors).map { original, mirror in
            let bytes = try Data(contentsOf: requireExact(original.sha256, path: original.path, root: home))
            guard FileDigest.sha256(of: bytes) == mirror.sha256 else {
                throw GateBlocked("The generated media changed while its exact evidence was being captured.")
            }
            return (path: mirror.path, bytes: bytes)
        }
        return Snapshot(outputReceipt: mirrors[0], package: mirrors[1], output: mirrors[2], files: files)
    }

    static func reference(mirroring original: CanonicalArtifactReferenceV1, area: Area) -> CanonicalArtifactReferenceV1 {
        .init(id: original.id, role: original.role,
              path: area.rawValue + "/generation-evidence/" + original.sha256 + ".bin", sha256: original.sha256)
    }

    static func require(_ mirror: CanonicalArtifactReferenceV1, original: CanonicalArtifactReferenceV1,
                        home: URL, dataRoot: URL, area: Area) throws {
        guard mirror == reference(mirroring: original, area: area) else {
            throw GateBlocked("The pipeline evidence does not name the exact original generation artifact.")
        }
        _ = try requireExact(original.sha256, path: original.path, root: home)
        _ = try requireExact(mirror.sha256, path: mirror.path, root: dataRoot)
    }

    static func requireExact(_ hash: String, path: String, root: URL) throws -> URL {
        let resolved = try ProjectLocalFile.requireHash(hash, at: path, dataRoot: root)
        guard resolved.standardizedFileURL == root.appendingPathComponent(path).standardizedFileURL else {
            throw GateBlocked("The evidence was found outside its declared project namespace.")
        }
        return resolved
    }

    static func requireReferences(originals: [CanonicalArtifactReferenceV1], inputs: [CanonicalArtifactReferenceV1],
        home: URL, dataRoot: URL, area: Area) throws -> [CanonicalArtifactReferenceV1] {
        let mirrors = originals.map { reference(mirroring: $0, area: area) }
        if mirrors.allSatisfy({ inputs.contains($0) }) {
            for (original, mirror) in zip(originals, mirrors) {
                try require(mirror, original: original, home: home, dataRoot: dataRoot, area: area)
            }
            return mirrors
        }
        guard originals.allSatisfy({ inputs.contains($0) }) else {
            throw GateBlocked("The generation evidence is incomplete.")
        }
        for original in originals { _ = try requireExact(original.sha256, path: original.path, root: home) }
        return originals
    }
}
