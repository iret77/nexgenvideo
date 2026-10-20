import CoreGraphics
import Foundation
import NexGenEngine
import XCTest
@testable import NexGenVideo

final class PipelineRenderReviewManifestTests: XCTestCase {
    private typealias Manifest = PipelineRenderReviewManifest

    func testEveryConditioningMappingSurvivesByteDeduplicationAndEveryEdgeKeepsItsPair() throws {
        let first = try image(red: 0.2), second = try image(red: 0.8), original = try image(red: 0.4)
        let shared = reference("bible/shared.png", bytes: first.bytes)
        let alias = reference("bible/alias.png", bytes: first.bytes, role: "identity")
        let other = reference("frames/end.png", bytes: second.bytes)
        let permitted = reference("source/original.png", bytes: original.bytes)
        let snapshot = try snapshot(evidence: [[shared], [other], []], conditioning: [[alias, shared], [], []],
            chain: true, permitted: [permitted])
        let manifest = try plan(snapshot, images: [shared.sha256: first, other.sha256: second, permitted.sha256: original])
        XCTAssertEqual(manifest.derivatives.count, 3)
        XCTAssertEqual(manifest.mappings.count, 5)
        XCTAssertEqual(manifest.mappings.filter { $0.usage == .conditioning }.map(\.source), [alias, shared])
        XCTAssertEqual(manifest.mappings.filter { $0.usage == .permittedOriginalReference }.map(\.source), [permitted])
        XCTAssertEqual(Set(manifest.mappings.filter { $0.source.sha256 == shared.sha256 }.map(\.derivativeID)), [first.derivative.id])
        XCTAssertEqual(Set(manifest.pages.flatMap(\.imageIDs)), [first.derivative.id, second.derivative.id, original.derivative.id])
        XCTAssertEqual(Set(manifest.items.flatMap(\.mappingIDs)), Set(manifest.mappings.map(\.id)))
        let relations = manifest.items.compactMap(\.relation)
        XCTAssertEqual(Set(relations.filter { $0.kind == .adjacent }.map(\.edgeID)).count, 2)
        XCTAssertEqual(Set(relations.filter { $0.kind == .predecessor }.map(\.edgeID)).count, 1)
        for item in manifest.items where item.kind == .relation {
            let page = try XCTUnwrap(manifest.pages.first { $0.itemIDs.contains(item.id) })
            let relation = try XCTUnwrap(item.relation)
            XCTAssertTrue(Set([relation.fromImageID, relation.toImageID].compactMap { $0 }).isSubset(of: Set(page.imageIDs)))
            XCTAssertEqual(relation.context.count, 2)
        }
        XCTAssertTrue(relations.contains { $0.toImageID == nil && $0.limitation.contains("not established") })
        XCTAssertTrue(relations.filter { $0.kind == .predecessor }.allSatisfy { $0.limitation.contains("not an observed final predecessor video") })
    }

