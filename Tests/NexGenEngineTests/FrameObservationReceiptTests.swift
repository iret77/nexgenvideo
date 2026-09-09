import Foundation
import Testing
@testable import NexGenEngine

@Suite("Frame style observation binding")
struct FrameObservationReceiptTests {
    @Test("missing image receipt, changed bytes and temporal claims cannot pass a frame review")
    func evidenceBoundary() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("style-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "review")
        let style = try ResolvedProductionStyleV1.resolve(.init(directorID: "director-wes-anderson-symmetry-deadpan"),
            catalog: EngineProductionKnowledgeResourcesV1.loadCatalog())
        let hash = FileDigest.sha256(of: Data("fixture original image".utf8))
        var checks = Dictionary(uniqueKeysWithValues: style.criteria.filter { $0.source.scope == .frame }.map {
            ($0.auditKey, AuditCheck(status: .clean, expected: $0.expected, observed: "Attributed fixture observation"))
        })
        var audit = try FrameAudit(shotId: "shot-1", renderPath: "frames/one.png", renderSha256: hash,
            generated: "2026-09-08", auditor: "fixture-reviewer", checks: checks, overall: .clean)
        #expect(throws: (any Error).self) { try FrameObservationStoreV1.requireStyleAudit(audit, style: style, dataRoot: root) }
        let receipt = try FrameObservationStoreV1.record(sourceSHA256: hash,
            transmittedImage: Data("fixture transmitted image".utf8), mediaID: "image-1", dataRoot: root)
        checks[FrameObservationStoreV1.auditKey] = AuditCheck(status: .clean, expected: hash,
            observed: receipt.id, note: receipt.transmittedImageSHA256)
        audit.checks = checks
        try FrameObservationStoreV1.requireStyleAudit(audit, style: style, dataRoot: root)
        audit.renderSha256 = FileDigest.sha256(of: Data("changed image".utf8))
        #expect(throws: (any Error).self) { try FrameObservationStoreV1.requireStyleAudit(audit, style: style, dataRoot: root) }
        audit.renderSha256 = hash
        let hold = try #require(style.criteria.first { $0.source.scope == .shot })
        audit.checks[hold.auditKey] = AuditCheck(status: .clean, expected: hold.expected, observed: "A still proves the hold")
        #expect(throws: (any Error).self) { try FrameObservationStoreV1.requireStyleAudit(audit, style: style, dataRoot: root) }
        audit.checks = checks
        let composition = try #require(style.criteria.first { $0.source.scope == .frame })
        audit.checks[composition.auditKey]?.observed = " "
        #expect(throws: (any Error).self) { try FrameObservationStoreV1.requireStyleAudit(audit, style: style, dataRoot: root) }
    }
}
