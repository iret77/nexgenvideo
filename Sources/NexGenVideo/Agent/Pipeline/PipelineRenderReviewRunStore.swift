import Foundation
import NexGenEngine

enum PipelineRenderReviewRunStore {
    enum Status: String, Codable, Sendable { case running, interrupted, failed, completed }

    struct Journal: Codable, Sendable, Equatable {
        let schema: String
        let runID: UUID
        let manifest: CanonicalArtifactReferenceV1
        let backend: String
        var modelID: String?
        var authorizations: [CanonicalArtifactReferenceV1]
        var children: [CanonicalArtifactReferenceV1]
        var status: Status
        var message: String?
    }

    static func journalPath(manifestID: String) -> String {
        "render-review/runs/\(manifestID)/current.v2.json"
    }

    static func load(manifest: CanonicalArtifactReferenceV1, dataRoot: URL) throws -> Journal? {
        let path = journalPath(manifestID: manifest.id)
        let url = dataRoot.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { return nil }
        guard try ProjectLocalFile.resolve(path, dataRoot: dataRoot).standardizedFileURL == url.standardizedFileURL else {
            throw GateBlocked("The review progress is outside its project location.")
        }
        let value = try PlanningWriterIO.read(Journal.self, at: path, dataRoot: dataRoot)
        guard value.schema == "render-review-run/v2", value.manifest == manifest,
              Set(value.children.map(\.path)).count == value.children.count,
              Set(value.authorizations.map(\.path)).count == value.authorizations.count else {
            throw GateBlocked("The saved review progress does not match these inputs.")
        }
        for reference in value.authorizations {
            let authorization = try read(PipelineRenderReviewRunReceipt.Authorization.self, reference, dataRoot: dataRoot)
            guard authorization.runID == value.runID, authorization.manifest == manifest,
                  authorization.backend == value.backend else { throw GateBlocked("The saved review authorization changed.") }
        }
        return value
    }

    static func save(_ journal: Journal, dataRoot: URL) throws {
        let paths = progressPaths(journal)
        let bytes = try PlanningWriterIO.json(journal)
        for path in paths {
            let parent = try ProjectLocalFile.ensureDirectory((path as NSString).deletingLastPathComponent, dataRoot: dataRoot)
            let target = parent.appendingPathComponent((path as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil {
                guard try ProjectLocalFile.resolve(path, dataRoot: dataRoot).standardizedFileURL == target.standardizedFileURL else {
                    throw GateBlocked("The review progress location changed.")
                }
            }
        }
        try ArtifactTransaction.perform(paths: paths.map { dataRoot.appendingPathComponent($0) }, dataRoot: dataRoot) {
            for path in paths { try bytes.write(to: dataRoot.appendingPathComponent(path), options: .atomic) }
        }
    }

    static func recordPage(_ page: PipelineRenderReviewRunReceipt.Page, journal: Journal,
                           dataRoot: URL) throws -> (reference: CanonicalArtifactReferenceV1, journal: Journal) {
        guard journal.authorizations.contains(page.authorization), page.writeEvidence.runID == journal.runID,
              page.submission.manifestID == journal.manifest.id,
              journal.modelID.map({ $0 == page.writeEvidence.response.modelID }) ?? true else {
            throw GateBlocked("The review page does not belong to its current authorized run.")
        }
        let path = "render-review/runs/\(journal.runID.uuidString.lowercased())/\(page.writeEvidence.authID.uuidString.lowercased())/\(page.submission.pageID)/page.v2.json"
        let reference = PlanningWriterIO.reference(path, id: page.submission.pageID, role: "host.render-review-child-page",
            bytes: try PlanningWriterIO.json(page))
        guard !journal.children.contains(where: { $0.path == path }) else {
            throw GateBlocked("The review page is already recorded in this run.")
        }
        var updated = journal
        updated.modelID = page.writeEvidence.response.modelID
        updated.children.append(reference)
        try ArtifactTransaction.perform(paths: ([path] + progressPaths(journal)).map { dataRoot.appendingPathComponent($0) }, dataRoot: dataRoot) {
            _ = try PipelineRenderReviewRunReceipt.publish(page, path: path, id: reference.id, role: reference.role, dataRoot: dataRoot)
            try save(updated, dataRoot: dataRoot)
        }
        return (reference, updated)
    }

    private static func progressPaths(_ journal: Journal) -> [String] {
        ["render-review/runs/\(journal.runID.uuidString.lowercased())/progress.v2.json", journalPath(manifestID: journal.manifest.id)]
    }

    static func read<T: Decodable>(_ type: T.Type, _ reference: CanonicalArtifactReferenceV1, dataRoot: URL) throws -> T {
        let url = try ProjectLocalFile.resolve(reference.path, dataRoot: dataRoot)
        guard url.standardizedFileURL == dataRoot.appendingPathComponent(reference.path).standardizedFileURL else {
            throw GateBlocked("A review receipt is outside its exact project location.")
        }
        let bytes = try Data(contentsOf: url)
        guard FileDigest.sha256(of: bytes) == reference.sha256 else { throw GateBlocked("A review receipt changed after it was recorded.") }
        return try JSONDecoder().decode(type, from: bytes)
    }

    static func publish(_ prepared: PipelineRenderReviewManifest.Prepared, dataRoot: URL) throws {
        for file in prepared.files {
            try Task.checkCancellation()
            let path = file.reference.path
            let directory = try ProjectLocalFile.ensureDirectory((path as NSString).deletingLastPathComponent, dataRoot: dataRoot)
            let destination = directory.appendingPathComponent((path as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                let existing = try ProjectLocalFile.requireHash(file.reference.sha256, at: path, dataRoot: dataRoot)
                guard existing.standardizedFileURL == destination.standardizedFileURL else {
                    throw GateBlocked("A review input moved outside its exact project location.")
                }
                continue
            }
            let staged = directory.appendingPathComponent(".review-input-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staged) }
            try PipelineGeometryVideoExport.copyVerified(source: file.url, to: staged, expectedSHA256: file.reference.sha256)
            try Task.checkCancellation()
            try FileManager.default.linkItem(at: staged, to: destination)
        }
    }

    static func schemasJSON() throws -> String {
        let objects: [[String: Any]] = PipelineRenderReviewRunReceipt.tools.map {
            ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    static func bounds() -> AgentReviewChildBounds {
        .init(maximumRequests: 4, maximumRequestBytes: 18 * 1_024 * 1_024,
            maximumToolResultBytes: PipelineRenderReviewManifest.maximumResultBytes,
            maximumEstimatedInputTokens: 131_072, maximumOutputTokens: 16_384,
            maximumMCPOutputTokens: PipelineRenderReviewManifest.maximumMCPOutputTokens, maximumTurns: 4)
    }
}
