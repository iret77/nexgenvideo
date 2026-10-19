import Foundation
import NexGenEngine

enum ProductionCompiledPromptStore {
    struct Record: Codable, Sendable, Equatable {
        let schema: String
        let projectID: String
        let shotID: String
        let modelID: String
        let modality: String
        let text: String
        let binding: PromptBinding
        let sourceIR: Data
    }

    static func imageIR(payload: PromptPayload) throws -> Data {
        var value: [String: Any] = ["schema": "image-prompt-ir/v1", "subject": payload.subject,
            "setting": payload.setting, "composition": payload.composition, "camera": payload.camera,
            "style": payload.style, "light": payload.light, "negatives": payload.negatives,
            "sheetView": payload.sheetView, "isStartFrame": payload.isStartFrame, "aspectRatio": payload.aspectRatio,
            "nShots": payload.nShots, "multiRefHints": payload.multiRefHints, "directives": payload.directives,
            "temporalStructure": payload.temporalStructure]
        if let duration = payload.durationS { value["durationS"] = duration }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func path(binding: PromptBinding, modelID: String, text: String) throws -> String {
        struct Key: Encodable { let binding: PromptBinding; let model: String; let text: String }
        return "execution/compiled-prompts/" + FileDigest.sha256(of: try PlanningWriterIO.json(Key(binding: binding, model: modelID, text: text))) + ".v1.json"
    }

    static func record(_ compiled: CompiledPrompt, modelID: String, modality: String,
                       projectID: String, dataRoot: URL) throws -> CanonicalArtifactReferenceV1 {
        guard let ir = compiled.sourceIRData, FileDigest.sha256(of: ir) == compiled.binding.promptIRSHA256 else {
            throw GateBlocked("The production prompt has no exact compiler input record.")
        }
        let value = Record(schema: "production-compiled-prompt/v1", projectID: projectID, shotID: compiled.binding.shotId,
            modelID: modelID, modality: modality, text: compiled.text, binding: compiled.binding, sourceIR: ir)
        let bytes = try PlanningWriterIO.json(value)
        let relative = try path(binding: compiled.binding, modelID: modelID, text: compiled.text)
        let candidate = dataRoot.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: candidate.path) {
            guard try Data(contentsOf: ProjectLocalFile.resolve(relative, dataRoot: dataRoot)) == bytes else {
                throw GateBlocked("A compiled production prompt cannot overwrite its recorded inputs.")
            }
        } else {
            let directory = try ProjectLocalFile.ensureDirectory("execution/compiled-prompts", dataRoot: dataRoot)
            let staged = directory.appendingPathComponent(".compiled-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staged) }
            try bytes.write(to: staged, options: .atomic)
            do { try FileManager.default.linkItem(at: staged, to: candidate) }
            catch {
                guard FileManager.default.fileExists(atPath: candidate.path) else { throw error }
                guard try Data(contentsOf: ProjectLocalFile.resolve(relative, dataRoot: dataRoot)) == bytes else {
                    throw GateBlocked("A compiled production prompt cannot overwrite its recorded inputs.")
                }
            }
        }
        return PlanningWriterIO.reference(relative, id: "compiled-prompt." + compiled.binding.promptIRSHA256,
            role: "host.production-compiled-prompt", bytes: bytes)
    }

    static func load(_ reference: CanonicalArtifactReferenceV1, dataRoot: URL) throws -> Record {
        let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot))
        let record = try JSONDecoder().decode(Record.self, from: bytes)
        guard record.schema == "production-compiled-prompt/v1", record.shotID == record.binding.shotId,
              record.binding.promptIRSHA256 == FileDigest.sha256(of: record.sourceIR),
              try path(binding: record.binding, modelID: record.modelID, text: record.text) == reference.path,
              try PlanningWriterIO.json(record) == bytes else { throw GateBlocked("The production prompt record changed.") }
        try requireCompilerOutput(record, dataRoot: dataRoot)
        return record
    }

    private struct ImageIR: Decodable {
        let schema: String
        let subject: String
        let setting: String
        let composition: String
        let camera: String
        let style: String
        let light: String
        let negatives: [String]
        let sheetView: String
        let isStartFrame: Bool
        let durationS: Double?
        let aspectRatio: String
        let nShots: Int
        let multiRefHints: [String]
        let directives: [String]
        let temporalStructure: String

        var payload: PromptPayload { .init(subject: subject, setting: setting, composition: composition,
            camera: camera, style: style, light: light, negatives: negatives, sheetView: sheetView,
            isStartFrame: isStartFrame, durationS: durationS, aspectRatio: aspectRatio,
            nShots: nShots, multiRefHints: multiRefHints, directives: directives, temporalStructure: temporalStructure) }
    }

    private static func requireCompilerOutput(_ value: Record, dataRoot: URL) throws {
        let actual: String
        if value.modality == "image" {
            let input = try JSONDecoder().decode(ImageIR.self, from: value.sourceIR)
            guard input.schema == "image-prompt-ir/v1", try imageIR(payload: input.payload) == value.sourceIR else {
                throw GateBlocked("The image compiler input record is not canonical.")
            }
            actual = try PromptGenerator.buildImagePrompt(modelID: PromptComposer.engineModelID(value.modelID), payload: input.payload)
        } else if value.modality == "video" {
            let ir = try JSONDecoder().decode(VideoPromptIRV1.self, from: value.sourceIR)
            var endpoint: String?
            if value.shotID != "none" {
                let promotion = try PlanningWriterIO.read(ShotPlanningPromotionV1.self,
                    at: ShotPlanningPromotionV1.currentPath, dataRoot: dataRoot)
                let reference: CanonicalArtifactReferenceV1
                if let planned = promotion.routes.first(where: { $0.shotID == value.shotID })?.route,
                   planned.sha256 == value.binding.routeArtifactSHA256 { reference = planned }
                else {
                    let bundle = try PipelineProductionInputMaterializer.requireCurrent(shotID: value.shotID, dataRoot: dataRoot)
                    guard bundle.receipt.route.sha256 == value.binding.routeArtifactSHA256 else { throw GateBlocked("The compiled prompt route changed.") }
                    reference = bundle.receipt.route
                }
                let route = try PlanningWriterIO.read(ProductionRouteV1.self, at: reference.path, dataRoot: dataRoot)
                _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
                endpoint = route.offering.endpointID
            }
            let dialect = try PromptDialectRegistry.requireVideoDialect(modelID: value.modelID, endpointID: endpoint, modeID: ir.modeID)
            guard dialect.id == value.binding.promptDialectID, dialect.version == value.binding.promptDialectVersion,
                  try VideoPromptCanonicalCodecV1.encode(ir) == value.sourceIR else { throw GateBlocked("The video compiler dialect or IR changed.") }
            actual = try PromptGenerator.buildVideoPrompt(ir: ir, dialect: dialect)
        } else { throw GateBlocked("The production prompt has no supported visual compiler.") }
        guard actual == value.text else { throw GateBlocked("The recorded prompt does not match its actual compiler inputs.") }
    }
}
