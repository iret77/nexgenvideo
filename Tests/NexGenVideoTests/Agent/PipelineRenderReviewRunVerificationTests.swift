import Foundation
import NexGenEngine
import XCTest
@testable import NexGenVideo

final class PipelineRenderReviewRunVerificationTests: XCTestCase {
    private typealias Manifest = PipelineRenderReviewManifest
    private typealias Receipt = PipelineRenderReviewRunReceipt
    private typealias Verifier = PipelineRenderReviewRunVerification

    @MainActor
    func testCanonicalGraphPreservesEveryPageReductionAndFinding() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeImportedAssembly()
        defer { context.document.close() }
        let snapshot = try await PipelineRenderReviewWriter.capture(editor: context.editor)
        let prepared = try Manifest.prepare(snapshot: snapshot, dataRoot: context.dataRoot)
        defer { prepared.discard() }
        try PipelineRenderReviewRunStore.publish(prepared, dataRoot: context.dataRoot)
        for backend in [AgentBackend.anthropicAPI, .claudeCode] {
            let fixture = try Fixture(manifest: prepared.manifest, root: context.dataRoot, backend: backend)
            let aggregate = try fixture.aggregate()
            let reference = try fixture.publish(aggregate)
            let verified = try Verifier.verify(reference, snapshot: snapshot, dataRoot: fixture.root)
            XCTAssertEqual(verified.modelID, Fixture.model)
            XCTAssertEqual(try PlanningWriterIO.json(verified.aggregate.findings), try PlanningWriterIO.json(aggregate.findings))
            XCTAssertTrue(verified.references.contains(prepared.reference))
            XCTAssertEqual(aggregate.pages.count, prepared.manifest.pages.count)
            XCTAssertFalse(aggregate.reductions.isEmpty)
            XCTAssertEqual(aggregate.findings.count, aggregate.pages.count + aggregate.reductions.count + 1)
            for page in aggregate.pages {
                _ = try Verifier.verifyChild(page, manifest: fixture.manifest, authorizationReferences: [fixture.authorization],
                    runID: fixture.runID, dataRoot: fixture.root)
            }
            for field in ["pages", "reductions", "findings"] {
                let altered: Receipt.Aggregate = try changing(aggregate) { object in
                    var values = try XCTUnwrap(object[field] as? [Any])
                    XCTAssertFalse(values.isEmpty)
                    values.removeFirst()
                    object[field] = values
                }
                XCTAssertThrowsError(try Verifier.verify(fixture.publish(altered), snapshot: snapshot, dataRoot: fixture.root))
            }
            let reordered: Receipt.Aggregate = try changing(aggregate) { object in
                object["pages"] = Array(try XCTUnwrap(object["pages"] as? [Any]).reversed())
            }
            XCTAssertThrowsError(try Verifier.verify(fixture.publish(reordered), snapshot: snapshot, dataRoot: fixture.root))
            let changed: Receipt.Aggregate = try changing(aggregate) { object in
                var findings = try XCTUnwrap(object["findings"] as? [[String: Any]])
                findings[0]["message"] = "Altered original concern"
                object["findings"] = findings
            }
            XCTAssertThrowsError(try Verifier.verify(fixture.publish(changed), snapshot: snapshot, dataRoot: fixture.root))
        }
    }

    func testExactChildCallsAndDeliveredContentRejectMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixture(manifest: minimalManifest(), root: root, backend: .claudeCode)
        let reference = try fixture.page(try XCTUnwrap(fixture.manifest.pages.first), first: true)
        _ = try Verifier.verifyChild(reference, manifest: fixture.manifest, authorizationReferences: [fixture.authorization],
            runID: fixture.runID, dataRoot: root)
        for key in ["sessionID", "turnID", "messageID", "toolUseID", "modelID", "toolName", "toolInputSHA256"] {
            try rejects(fixture, reference: reference, pageMutation: { object in
                var write = try XCTUnwrap(object["writeEvidence"] as? [String: Any])
                var response = try XCTUnwrap(write["response"] as? [String: Any])
                let delivery = try PipelineRenderReviewRunStore.read(Receipt.Delivery.self,
                    JSONDecoder().decode(CanonicalArtifactReferenceV1.self,
                        from: JSONSerialization.data(withJSONObject: try XCTUnwrap(object["delivery"]))), dataRoot: root)
                switch key {
                case "sessionID", "turnID": response[key] = UUID().uuidString
                case "messageID": response[key] = delivery.readEvidence.response.messageID
                case "toolUseID": response[key] = delivery.readEvidence.response.toolUseID
                case "toolName": response[key] = "mcp__other__write_render_review_page"
                default: response[key] = "changed"
                }
                write["response"] = response; object["writeEvidence"] = write
            })
        }
        for key in ["runID", "authID", "generationID", "projectGenerationID", "workingCopyGeneration", "originalChatID"] {
            try rejects(fixture, reference: reference, pageMutation: { object in
                var write = try XCTUnwrap(object["writeEvidence"] as? [String: Any])
                write[key] = UUID().uuidString; object["writeEvidence"] = write
            })
        }
        try rejects(fixture, reference: reference, pageMutation: { object in
            var submission = try XCTUnwrap(object["submission"] as? [String: Any])
            var observations = try XCTUnwrap(submission["observations"] as? [[String: Any]])
            let original = try XCTUnwrap(observations[0]["text"] as? String)
            observations[0]["text"] = original.precomposedStringWithCanonicalMapping
            XCTAssertNotEqual(Data(original.utf8), Data(try XCTUnwrap(observations[0]["text"] as? String).utf8))
            submission["observations"] = observations; object["submission"] = submission
        })
        for key in ["bootstrap", "deliveredText", "toolSchemasJSON", "toolResultSHA256"] {
            try rejects(fixture, reference: reference, deliveryMutation: { $0[key] = "changed" })
        }
        try rejects(fixture, reference: reference, deliveryMutation: { object in
            let text = try XCTUnwrap(object["deliveredText"] as? String)
            let normalized = text.precomposedStringWithCanonicalMapping
            XCTAssertNotEqual(Data(text.utf8), Data(normalized.utf8))
            object["deliveredText"] = normalized
        })
        try rejects(fixture, reference: reference, deliveryMutation: { $0["requestedModelID"] = "another-model" })
        try rejects(fixture, reference: reference, deliveryMutation: { $0["itemIDs"] = [] })
    }

    func testSummaryMustKeepExactSourceUnitsAndCanonicalReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixture(manifest: minimalManifest(), root: root, backend: .anthropicAPI)
        let page = try fixture.page(try XCTUnwrap(fixture.manifest.pages.first), first: true)
        let units = try PipelineRenderReviewSummary.units(references: [page], dataRoot: root, includeFindings: true)
        let context = try XCTUnwrap(PipelineRenderReviewSummary.contexts(manifestID: fixture.manifest.id,
            units: units, kind: .synthesis).first)
        let summary = try fixture.summary(context)
        _ = try Verifier.verifyChild(summary, manifest: fixture.manifest, authorizationReferences: [fixture.authorization],
            runID: fixture.runID, dataRoot: root)
        try rejects(fixture, reference: summary, deliveryMutation: { $0["sourceReceipts"] = [] })
        try rejects(fixture, reference: summary, deliveryMutation: { object in
            let text = try XCTUnwrap(object["deliveredText"] as? String)
            object["deliveredText"] = text.replacingOccurrences(of: "Observed", with: "Suppressed")
        })
        let original = try Data(contentsOf: root.appendingPathComponent(page.path))
        defer { try? original.write(to: root.appendingPathComponent(page.path)) }
        try Data("changed underlying child receipt".utf8).write(to: root.appendingPathComponent(page.path))
        XCTAssertThrowsError(try Verifier.verifyChild(summary, manifest: fixture.manifest,
            authorizationReferences: [fixture.authorization], runID: fixture.runID, dataRoot: root))
    }

    private func rejects(_ fixture: Fixture, reference: CanonicalArtifactReferenceV1,
                         pageMutation: ((inout [String: Any]) throws -> Void)? = nil,
                         deliveryMutation: ((inout [String: Any]) throws -> Void)? = nil) throws {
        let originalPage = try PipelineRenderReviewRunStore.read(Receipt.Page.self, reference, dataRoot: fixture.root)
        let pageURL = fixture.root.appendingPathComponent(reference.path)
        let deliveryURL = fixture.root.appendingPathComponent(originalPage.delivery.path)
        let pageBytes = try Data(contentsOf: pageURL), deliveryBytes = try Data(contentsOf: deliveryURL)
        defer { try? pageBytes.write(to: pageURL); try? deliveryBytes.write(to: deliveryURL) }
        let altered: Receipt.Page = try changing(originalPage) { object in
            if let deliveryMutation {
                let original = try JSONDecoder().decode(Receipt.Delivery.self, from: deliveryBytes)
                let modified: Receipt.Delivery = try changing(original, mutation: deliveryMutation)
                let bytes = try PlanningWriterIO.json(modified)
                try bytes.write(to: deliveryURL)
                let reference = PlanningWriterIO.reference(originalPage.delivery.path, id: originalPage.delivery.id,
                    role: originalPage.delivery.role, bytes: bytes)
                object["delivery"] = try JSONSerialization.jsonObject(with: PlanningWriterIO.json(reference))
            }
            try pageMutation?(&object)
        }
        let bytes = try PlanningWriterIO.json(altered)
        try bytes.write(to: pageURL)
        let changed = PlanningWriterIO.reference(reference.path, id: reference.id, role: reference.role, bytes: bytes)
        XCTAssertThrowsError(try Verifier.verifyChild(changed, manifest: fixture.manifest,
            authorizationReferences: [fixture.authorization], runID: fixture.runID, dataRoot: fixture.root))
    }

    private func changing<T: Codable>(_ value: T, mutation: (inout [String: Any]) throws -> Void) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: PlanningWriterIO.json(value)) as? [String: Any])
        try mutation(&object)
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func minimalManifest() throws -> Manifest {
        let empty = PlanningWriterIO.reference("planning/fixture.json", id: "fixture", role: "fixture", bytes: Data())
        let shot = ExecutionShotV1(id: "shot-1", sourceMode: .imported, startState: .init(summary: "Initial"),
            endState: .init(summary: "Final"), primaryAction: "Observed e\u{301} action", camera: .init(movementID: "core.static"), renderability: .green)
        let projection = ProductionPlanProjectionV1(header: .init(projectID: "fixture", revision: 1, origin: .userRevision, inputs: []),
            timebase: .init(ticksPerSecond: 24, fpsNumerator: 24), mode: .generic,
            executionPlan: .init(id: "fixture", projectID: "fixture", creativeContext: empty, shots: [shot]),
            timings: [.init(shotID: shot.id, startTicks: 0, durationTicks: 48)], sourceBindings: [],
            draftReference: empty, storyboardReference: empty)
        let snapshot = PipelineRenderReviewWriter.Snapshot(fingerprint: FileDigest.sha256(of: try PlanningWriterIO.json(projection)),
            workflow: try .core(.current), projectKey: "fixture", projection: projection,
            shots: [.init(shotID: shot.id, sourceMode: .imported, compiledPrompt: nil, modelID: nil, sourceInput: nil, sourceInputRange: nil,
                review: .init(shotID: shot.id, evidence: []))], references: [], absentPaths: [])
        return try Manifest.plan(snapshot: snapshot, mappings: [], derivatives: [], sourceEncodings: []) { _ in
            throw GateBlocked("No image is present in this parser fixture.")
        }
    }

    private struct Fixture {
        static let model = "fixture-model"
        let root: URL
        let manifest: Manifest
        let runID = UUID()
        let originalChatID = UUID()
        let projectGenerationID = UUID()
        let workingCopyGeneration = UUID()
        let backend: AgentBackend
        let authorization: CanonicalArtifactReferenceV1
        let manifestReference: CanonicalArtifactReferenceV1

        init(manifest: Manifest, root: URL, backend: AgentBackend) throws {
            self.root = root; self.manifest = manifest; self.backend = backend
            manifestReference = try Receipt.publish(manifest, path: "render-review/manifests/\(manifest.id).v2.json",
                id: manifest.id, role: "host.render-review-manifest", dataRoot: root)
            let auth = Receipt.Authorization(schema: "render-review-authorization/v2", id: UUID(), runID: runID,
                manifest: manifestReference, backend: backend.rawValue, requestedModelID: backend == .claudeCode ? nil : Self.model,
                phaseGrantID: nil, pageCount: manifest.pages.count,
                maximumSynthesisContexts: try PipelineRenderReviewSummary.maximumContexts(pageCount: manifest.pages.count),
                bounds: PipelineRenderReviewRunStore.bounds(), costDescription: "Parser regression fixture", approvedAt: "fixture")
            authorization = try Receipt.publish(auth,
                path: "render-review/runs/\(runID.uuidString.lowercased())/authorizations/\(auth.id.uuidString.lowercased()).v2.json",
                id: auth.id.uuidString.lowercased(), role: "host.render-review-authorization", dataRoot: root)
        }

        func aggregate() throws -> Receipt.Aggregate {
            var pages: [CanonicalArtifactReferenceV1] = []
            for (index, value) in manifest.pages.enumerated() { pages.append(try page(value, first: index == 0)) }
            var units = try PipelineRenderReviewSummary.units(references: pages, dataRoot: root, includeFindings: true)
            var reductions: [CanonicalArtifactReferenceV1] = []
            while units.count > PipelineRenderReviewSummary.maximumUnits {
                let before = units.count
                let contexts = try PipelineRenderReviewSummary.contexts(manifestID: manifest.id, units: units, kind: .reducer)
                let level = try contexts.map { try summary($0) }
                reductions += level
                units = try PipelineRenderReviewSummary.units(references: level, dataRoot: root, includeFindings: false)
                guard units.count < before else { throw GateBlocked("The test summary did not shrink.") }
            }
            let context = try XCTUnwrap(PipelineRenderReviewSummary.contexts(manifestID: manifest.id, units: units, kind: .synthesis).first)
            let synthesis = try summary(context)
            let findings = try (pages + reductions + [synthesis]).flatMap {
                try PipelineRenderReviewRunStore.read(Receipt.Page.self, $0, dataRoot: root).submission.namespacedFindings(reviewID: $0.sha256)
            }
            return .init(schema: "render-review-aggregate/v2", runID: runID, manifest: manifestReference,
                authorizations: [authorization], pages: pages, reductions: reductions, synthesis: synthesis, findings: findings, completedAt: "fixture")
        }

        func publish(_ aggregate: Receipt.Aggregate) throws -> CanonicalArtifactReferenceV1 {
            try Receipt.publish(aggregate, path: "render-review/runs/\(runID.uuidString.lowercased())/aggregates/\(UUID().uuidString.lowercased()).v2.json",
                id: runID.uuidString.lowercased(), role: "host.render-review-aggregate", dataRoot: root)
        }

        func page(_ page: Manifest.Page, first: Bool) throws -> CanonicalArtifactReferenceV1 {
            let scoped = manifest.items.filter { page.itemIDs.contains($0.id) }.flatMap(\.shotIDs)
            let shotIDs = scoped.isEmpty ? manifest.snapshot.shots.map(\.shotID) : Array(Set(scoped)).sorted()
            let images = try page.imageIDs.map { id -> Receipt.DeliveredImage in
                let image = try XCTUnwrap(manifest.derivatives.first { $0.id == id })
                return .init(reference: image.reference, mediaType: image.mediaType,
                    width: image.width, height: image.height, byteCount: image.byteCount)
            }
            return try child(kind: .page, pageID: page.id, itemIDs: page.itemIDs, shotIDs: shotIDs,
                sourceReceipts: [], images: images, result: manifest.pageContent(pageID: page.id, dataRoot: root), first: first)
        }

        func summary(_ context: PipelineRenderReviewSummary.Context) throws -> CanonicalArtifactReferenceV1 {
            try child(kind: context.kind, pageID: context.id, itemIDs: context.itemIDs,
                shotIDs: manifest.snapshot.shots.map(\.shotID), sourceReceipts: context.sourceReceipts,
                images: [], result: context.content(), first: false)
        }

        private func child(kind: AgentReviewChildKind, pageID: String, itemIDs: [String], shotIDs: [String],
                           sourceReceipts: [CanonicalArtifactReferenceV1], images: [Receipt.DeliveredImage], result: ToolResult,
                           first: Bool) throws -> CanonicalArtifactReferenceV1 {
            let auth = try PipelineRenderReviewRunStore.read(Receipt.Authorization.self, authorization, dataRoot: root)
            let bootstrap = "Review only the bound \(kind.rawValue) context \(pageID) in manifest \(manifest.id). "
                + "First call get_render_review_page with {}. After reading its result, call write_render_review_page in a later response. "
                + "Return one specific observation per item and any additional findings. Never accept a finding or claim unseen motion or audio."
            let generation = UUID(), session = UUID(), turn = UUID()
            let findings: [RenderReviewV1.Finding] = manifest.snapshot.references.first.map { reference in
                [.init(id: "concern", kind: .semanticConcern, category: .stateAndProps, shotIDs: shotIDs,
                    message: "Retain this original e\u{301} concern.", evidence: [reference])]
            } ?? []
            let submission = Receipt.Submission(manifestID: manifest.id, pageID: pageID,
                observations: itemIDs.map { .init(itemID: $0, text: "Observed e\u{301} context") }, findings: findings)
            func evidence(tool: String, json: String) throws -> AgentReviewChildCallEvidence {
                let response = try AgentModelResponseEvidence(sessionID: session, turnID: turn, messageID: UUID().uuidString,
                    modelID: Self.model, toolUseID: UUID().uuidString,
                    toolName: (backend == .claudeCode ? "mcp__nexgen__" : "") + tool, inputJSON: json)
                let encoded = EvidenceFixture(runID: runID, authID: auth.id, manifestID: manifest.id, pageID: pageID, kind: kind,
                    originalChatID: originalChatID, projectID: manifest.snapshot.projectKey, projectGenerationID: projectGenerationID,
                    workingCopyGeneration: workingCopyGeneration, generationID: generation,
                    bootstrapSHA256: FileDigest.sha256(of: Data(bootstrap.utf8)), response: response)
                return try JSONDecoder().decode(AgentReviewChildCallEvidence.self, from: PlanningWriterIO.json(encoded))
            }
            let directory = "render-review/runs/\(runID.uuidString.lowercased())/\(auth.id.uuidString.lowercased())/\(pageID)"
            let text = result.content.compactMap { block -> String? in if case .text(let text) = block { return text }; return nil }.joined(separator: "\n")
            let delivery = Receipt.Delivery(schema: "render-review-child-delivery/v2", authorization: authorization,
                manifest: manifestReference, kind: kind, pageID: pageID, itemIDs: itemIDs, shotIDs: shotIDs,
                sourceReceipts: sourceReceipts, requestedModelID: first && backend == .claudeCode ? nil : Self.model,
                bootstrap: bootstrap, systemInstructions: "Isolated receipt parser regression, not a model run.",
                toolSchemasJSON: try PipelineRenderReviewRunStore.schemasJSON(), deliveredText: text,
                deliveredImages: images, toolResultSHA256: try Receipt.contentSHA256(result.content),
                readEvidence: try evidence(tool: AgentReviewChildRequest.readTool, json: "{}"))
            let deliveryRef = try Receipt.publish(delivery, path: directory + "/delivery.v2.json", id: pageID,
                role: "host.render-review-child-delivery", dataRoot: root)
            let page = Receipt.Page(schema: "render-review-child-page/v2", authorization: authorization,
                delivery: deliveryRef, submission: submission,
                writeEvidence: try evidence(tool: AgentReviewChildRequest.writeTool, json: String(decoding: PlanningWriterIO.json(submission), as: UTF8.self)))
            return try Receipt.publish(page, path: directory + "/page.v2.json", id: pageID, role: "host.render-review-child-page", dataRoot: root)
        }
    }

    // Decoded fixtures exercise persistent evidence validation; they are not runtime-issued model proofs.
    private struct EvidenceFixture: Encodable {
        let runID: UUID
        let authID: UUID
        let manifestID: String
        let pageID: String
        let kind: AgentReviewChildKind
        let originalChatID: UUID
        let projectID: String
        let projectGenerationID: UUID
        let workingCopyGeneration: UUID
        let generationID: UUID
        let bootstrapSHA256: String
        let response: AgentModelResponseEvidence
    }
}
