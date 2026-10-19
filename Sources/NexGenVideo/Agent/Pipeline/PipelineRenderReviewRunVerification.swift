import Foundation
import NexGenEngine

enum PipelineRenderReviewRunVerification {
    private typealias Receipt = PipelineRenderReviewRunReceipt

    struct Verified: Sendable {
        let aggregate: PipelineRenderReviewRunReceipt.Aggregate
        let references: [CanonicalArtifactReferenceV1]
        let modelID: String
        let responseID: String
    }

    private struct Child {
        let reference: CanonicalArtifactReferenceV1
        let page: Receipt.Page
        let delivery: Receipt.Delivery
        let authorization: Receipt.Authorization
    }

    static func verify(_ reference: CanonicalArtifactReferenceV1, snapshot: PipelineRenderReviewWriter.Snapshot,
                       dataRoot: URL) throws -> Verified {
        try Task.checkCancellation()
        let aggregate = try read(Receipt.Aggregate.self, reference, dataRoot: dataRoot)
        let name = (reference.path as NSString).lastPathComponent
        guard aggregate.schema == "render-review-aggregate/v2", !aggregate.completedAt.isEmpty,
              name.hasSuffix(".v2.json"), let identifier = UUID(uuidString: String(name.dropLast(8))),
              name == identifier.uuidString.lowercased() + ".v2.json" else { throw invalid() }
        try require(reference, id: aggregate.runID.uuidString.lowercased(), role: "host.render-review-aggregate",
            path: directory(aggregate.runID) + "/aggregates/" + name)
        let manifest = try read(PipelineRenderReviewManifest.self, aggregate.manifest, dataRoot: dataRoot)
        try requireManifest(manifest, reference: aggregate.manifest, dataRoot: dataRoot)
        try PipelineRenderReviewManifest.verify(manifest: manifest, snapshot: snapshot, dataRoot: dataRoot)
        let authorizations = try authorizations(aggregate.authorizations, manifest: manifest, runID: aggregate.runID, dataRoot: dataRoot)
        guard aggregate.pages.count == manifest.pages.count,
              Set((aggregate.pages + aggregate.reductions + [aggregate.synthesis]).map(\.path)).count
                == aggregate.pages.count + aggregate.reductions.count + 1 else { throw invalid() }
        var cache: [String: Child] = [:]
        var visiting = Set<String>()
        let all = aggregate.pages + aggregate.reductions + [aggregate.synthesis]
        for child in all {
            _ = try verifyChild(child, manifest: manifest, manifestReference: aggregate.manifest,
                authorizations: authorizations, runID: aggregate.runID, dataRoot: dataRoot, cache: &cache, visiting: &visiting)
        }
        for (reference, expected) in zip(aggregate.pages, manifest.pages) {
            guard let child = cache[reference.path], child.delivery.kind == .page,
                  child.delivery.pageID == expected.id else { throw invalid() }
        }
        var units = try PipelineRenderReviewSummary.units(references: aggregate.pages, dataRoot: dataRoot, includeFindings: true)
        var cursor = 0
        while units.count > PipelineRenderReviewSummary.maximumUnits {
            let previousCount = units.count
            let contexts = try PipelineRenderReviewSummary.contexts(manifestID: manifest.id, units: units, kind: .reducer)
            var level: [CanonicalArtifactReferenceV1] = []
            for context in contexts {
                guard cursor < aggregate.reductions.count else { throw invalid() }
                let reference = aggregate.reductions[cursor]
                guard let child = cache[reference.path] else { throw invalid() }
                try requireContext(context, delivery: child.delivery)
                level.append(reference)
                cursor += 1
            }
            units = try PipelineRenderReviewSummary.units(references: level, dataRoot: dataRoot, includeFindings: false)
            guard units.count < previousCount else { throw invalid() }
        }
        guard cursor == aggregate.reductions.count,
              let context = try PipelineRenderReviewSummary.contexts(manifestID: manifest.id, units: units, kind: .synthesis).first,
              let synthesis = cache[aggregate.synthesis.path] else { throw invalid() }
        try requireContext(context, delivery: synthesis.delivery)
        guard Set(cache.keys) == Set(all.map(\.path)) else { throw invalid() }
        let ordered = try all.map { reference -> Child in
            guard let child = cache[reference.path] else { throw invalid() }
            return child
        }
        try requireRunOrder(ordered, authorizationReferences: aggregate.authorizations, authorizations: authorizations)
        let findings = ordered.flatMap { $0.page.submission.namespacedFindings(reviewID: $0.reference.sha256) }
        guard try exact(aggregate.findings, findings), Set(findings.map(\.id)).count == findings.count else { throw invalid() }
        var references = [reference, aggregate.manifest] + aggregate.authorizations + snapshot.references + manifest.derivatives.map(\.reference)
        references += ordered.flatMap { [$0.reference, $0.page.delivery] + $0.delivery.sourceReceipts }
        references = try unique(references)
        for reference in references { _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot) }
        try PipelineRenderReviewWriter.requireSnapshot(snapshot, root: dataRoot)
        return .init(aggregate: aggregate, references: references,
            modelID: synthesis.page.writeEvidence.response.modelID, responseID: synthesis.page.writeEvidence.response.messageID)
    }

    static func verifyChild(_ reference: CanonicalArtifactReferenceV1, manifest: PipelineRenderReviewManifest,
                            authorizationReferences: [CanonicalArtifactReferenceV1], runID: UUID,
                            dataRoot: URL) throws -> (page: PipelineRenderReviewRunReceipt.Page, delivery: PipelineRenderReviewRunReceipt.Delivery) {
        let manifestReference = try manifestReference(manifest)
        try requireManifest(manifest, reference: manifestReference, dataRoot: dataRoot)
        let authorizations = try authorizations(authorizationReferences, manifest: manifest, runID: runID, dataRoot: dataRoot)
        var cache: [String: Child] = [:]
        var visiting = Set<String>()
        let child = try verifyChild(reference, manifest: manifest, manifestReference: manifestReference,
            authorizations: authorizations, runID: runID, dataRoot: dataRoot, cache: &cache, visiting: &visiting)
        return (child.page, child.delivery)
    }

    private static func verifyChild(_ reference: CanonicalArtifactReferenceV1, manifest: PipelineRenderReviewManifest,
        manifestReference: CanonicalArtifactReferenceV1, authorizations: [String: Receipt.Authorization], runID: UUID,
        dataRoot: URL, cache: inout [String: Child], visiting: inout Set<String>) throws -> Child {
        try Task.checkCancellation()
        if let cached = cache[reference.path] {
            guard try exact(cached.reference, reference) else { throw invalid() }
            return cached
        }
        guard visiting.insert(reference.path).inserted else { throw invalid() }
        defer { visiting.remove(reference.path) }
        let page = try read(Receipt.Page.self, reference, dataRoot: dataRoot)
        guard page.schema == "render-review-child-page/v2", isHash(page.submission.pageID),
              let authorization = authorizations[page.authorization.path],
              try exact(page.authorization, authorizationReference(authorization)),
              cache.count + visiting.count <= manifest.pages.count + authorization.maximumSynthesisContexts else { throw invalid() }
        let base = directory(runID) + "/" + authorization.id.uuidString.lowercased() + "/" + page.submission.pageID
        try require(reference, id: page.submission.pageID, role: "host.render-review-child-page", path: base + "/page.v2.json")
        try require(page.delivery, id: page.submission.pageID, role: "host.render-review-child-delivery", path: base + "/delivery.v2.json")
        let delivery = try read(Receipt.Delivery.self, page.delivery, dataRoot: dataRoot)
        guard delivery.schema == "render-review-child-delivery/v2", try exact(delivery.authorization, page.authorization),
              try exact(delivery.manifest, manifestReference), delivery.pageID == page.submission.pageID,
              Data(delivery.toolSchemasJSON.utf8) == Data(try PipelineRenderReviewRunStore.schemasJSON().utf8),
              !delivery.systemInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid() }
        try requireCalls(page: page, delivery: delivery, authorization: authorization, manifest: manifest)
        let result: ToolResult
        if delivery.kind == .page {
            let expected = try manifest.page(id: delivery.pageID)
            let scoped = manifest.items.filter { expected.itemIDs.contains($0.id) }.flatMap(\.shotIDs)
            let shotIDs = scoped.isEmpty ? manifest.snapshot.shots.map(\.shotID) : Array(Set(scoped)).sorted()
            let images = try expected.imageIDs.map { id -> Receipt.DeliveredImage in
                guard let image = manifest.derivatives.first(where: { $0.id == id }) else { throw invalid() }
                return .init(reference: image.reference, mediaType: image.mediaType,
                    width: image.width, height: image.height, byteCount: image.byteCount)
            }
            guard try exact(delivery.itemIDs, expected.itemIDs), try exact(delivery.shotIDs, shotIDs),
                  delivery.sourceReceipts.isEmpty, try exact(delivery.deliveredImages, images) else { throw invalid() }
            result = try manifest.pageContent(pageID: expected.id, dataRoot: dataRoot)
        } else {
            guard delivery.deliveredImages.isEmpty, try exact(delivery.shotIDs, manifest.snapshot.shots.map(\.shotID)),
                  !delivery.sourceReceipts.isEmpty,
                  delivery.sourceReceipts.count <= PipelineRenderReviewSummary.maximumUnits,
                  Set(delivery.sourceReceipts.map(\.path)).count == delivery.sourceReceipts.count else { throw invalid() }
            var parents: [Child] = []
            for source in delivery.sourceReceipts {
                parents.append(try verifyChild(source, manifest: manifest, manifestReference: manifestReference,
                    authorizations: authorizations, runID: runID, dataRoot: dataRoot, cache: &cache, visiting: &visiting))
            }
            let kinds = Set(parents.map { $0.delivery.kind.rawValue })
            guard kinds == [AgentReviewChildKind.page.rawValue] || kinds == [AgentReviewChildKind.reducer.rawValue] else { throw invalid() }
            let available = try PipelineRenderReviewSummary.units(references: delivery.sourceReceipts,
                dataRoot: dataRoot, includeFindings: parents[0].delivery.kind == .page)
            let context = try summaryContext(delivery.deliveredText)
            guard !context.units.isEmpty, context.units.count <= available.count,
                  try (0...(available.count - context.units.count)).contains(where: { start in
                      try exact(Array(available[start..<(start + context.units.count)]), context.units)
                  }), let rebuilt = try PipelineRenderReviewSummary.contexts(manifestID: manifest.id,
                    units: context.units, kind: delivery.kind).first, try exact(rebuilt, context) else { throw invalid() }
            try requireContext(context, delivery: delivery)
            result = try context.content()
        }
        try page.submission.validate(manifestID: manifest.id, pageID: delivery.pageID, itemIDs: delivery.itemIDs,
            shotIDs: Set(delivery.shotIDs), references: manifest.snapshot.references, kind: delivery.kind)
        try requireDeliveredResult(result, delivery: delivery, authorization: authorization)
        let child = Child(reference: reference, page: page, delivery: delivery, authorization: authorization)
        cache[reference.path] = child
        return child
    }

    private static func requireCalls(page: Receipt.Page, delivery: Receipt.Delivery,
                                     authorization: Receipt.Authorization, manifest: PipelineRenderReviewManifest) throws {
        let read = delivery.readEvidence, write = page.writeEvidence
        let expectedBootstrap = "Review only the bound \(delivery.kind.rawValue) context \(delivery.pageID) in manifest \(manifest.id). "
            + "First call get_render_review_page with {}. After reading its result, call write_render_review_page in a later response. "
            + "Return one specific observation per item and any additional findings. Never accept a finding or claim unseen motion or audio."
        guard Data(delivery.bootstrap.utf8) == Data(expectedBootstrap.utf8),
              read.runID == authorization.runID, read.authID == authorization.id,
              read.manifestID == manifest.id, read.pageID == delivery.pageID, read.kind == delivery.kind,
              read.projectID == manifest.snapshot.projectKey,
              read.bootstrapSHA256 == FileDigest.sha256(of: Data(delivery.bootstrap.utf8)),
              read.runID == write.runID, read.authID == write.authID, read.manifestID == write.manifestID,
              read.pageID == write.pageID, read.kind == write.kind, read.originalChatID == write.originalChatID,
              read.projectID == write.projectID, read.projectGenerationID == write.projectGenerationID,
              read.workingCopyGeneration == write.workingCopyGeneration, read.generationID == write.generationID,
              read.bootstrapSHA256 == write.bootstrapSHA256,
              read.response.sessionID == write.response.sessionID, read.response.turnID == write.response.turnID,
              read.response.messageID != write.response.messageID, read.response.toolUseID != write.response.toolUseID,
              read.response.modelID == write.response.modelID,
              delivery.requestedModelID.map({ $0 == read.response.modelID }) ?? (authorization.backend == AgentBackend.claudeCode.rawValue),
              authorization.requestedModelID.map({ $0 == read.response.modelID }) ?? (authorization.backend == AgentBackend.claudeCode.rawValue)
        else { throw invalid() }
        try requireCall(read.response, tool: AgentReviewChildRequest.readTool, backend: authorization.backend)
        try requireCall(write.response, tool: AgentReviewChildRequest.writeTool, backend: authorization.backend)
        guard Data(read.response.toolInputJSON.utf8) == Data("{}".utf8),
              try exact(Receipt.decodeSubmission(write.response.toolInputJSON), page.submission) else { throw invalid() }
    }

    private static func requireCall(_ response: AgentModelResponseEvidence, tool: String, backend: String) throws {
        let name = backend == AgentBackend.claudeCode.rawValue ? "mcp__nexgen__" + tool : tool
        guard response.toolName == name, !response.toolUseID.isEmpty, !response.messageID.isEmpty,
              !response.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.toolInputSHA256 == (try AgentModelResponseEvidence.inputHash(response.toolInputJSON)) else { throw invalid() }
        let object = try JSONSerialization.jsonObject(with: Data(response.toolInputJSON.utf8))
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard Data(response.toolInputJSON.utf8) == canonical else { throw invalid() }
    }

    private static func requireDeliveredResult(_ result: ToolResult, delivery: Receipt.Delivery,
                                               authorization: Receipt.Authorization) throws {
        let text = result.content.compactMap { block -> String? in
            if case .text(let value) = block { return value }; return nil
        }.joined(separator: "\n")
        let imageTokens = delivery.deliveredImages.reduce(0) { $0 + (($1.width * $1.height + 749) / 750) + 256 }
        let header = delivery.bootstrap.utf8.count + delivery.systemInstructions.utf8.count + delivery.toolSchemasJSON.utf8.count
        let estimated = header + text.utf8.count + imageTokens + 1_024
        let resultBytes = try JSONEncoder().encode(result.toMCPResult()).count
        guard Data(text.utf8) == Data(delivery.deliveredText.utf8), delivery.toolResultSHA256 == (try Receipt.contentSHA256(result.content)),
              resultBytes <= authorization.bounds.maximumToolResultBytes,
              resultBytes + header + 1_024 <= authorization.bounds.maximumRequestBytes,
              estimated <= authorization.bounds.maximumEstimatedInputTokens else { throw invalid() }
    }

    private static func requireRunOrder(_ children: [Child], authorizationReferences: [CanonicalArtifactReferenceV1],
                                        authorizations: [String: Receipt.Authorization]) throws {
        guard let first = children.first else { throw invalid() }
        let model = first.page.writeEvidence.response.modelID
        var authorizationIndex = 0
        var contexts: [String: AgentReviewChildCallEvidence] = [:]
        var generations = Set<UUID>(), sessions = Set<UUID>(), turns = Set<UUID>()
        for (index, child) in children.enumerated() {
            let evidence = child.delivery.readEvidence
            guard let authIndex = try authorizationReferences.firstIndex(where: { try exact($0, child.page.authorization) }), authIndex >= authorizationIndex,
                  child.page.writeEvidence.response.modelID == model,
                  index == 0 || child.delivery.requestedModelID == model,
                  generations.insert(evidence.generationID).inserted,
                  sessions.insert(evidence.response.sessionID).inserted, turns.insert(evidence.response.turnID).inserted else { throw invalid() }
            authorizationIndex = authIndex
            if let previous = contexts[child.page.authorization.path] {
                guard previous.originalChatID == evidence.originalChatID,
                      previous.projectGenerationID == evidence.projectGenerationID,
                      previous.workingCopyGeneration == evidence.workingCopyGeneration else { throw invalid() }
            }
            contexts[child.page.authorization.path] = evidence
        }
        guard let backend = authorizations[authorizationReferences[0].path]?.backend,
              authorizations.values.allSatisfy({ $0.backend == backend && ($0.requestedModelID.map { $0 == model } ?? (backend == AgentBackend.claudeCode.rawValue)) }),
              children.filter({ $0.delivery.kind != .page }).count <= first.authorization.maximumSynthesisContexts else { throw invalid() }
    }

    private static func requireContext(_ context: PipelineRenderReviewSummary.Context, delivery: Receipt.Delivery) throws {
        guard context.schema == "render-review-summary-context/v2", context.manifestID == delivery.manifest.id,
              context.kind == delivery.kind, context.id == delivery.pageID,
              try exact(context.itemIDs, delivery.itemIDs), try exact(context.sourceReceipts, delivery.sourceReceipts),
              delivery.deliveredImages.isEmpty,
              try Receipt.contentSHA256(context.content().content) == Receipt.contentSHA256([.text(delivery.deliveredText)]) else { throw invalid() }
    }

    private static func summaryContext(_ text: String) throws -> PipelineRenderReviewSummary.Context {
        guard let newline = text.firstIndex(of: "\n") else { throw invalid() }
        return try JSONDecoder().decode(PipelineRenderReviewSummary.Context.self,
            from: Data(text[text.index(after: newline)...].utf8))
    }

    private static func authorizations(_ references: [CanonicalArtifactReferenceV1], manifest: PipelineRenderReviewManifest,
        runID: UUID, dataRoot: URL) throws -> [String: Receipt.Authorization] {
        guard !references.isEmpty, Set(references.map(\.path)).count == references.count else { throw invalid() }
        let manifestReference = try manifestReference(manifest)
        var result: [String: Receipt.Authorization] = [:]
        for reference in references {
            let authorization = try read(Receipt.Authorization.self, reference, dataRoot: dataRoot)
            guard authorization.schema == "render-review-authorization/v2", authorization.runID == runID,
                  try exact(authorization.manifest, manifestReference), authorization.pageCount == manifest.pages.count,
                  authorization.maximumSynthesisContexts == (try PipelineRenderReviewSummary.maximumContexts(pageCount: manifest.pages.count)),
                  authorization.bounds == PipelineRenderReviewRunStore.bounds(),
                  !authorization.approvedAt.isEmpty, !authorization.costDescription.isEmpty,
                  [AgentBackend.claudeCode.rawValue, AgentBackend.anthropicAPI.rawValue].contains(authorization.backend),
                  authorization.requestedModelID.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    ?? (authorization.backend == AgentBackend.claudeCode.rawValue),
                  try exact(reference, authorizationReference(authorization)) else { throw invalid() }
            result[reference.path] = authorization
        }
        return result
    }

    private static func requireManifest(_ manifest: PipelineRenderReviewManifest, reference: CanonicalArtifactReferenceV1,
                                        dataRoot: URL) throws {
        guard manifest.schema == PipelineRenderReviewManifest.schemaVersion, isHash(manifest.id),
              try exact(reference, manifestReference(manifest)),
              try exact(read(PipelineRenderReviewManifest.self, reference, dataRoot: dataRoot), manifest) else { throw invalid() }
    }

    private static func manifestReference(_ value: PipelineRenderReviewManifest) throws -> CanonicalArtifactReferenceV1 {
        PlanningWriterIO.reference("render-review/manifests/\(value.id).v2.json", id: value.id,
            role: "host.render-review-manifest", bytes: try PlanningWriterIO.json(value))
    }

    private static func authorizationReference(_ value: Receipt.Authorization) throws -> CanonicalArtifactReferenceV1 {
        let id = value.id.uuidString.lowercased()
        return PlanningWriterIO.reference(directory(value.runID) + "/authorizations/" + id + ".v2.json",
            id: id, role: "host.render-review-authorization", bytes: try PlanningWriterIO.json(value))
    }

    private static func read<T: Codable>(_ type: T.Type, _ reference: CanonicalArtifactReferenceV1, dataRoot: URL) throws -> T {
        try Task.checkCancellation()
        let value = try PipelineRenderReviewRunStore.read(type, reference, dataRoot: dataRoot)
        guard reference.sha256 == FileDigest.sha256(of: try PlanningWriterIO.json(value)) else { throw invalid() }
        return value
    }

    private static func exact<T: Encodable>(_ lhs: T, _ rhs: T) throws -> Bool {
        try PlanningWriterIO.json(lhs) == PlanningWriterIO.json(rhs)
    }

    private static func require(_ reference: CanonicalArtifactReferenceV1, id: String, role: String, path: String) throws {
        guard reference.id == id, reference.role == role, reference.path == path, isHash(reference.sha256) else { throw invalid() }
    }

    private static func directory(_ runID: UUID) -> String { "render-review/runs/" + runID.uuidString.lowercased() }

    private static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func unique(_ references: [CanonicalArtifactReferenceV1]) throws -> [CanonicalArtifactReferenceV1] {
        var paths: [String: CanonicalArtifactReferenceV1] = [:]
        for reference in references {
            if let previous = paths[reference.path], previous.sha256 != reference.sha256 { throw invalid() }
            if paths[reference.path] == nil { paths[reference.path] = reference }
        }
        return paths.values.sorted { $0.path < $1.path }
    }

    private static func invalid() -> GateBlocked {
        GateBlocked("The model review does not preserve its authorized exact inputs, complete child evidence and original findings.")
    }
}
