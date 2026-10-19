import Foundation
import NexGenEngine

enum PipelineRenderReviewSummary {
    static let maximumUnits = 4
    static let segmentBytes = 4_096
    static let maximumPageUnits = 16
    static let maximumReducerUnits = 2

    struct Unit: Codable, Sendable, Equatable {
        let id: String
        let source: CanonicalArtifactReferenceV1
        let ordinal: Int
        let count: Int
        let text: String
    }

    struct Context: Codable, Sendable, Equatable {
        let schema: String
        let manifestID: String
        let id: String
        let kind: AgentReviewChildKind
        let units: [Unit]

        var itemIDs: [String] { units.map(\.id) }
        var sourceReceipts: [CanonicalArtifactReferenceV1] {
            var seen = Set<String>()
            return units.map(\.source).filter { seen.insert($0.path).inserted }
        }

        func content() throws -> ToolResult {
            .ok("Review these labelled excerpts from completed child reviews. Each input item requires one observation of at most 512 UTF-8 bytes. "
                + "The host preserves every original finding independently of these summaries. Add concerns; never erase, replace or accept earlier findings. "
                + "Excerpts may begin or end inside a record; their labels identify their original page and order. "
                + "This is a text synthesis, not a new visual inspection. No motion, audio or deferred predecessor video was observed.\n"
                + String(decoding: try PlanningWriterIO.json(self), as: UTF8.self))
        }
    }

    static func units(references: [CanonicalArtifactReferenceV1], dataRoot: URL, includeFindings: Bool) throws -> [Unit] {
        try references.flatMap { reference in
            let page = try PipelineRenderReviewRunStore.read(PipelineRenderReviewRunReceipt.Page.self, reference, dataRoot: dataRoot)
            return try units(reference: reference, submission: page.submission, includeFindings: includeFindings)
        }
    }

    static func units(reference: CanonicalArtifactReferenceV1, submission: PipelineRenderReviewRunReceipt.Submission,
                      includeFindings: Bool) throws -> [Unit] {
        let chunks = try chunks(submission, includeFindings: includeFindings)
        return try chunks.enumerated().map { ordinal, text in
            let id = FileDigest.sha256(of: try PlanningWriterIO.json([reference.sha256, String(ordinal), text]))
            return Unit(id: id, source: reference, ordinal: ordinal, count: chunks.count, text: text)
        }
    }

    static func requireBounded(_ submission: PipelineRenderReviewRunReceipt.Submission, kind: AgentReviewChildKind) throws {
        _ = try chunks(submission, includeFindings: true)
        if kind != .page { _ = try chunks(submission, includeFindings: false) }
    }

    private static func chunks(_ submission: PipelineRenderReviewRunReceipt.Submission, includeFindings: Bool) throws -> [String] {
        struct Summary: Encodable {
            let manifestID: String
            let pageID: String
            let observations: [PipelineRenderReviewRunReceipt.Observation]
        }
        let bytes: Data
        if includeFindings { bytes = try PlanningWriterIO.json(submission) }
        else {
            bytes = try PlanningWriterIO.json(Summary(manifestID: submission.manifestID,
                pageID: submission.pageID, observations: submission.observations))
        }
        let chunks = split(String(decoding: bytes, as: UTF8.self))
        guard chunks.count <= (includeFindings ? maximumPageUnits : maximumReducerUnits) else {
            throw GateBlocked("The review response exceeds its authorized summary size. Use shorter observations or findings.")
        }
        return chunks
    }

    static func contexts(manifestID: String, units: [Unit], kind: AgentReviewChildKind) throws -> [Context] {
        guard !units.isEmpty, kind != .page, kind != .synthesis || units.count <= maximumUnits else {
            throw GateBlocked("The review synthesis has no bounded complete input set.")
        }
        return try stride(from: 0, to: units.count, by: maximumUnits).map { start in
            let group = Array(units[start..<min(start + maximumUnits, units.count)])
            struct Identity: Encodable { let manifest: String; let kind: AgentReviewChildKind; let units: [Unit] }
            let id = FileDigest.sha256(of: try PlanningWriterIO.json(Identity(manifest: manifestID, kind: kind, units: group)))
            return Context(schema: "render-review-summary-context/v2", manifestID: manifestID, id: id, kind: kind, units: group)
        }
    }

    static func maximumContexts(pageCount: Int) throws -> Int {
        let initial = pageCount.multipliedReportingOverflow(by: maximumPageUnits)
        guard pageCount > 0, !initial.overflow else { throw GateBlocked("The review page count is invalid.") }
        var count = initial.partialValue
        var total = 1
        while count > maximumUnits {
            let groups = (count - 1) / maximumUnits + 1
            let sum = total.addingReportingOverflow(groups)
            let next = groups.multipliedReportingOverflow(by: maximumReducerUnits)
            guard !sum.overflow, !next.overflow, next.partialValue < count else { throw GateBlocked("The review summary bounds are invalid.") }
            total = sum.partialValue
            count = next.partialValue
        }
        return total
    }

    private static func split(_ text: String) -> [String] {
        var chunks: [String] = []
        var chunk = String.UnicodeScalarView()
        var size = 0
        for scalar in text.unicodeScalars {
            if size + scalar.utf8.count > segmentBytes {
                chunks.append(String(chunk)); chunk = String.UnicodeScalarView(); size = 0
            }
            chunk.append(scalar); size += scalar.utf8.count
        }
        if !chunk.isEmpty || chunks.isEmpty { chunks.append(String(chunk)) }
        return chunks
    }
}
