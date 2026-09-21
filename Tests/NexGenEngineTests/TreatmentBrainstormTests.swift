import Foundation
import Testing
@testable import NexGenEngine

@Suite("Treatment brainstorm provenance")
struct TreatmentBrainstormTests {
    private func fixture() throws -> (URL, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent("pipeline")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (home, root)
    }

    private func run(root: URL, responseJSON: String? = nil) throws -> TreatmentBrainstormRunV1 {
        let inputPath = "brief.yaml"
        let input = Data("mission: fixture\n".utf8)
        try input.write(to: root.appendingPathComponent(inputPath))
        let json = responseJSON ?? "{\"title\":\"One\",\"summary\":\"A summary\",\"body_markdown\":\"# Treatment\\nBody\"}"
        let variant = TreatmentBrainstormVariantV1(
            id: UUID().uuidString,
            role: .idea,
            providerID: "openai",
            modelID: "fixture-model",
            title: "One",
            summary: "A summary",
            bodyMarkdown: "# Treatment\nBody",
            requestSHA256: FileDigest.sha256(of: Data("request".utf8)),
            providerResponseID: "response-1",
            responseJSON: json,
            responseSHA256: FileDigest.sha256(of: Data(json.utf8)),
            usage: .init(inputTokens: 10, outputTokens: 20)
        )
        let inputs = [TreatmentBrainstormInputProofV1(
            path: inputPath,
            sha256: FileDigest.sha256(of: input)
        )]
        return TreatmentBrainstormRunV1(
            id: UUID().uuidString,
            createdAt: "2026-09-21T00:00:00Z",
            inputFingerprint: TreatmentBrainstormStoreV1.inputFingerprint(inputs),
            inputs: inputs,
            approval: .init(
                authorizationSHA256: FileDigest.sha256(of: Data("authorization".utf8)),
                approvedAt: "2026-09-21T00:00:00Z",
                calls: [.init(role: .idea, providerID: "openai", modelID: "fixture-model")]
            ),
            executions: [
                .init(
                    role: .idea,
                    providerID: "openai",
                    modelID: "fixture-model",
                    status: .succeeded,
                    variantID: variant.id
                ),
            ],
            variants: [variant]
        )
    }

    @Test("run preserves exact provider response and rejects field substitution")
    func validatesResponsePayload() throws {
        let (home, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let valid = try run(root: root)
        try TreatmentBrainstormStoreV1.validate(valid, dataRoot: root)

        let substituted = try run(
            root: root,
            responseJSON: "{\"title\":\"Different\",\"summary\":\"A summary\",\"body_markdown\":\"# Treatment\\nBody\"}"
        )
        #expect(throws: TreatmentBrainstormStoreV1.ValidationError.self) {
            try TreatmentBrainstormStoreV1.validate(substituted, dataRoot: root)
        }
    }

    @Test("failed approved calls remain durable without fabricated variants")
    func recordsFailedCalls() throws {
        let (home, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let input = Data("mission: fixture\n".utf8)
        try input.write(to: root.appendingPathComponent("brief.yaml"))
        let inputs = [TreatmentBrainstormInputProofV1(
            path: "brief.yaml",
            sha256: FileDigest.sha256(of: input)
        )]
        let run = TreatmentBrainstormRunV1(
            id: UUID().uuidString,
            createdAt: "2026-09-21T00:00:00Z",
            inputFingerprint: TreatmentBrainstormStoreV1.inputFingerprint(inputs),
            inputs: inputs,
            approval: .init(
                authorizationSHA256: FileDigest.sha256(of: Data("authorization".utf8)),
                approvedAt: "2026-09-21T00:00:00Z",
                calls: [.init(role: .idea, providerID: "anthropic", modelID: "fixture")]
            ),
            executions: [.init(
                role: .idea,
                providerID: "anthropic",
                modelID: "fixture",
                status: .failed,
                error: "Provider unavailable."
            )],
            variants: []
        )
        _ = try TreatmentBrainstormStoreV1.writeRun(run, dataRoot: root)
        #expect(try TreatmentBrainstormStoreV1.loadRun(id: run.id, dataRoot: root).0 == run)
    }

    @Test("exact selection derives origin and binds treatment, run, model, and response")
    func exactProvenance() throws {
        let (home, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let run = try run(root: root)
        _ = try TreatmentBrainstormStoreV1.writeRun(run, dataRoot: root)
        let meta = try TreatmentMeta(
            project: "fixture",
            version: 1,
            generated: "2026-09-21T00:00:00Z",
            origin: .agentProposal,
            generator: "treatment-agent@write_treatment",
            summaryOneline: "A summary"
        )
        let treatment = Treatment(meta: meta, bodyMarkdown: run.variants[0].bodyMarkdown)
        let result = try TreatmentBrainstormStoreV1.makeProvenance(
            treatment: treatment,
            runID: run.id,
            variantIDs: [run.variants[0].id],
            relationship: .exact,
            dataRoot: root
        )
        #expect(result.2 == .brainstormOpenai)
        #expect(result.0.sources == [TreatmentBrainstormSourceV1(variant: run.variants[0])])
        #expect(result.0.relationship == .exact)

        let resolvedMeta = try TreatmentMeta(
            project: meta.project,
            version: meta.version,
            generated: meta.generated,
            origin: result.2,
            generator: meta.generator,
            summaryOneline: meta.summaryOneline
        )
        let resolved = Treatment(meta: resolvedMeta, bodyMarkdown: treatment.bodyMarkdown)
        let treatmentURL = root.appendingPathComponent(PipelineLayout.treatmentVersionFile(1))
        try FileManager.default.createDirectory(
            at: treatmentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(try resolved.serialized().utf8).write(to: treatmentURL)
        try result.1.write(
            to: root.appendingPathComponent(TreatmentBrainstormStoreV1.provenancePath(1))
        )
        #expect(try TreatmentBrainstormStoreV1.requireCurrent(version: 1, dataRoot: root) == result.0)

        try Data(try Treatment(meta: resolvedMeta, bodyMarkdown: "Changed").serialized().utf8)
            .write(to: treatmentURL)
        #expect(throws: TreatmentBrainstormStoreV1.ValidationError.self) {
            _ = try TreatmentBrainstormStoreV1.requireCurrent(version: 1, dataRoot: root)
        }
    }

    @Test("influenced work remains agent-authored and records every source")
    func influencedProvenance() throws {
        let (home, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let run = try run(root: root)
        _ = try TreatmentBrainstormStoreV1.writeRun(run, dataRoot: root)
        let meta = try TreatmentMeta(
            project: "fixture",
            version: 1,
            generated: "2026-09-21T00:00:00Z",
            origin: .agentRevision,
            generator: "treatment-agent@write_treatment",
            summaryOneline: "Reworked"
        )
        let result = try TreatmentBrainstormStoreV1.makeProvenance(
            treatment: Treatment(meta: meta, bodyMarkdown: "A new host-agent revision."),
            runID: run.id,
            variantIDs: [run.variants[0].id],
            relationship: .influenced,
            dataRoot: root
        )
        #expect(result.2 == .agentRevision)
        #expect(result.0.relationship == .influenced)
    }
}