    func testUnicodeLongTextReassemblesExactlyAndPlanningIsDeterministic() throws {
        let text = String(repeating: "Ä 🎬 \"shot\" / état\n", count: 2_000)
        let chunks = Manifest.splitText(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= Manifest.maximumTextSegmentBytes })
        let snapshot = try snapshot(evidence: [[]], longText: text)
        let first = try plan(snapshot, images: [:]), second = try plan(snapshot, images: [:])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.id.count, 64)
        for source in first.textSources {
            let segments = try source.segmentItemIDs.map { id in
                try XCTUnwrap(first.items.first { $0.id == id }?.textSegment)
            }
            let bytes = Data(segments.map(\.text).joined().utf8)
            XCTAssertEqual(bytes.count, source.utf8Bytes)
            XCTAssertEqual(FileDigest.sha256(of: bytes), source.sha256)
            var offset = 0
            for (ordinal, segment) in segments.enumerated() {
                XCTAssertEqual(segment.ordinal, ordinal)
                XCTAssertEqual(segment.count, segments.count)
                XCTAssertEqual(segment.utf8Offset, offset)
                offset += segment.text.utf8.count
            }
        }
        let full = try XCTUnwrap(first.textSources.first)
        let actual = try full.segmentItemIDs.map { id in try XCTUnwrap(first.items.first { $0.id == id }?.textSegment?.text) }.joined()
        XCTAssertEqual(Data(actual.utf8), try PlanningWriterIO.json(snapshot))
    }

    func testNoShotCapAndNoPretendedImageInspectionForVideoOnlyImports() throws {
        let snapshot = try snapshot(evidence: Array(repeating: [], count: 51))
        let manifest = try plan(snapshot, images: [:])
        XCTAssertEqual(Set(manifest.items.flatMap(\.shotIDs)), Set(snapshot.shots.map(\.shotID)))
        XCTAssertEqual(Set(manifest.items.compactMap(\.relation).filter { $0.kind == .adjacent }.map(\.edgeID)).count, 50)
        XCTAssertTrue(manifest.derivatives.isEmpty)
        XCTAssertTrue(manifest.pages.allSatisfy { $0.imageIDs.isEmpty })
        XCTAssertTrue(manifest.items.compactMap(\.relation).allSatisfy { $0.fromImageID == nil && $0.toImageID == nil })
        let texts = manifest.items.filter { $0.kind == .textSegment }.compactMap { $0.textSegment?.text }.joined()
        XCTAssertTrue(texts.contains("No evidence image is available for this shot"))
    }

    func testConditioningAndPermittedOriginalsNeverSubstituteForShotEvidence() throws {
        let image = try image(red: 0.6), reference = reference("bible/reference.png", bytes: image.bytes)
        let manifest = try plan(snapshot(evidence: [[], []], conditioning: [[reference], []],
            chain: true, permitted: [reference]), images: [reference.sha256: image])
        XCTAssertEqual(Set(manifest.mappings.map(\.usage.rawValue)), ["conditioning", "permittedOriginalReference"])
        XCTAssertTrue(manifest.items.contains { $0.kind == .image && $0.imageIDs == [image.derivative.id] })
        for item in manifest.items where item.kind == .relation {
            XCTAssertTrue(item.imageIDs.isEmpty)
            XCTAssertTrue(item.mappingIDs.isEmpty)
            XCTAssertNil(item.relation?.fromImageID)
            XCTAssertNil(item.relation?.toImageID)
            XCTAssertTrue(item.relation?.limitation.contains("visual continuity is not established") == true)
        }
        for id in manifest.snapshot.shots.map(\.shotID) {
            let text = manifest.items.filter { $0.kind == .textSegment && $0.shotIDs == [id] }
                .compactMap { $0.textSegment?.text }.joined()
            XCTAssertTrue(text.contains("No evidence image is available for this shot"))
        }
    }

    func testDuplicateOrMissingChainRecipesAreRejected() throws {
        let value = try snapshot(evidence: [[], [], []], chain: true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: PlanningWriterIO.json(value)) as? [String: Any])
        var projection = try XCTUnwrap(json["projection"] as? [String: Any])
        let chains = try XCTUnwrap(projection["chains"] as? [[String: Any]])
        for changed in [chains + chains, []] {
            projection["chains"] = changed
            json["projection"] = projection
            let altered = try JSONDecoder().decode(PipelineRenderReviewWriter.Snapshot.self,
                from: JSONSerialization.data(withJSONObject: json))
            XCTAssertThrowsError(try plan(altered, images: [:]))
        }
    }

    func testCanonicallyEquivalentUnicodeCannotReplaceExactTextBytes() throws {
        let manifest = try plan(snapshot(evidence: [[]], longText: "Unchanged e\u{301} action"), images: [:])
        let original = try PlanningWriterIO.json(manifest)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var items = try XCTUnwrap(object["items"] as? [[String: Any]])
        let index = try XCTUnwrap(items.firstIndex { item in
            guard let text = (item["textSegment"] as? [String: Any])?["text"] as? String else { return false }
            return Array(text.utf8) != Array(text.precomposedStringWithCanonicalMapping.utf8)
        })
        var segment = try XCTUnwrap(items[index]["textSegment"] as? [String: Any])
        segment["text"] = try XCTUnwrap(segment["text"] as? String).precomposedStringWithCanonicalMapping
        items[index]["textSegment"] = segment; object["items"] = items
        let changed = try JSONDecoder().decode(Manifest.self, from: JSONSerialization.data(withJSONObject: object))
        let changedBytes = try PlanningWriterIO.json(changed)
        XCTAssertEqual(String(decoding: original, as: UTF8.self), String(decoding: changedBytes, as: UTF8.self))
        XCTAssertNotEqual(original, changedBytes)
        XCTAssertThrowsError(try changed.requirePlan { _ in throw GateBlocked("Unexpected image") })
    }

    func testJPEGSourceProvenanceSurvivesPublicationAndRejectsChangedBindings() throws {
        let source = try imageBytes(red: 0.6, size: 2_400)
        let encoded = try Manifest.encode(source)
        XCTAssertEqual(encoded.derivative.mediaType, "image/jpeg")
        XCTAssertEqual(encoded.sourceEncoding.mode, .jpegThumbnail)
        XCTAssertEqual(encoded.sourceEncoding.sourceWidth, 2_400)
        XCTAssertEqual(encoded.derivative.width, ImageEncoder.maxLongestEdge)
        let reference = reference("sources/large.png", bytes: source)
        let manifest = try plan(snapshot(evidence: [[reference]]), images: [reference.sha256: encoded])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (path, bytes) in [(reference.path, source), (encoded.derivative.reference.path, encoded.bytes)] {
            let destination = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination)
        }
        let manifestBytes = try PlanningWriterIO.json(manifest)
        let persisted = try PipelineRenderReviewRunReceipt.publish(manifest,
            path: "render-review/manifests/\(manifest.id).v2.json", id: manifest.id,
            role: "host.render-review-manifest", dataRoot: directory)
        let loaded = try PipelineRenderReviewRunStore.read(Manifest.self, persisted, dataRoot: directory)
        try loaded.requireSourceEncodings(dataRoot: directory)
        try loaded.requirePlan { _ in encoded.bytes }
        for field in ["sourceWidth", "sourceByteCount", "sourceType", "encoder"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any])
            var records = try XCTUnwrap(json["sourceEncodings"] as? [[String: Any]])
            if field == "sourceWidth" || field == "sourceByteCount" { records[0][field] = 1 }
            else { records[0][field] = "changed" }
            json["sourceEncodings"] = records
            let changed = try JSONDecoder().decode(Manifest.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertThrowsError(try changed.requireSourceEncodings(dataRoot: directory))
        }
        try Data("replaced source".utf8).write(to: directory.appendingPathComponent(reference.path))
        XCTAssertThrowsError(try loaded.requireSourceEncodings(dataRoot: directory))
    }

    @MainActor
    func testActualCanonicalSnapshotPreparePublishAndVerify() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makeImportedAssembly()
        defer { fixture.document.close() }
        let snapshot = try await PipelineRenderReviewWriter.capture(editor: fixture.editor)
        let root = fixture.dataRoot
        try await Task.detached {
            let prepared = try Manifest.prepare(snapshot: snapshot, dataRoot: root)
            defer { prepared.discard() }
            XCTAssertEqual(prepared.files.filter { $0.reference == prepared.reference }.count, 1)
            try PipelineRenderReviewRunStore.publish(prepared, dataRoot: root)
            let loaded = try PipelineRenderReviewRunStore.read(Manifest.self, prepared.reference, dataRoot: root)
            try Manifest.verify(manifest: loaded, snapshot: snapshot, dataRoot: root)
            let repeated = try Manifest.prepare(snapshot: snapshot, dataRoot: root)
            defer { repeated.discard() }
            XCTAssertEqual(prepared.reference, repeated.reference)
            for page in loaded.pages { _ = try loaded.pageContent(pageID: page.id, dataRoot: root) }
        }.value
    }

    func testActualPageBytesAndAllBudgetLimitsMatchPersistedDerivatives() throws {
        let first = try image(red: 0.2, size: 768), second = try image(red: 0.8, size: 768)
        let a = reference("frames/a.png", bytes: first.bytes), b = reference("frames/b.png", bytes: second.bytes)
        let manifest = try plan(snapshot(evidence: [[a], [b]]), images: [a.sha256: first, b.sha256: second])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for image in [first, second] {
            let url = directory.appendingPathComponent(image.derivative.reference.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try image.bytes.write(to: url)
        }
        for page in manifest.pages {
            XCTAssertLessThanOrEqual(page.itemIDs.count, Manifest.maximumItemsPerPage)
            XCTAssertLessThanOrEqual(page.imageIDs.count, Manifest.maximumImagesPerPage)
            XCTAssertLessThanOrEqual(page.estimatedInputTokens, Manifest.maximumEstimatedInputTokens)
            XCTAssertLessThanOrEqual(page.resultByteCount + 1_024, Manifest.maximumResultBytes)
            let result = try manifest.pageContent(pageID: page.id, dataRoot: directory)
            XCTAssertEqual(try JSONEncoder().encode(result.toMCPResult()).count, page.resultByteCount)
            let images = result.content.compactMap { block -> Data? in
                if case .image(let base64, _) = block { return Data(base64Encoded: base64) }
                return nil
            }
            XCTAssertEqual(images.map { FileDigest.sha256(of: $0) }, page.imageIDs)
            guard case .text(let text) = result.content[0] else { return XCTFail("Missing actual page text") }
            XCTAssertTrue(text.contains(manifest.id))
            XCTAssertTrue(text.contains(page.id))
            for id in page.itemIDs { XCTAssertTrue(text.contains(id)) }
        }
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent(first.derivative.reference.path))
        let page = try XCTUnwrap(manifest.pages.first { $0.imageIDs.contains(first.derivative.id) })
        XCTAssertThrowsError(try manifest.pageContent(pageID: page.id, dataRoot: directory))
    }

    func testOversizedImagePairIsRefusedWithoutTruncatingContents() throws {
        let first = try image(red: 0.2, size: 1_568), second = try image(red: 0.8, size: 1_568)
        let a = reference("frames/a.png", bytes: first.bytes), b = reference("frames/b.png", bytes: second.bytes)
        XCTAssertThrowsError(try plan(snapshot(evidence: [[a], [b]]), images: [a.sha256: first, b.sha256: second])) { error in
            guard let blocked = error as? GateBlocked else { return XCTFail("Expected the bounded review refusal, got \(error)") }
            XCTAssertTrue(blocked.message.contains("cannot fit the image, byte or token bounds"))
            XCTAssertTrue(blocked.message.contains("Its contents have not been truncated."))
        }
    }

    func testOmittedMappingsItemsEdgesOrDerivativesAndChangedDimensionsAreRejected() throws {
        let image = try image(red: 0.2), source = reference("bible/image.png", bytes: image.bytes)
        let snapshot = try snapshot(evidence: [[source], [source]], conditioning: [[source], []])
        let manifest = try plan(snapshot, images: [source.sha256: image])
        let bytes: (String) throws -> Data = { _ in image.bytes }
        XCTAssertThrowsError(try Manifest.plan(snapshot: snapshot, mappings: Array(manifest.mappings.dropLast()),
            derivatives: manifest.derivatives, sourceEncodings: manifest.sourceEncodings, imageBytes: bytes))
        XCTAssertThrowsError(try Manifest.plan(snapshot: snapshot, mappings: manifest.mappings, derivatives: [],
            sourceEncodings: manifest.sourceEncodings, imageBytes: bytes))
        let changed = Manifest.Derivative(id: image.derivative.id, reference: image.derivative.reference,
            mediaType: image.derivative.mediaType, byteCount: image.derivative.byteCount,
            encodedJSONPayloadBytes: image.derivative.encodedJSONPayloadBytes, width: 99, height: image.derivative.height)
        XCTAssertThrowsError(try Manifest.plan(snapshot: snapshot, mappings: manifest.mappings, derivatives: [changed],
            sourceEncodings: manifest.sourceEncodings, imageBytes: bytes))
        for items in [Array(manifest.items.dropLast()), manifest.items.filter { $0.kind != .relation }] {
            let damaged = Manifest(schema: manifest.schema, id: manifest.id, snapshot: snapshot, textSources: manifest.textSources,
                mappings: manifest.mappings, derivatives: manifest.derivatives, sourceEncodings: manifest.sourceEncodings, items: items, pages: manifest.pages)
            XCTAssertThrowsError(try damaged.requirePlan(imageBytes: bytes))
        }
        let damaged = Manifest(schema: manifest.schema, id: manifest.id, snapshot: snapshot, textSources: manifest.textSources,
            mappings: manifest.mappings, derivatives: manifest.derivatives, sourceEncodings: manifest.sourceEncodings,
            items: manifest.items, pages: Array(manifest.pages.dropFirst()))
        XCTAssertThrowsError(try damaged.requirePlan(imageBytes: bytes))
    }

    func testOversizedIndivisibleMappingIsRefusedRatherThanTruncated() throws {
        let image = try image(red: 0.2)
        let source = reference(String(repeating: "a", count: 20_000) + ".png", bytes: image.bytes)
        let snapshot = try snapshot(evidence: [[source]])
        XCTAssertThrowsError(try plan(snapshot, images: [source.sha256: image])) { error in
            XCTAssertTrue(error is GateBlocked)
            XCTAssertTrue(error.localizedDescription.contains("cannot fit the image, byte or token bounds"))
        }
    }

    func testMissingCapturedImageAndConflictingPathHashesFailClosed() throws {
        let image = try image(red: 0.2), source = reference("a.png", bytes: image.bytes)
        let other = reference("a.png", bytes: Data("different".utf8))
        XCTAssertThrowsError(try plan(snapshot(evidence: [[source, other]]), images: [source.sha256: image]))
        let original = try snapshot(evidence: [[source]])
        let incomplete = PipelineRenderReviewWriter.Snapshot(fingerprint: original.fingerprint, workflow: original.workflow,
            projectKey: original.projectKey, projection: original.projection, shots: original.shots, references: [], absentPaths: [])
        XCTAssertThrowsError(try plan(incomplete, images: [source.sha256: image]))
        XCTAssertThrowsError(try Manifest.encode(Data("not an image".utf8)))
    }

    private func image(red: CGFloat, size: Int = 32) throws -> Manifest.EncodedImage {
        try Manifest.encode(imageBytes(red: red, size: size))
    }

    private func imageBytes(red: CGFloat, size: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
        return try XCTUnwrap(ImageEncoder.encodePNG(XCTUnwrap(context.makeImage())))
    }

    private func reference(_ path: String, bytes: Data = Data(), role: String = "core.fixture") -> CanonicalArtifactReferenceV1 {
        PlanningWriterIO.reference(path, id: path, role: role, bytes: bytes)
    }

    private func plan(_ snapshot: PipelineRenderReviewWriter.Snapshot,
                      images: [String: Manifest.EncodedImage]) throws -> Manifest {
        let mappings = try Manifest.imageMappings(snapshot: snapshot, derivativeIDsBySourceHash: images.mapValues { $0.derivative.id })
        var seen = Set<String>()
        let derivatives = try mappings.compactMap { mapping -> Manifest.Derivative? in
            guard seen.insert(mapping.derivativeID).inserted else { return nil }
            return try XCTUnwrap(images.values.first { $0.derivative.id == mapping.derivativeID }?.derivative)
        }
        var sourceHashes = Set<String>()
        let encodings = try mappings.compactMap { mapping -> Manifest.SourceEncoding? in
            guard sourceHashes.insert(mapping.source.sha256).inserted else { return nil }
            return try XCTUnwrap(images[mapping.source.sha256]?.sourceEncoding)
        }
        return try Manifest.plan(snapshot: snapshot, mappings: mappings, derivatives: derivatives, sourceEncodings: encodings) { id in
            try XCTUnwrap(images.values.first { $0.derivative.id == id }?.bytes)
        }
    }

    private func snapshot(evidence: [[CanonicalArtifactReferenceV1]], conditioning: [[CanonicalArtifactReferenceV1]]? = nil,
                          chain: Bool = false, permitted: [CanonicalArtifactReferenceV1] = [],
                          longText: String = "Exact planned action") throws -> PipelineRenderReviewWriter.Snapshot {
        let ids = evidence.indices.map { "shot-" + String($0) }
        let references = evidence.flatMap { $0 } + (conditioning?.flatMap { $0 } ?? []) + permitted
        let draft = reference("shot-planning/v1.v1.json"), board = reference("storyboard/timing-v1.v1.json")
        let shots = ids.map { id in ExecutionShotV1(id: id, sourceMode: chain ? .generated : .imported,
            startState: .init(summary: "Initial state"), endState: .init(summary: "Final state"), primaryAction: longText,
            camera: .init(movementID: "core.static"), renderability: .green) }
        let chains: [ProductionPlanProjectionV1.ChainBinding] = chain
            ? [.init(shotID: ids[1], kind: .frameContinuation, predecessorShotID: ids[0])] : []
        let projection = ProductionPlanProjectionV1(header: .init(projectID: "fixture", revision: 1, origin: .userRevision, inputs: []),
            timebase: .init(ticksPerSecond: 24, fpsNumerator: 24), mode: .generic,
            executionPlan: .init(id: "fixture", projectID: "fixture", creativeContext: reference("context.json"), shots: shots),
            timings: ids.enumerated().map { .init(shotID: $0.element, startTicks: Int64($0.offset * 48), durationTicks: 48) },
            sourceBindings: [], draftReference: draft, storyboardReference: board, chains: chains)
        let captured = ids.enumerated().map { index, id in PipelineRenderReviewWriter.CapturedShot(shotID: id,
            sourceMode: chain ? .generated : .imported, compiledPrompt: nil, modelID: nil, sourceInput: nil, sourceInputRange: nil,
            review: .init(shotID: id, evidence: evidence[index], conditioning: conditioning?[index] ?? [],
                predecessor: chain && index == 1 ? .init(strategy: .frameContinuation, predecessorShotID: ids[0],
                    permittedOriginalReferences: permitted) : nil)) }
        return .init(fingerprint: FileDigest.sha256(of: try PlanningWriterIO.json(projection)), workflow: try .core(.current),
            projectKey: "fixture", projection: projection, shots: captured, references: references, absentPaths: [])
    }
}
