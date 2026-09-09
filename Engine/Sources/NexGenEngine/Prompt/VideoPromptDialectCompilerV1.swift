import Foundation

public enum VideoPromptCompilationErrorV1: Error, Sendable, Equatable {
    case unsupportedIRSchema(String)
    case invalidDialect
    case invalidMode
    case invalidReferenceOrder
    case invalidReferenceRole
}

public enum VideoPromptCanonicalCodecV1 {
    public static func encode(_ value: VideoPromptIRV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

public enum VideoPromptDialectCompilerV1 {
    public static func compile(
        _ ir: VideoPromptIRV1,
        dialect: VideoPromptDialectV1
    ) throws -> String {
        try validate(ir, dialect: dialect)
        switch dialect.family {
        case .seedance:
            return compileBlocks(ir, syntax: .seedance, order: [.references, .optics, .start, .action, .blocking, .setting, .light, .style, .ending, .locks, .exclusions, .output])
        case .h3:
            return compileH3(ir)
        case .cameraFirst:
            return compileBlocks(ir, syntax: .descriptive, order: [.references, .optics, .start, .action, .blocking, .setting, .light, .style, .ending, .locks, .exclusions, .output])
        case .styleFirst:
            return compileBlocks(ir, syntax: .descriptive, order: [.style, .references, .optics, .start, .action, .blocking, .setting, .light, .ending, .locks, .exclusions, .output])
        case .generic:
            return compileBlocks(ir, syntax: .descriptive, order: [.references, .start, .action, .blocking, .setting, .optics, .light, .style, .ending, .locks, .exclusions, .output])
        }
    }

    private static func compileH3(_ ir: VideoPromptIRV1) -> String {
        if ir.references.contains(where: {
            ![VideoPromptReferenceRoleV1.startFrame, .endFrame].contains($0.role)
        }) {
            let definitions = referenceLines(ir.references, syntax: .h3).joined(separator: " ")
            let retention = ir.references.map { reference in
                let marker: String
                switch reference.role {
                case .style, .lighting: marker = "attribute_transfer"
                case .motion, .audioTiming, .voice: marker = "reference"
                default: marker = "fully_preserved"
                }
                return "\(referenceLabel(reference, syntax: .h3)) \(marker)"
            }.joined(separator: "; ")
            let detail = compileBlocks(
                ir,
                syntax: .h3,
                order: [.style, .optics, .start, .action, .blocking, .setting, .light, .ending, .locks, .exclusions]
            )
            return [
                "subject_definitions: \(definitions)",
                "summary: [reference generation] \(clean(ir.subject))",
                "retention_analysis: \(retention)",
                "detailed_description: \(detail)",
                "overall_soundscape: N/A",
                "non_diegetic_music: N/A",
            ].joined(separator: "\n")
        }
        let detail = compileBlocks(
            ir,
            syntax: .h3,
            order: [.references, .style, .optics, .start, .action, .blocking, .setting, .light, .ending, .locks, .exclusions]
        )
        return [
            "integrated_multimodal_description: [Shot 1] \(detail)",
            "overall_soundscape: N/A",
            "non_diegetic_music: N/A",
        ].joined(separator: "\n\n")
    }

    private enum Block {
        case references, start, action, blocking, setting, optics, light, style
        case ending, locks, exclusions, output
    }

    private enum ReferenceSyntax {
        case seedance, h3, descriptive
    }

    private static func compileBlocks(
        _ ir: VideoPromptIRV1,
        syntax: ReferenceSyntax,
        order: [Block]
    ) -> String {
        let blocks = order.compactMap { block(ir, $0, syntax: syntax) }
        return BuilderSupport.joinClean(blocks + ir.directives)
    }

    private static func block(
        _ ir: VideoPromptIRV1,
        _ block: Block,
        syntax: ReferenceSyntax
    ) -> String? {
        switch block {
        case .references:
            let lines = referenceLines(ir.references, syntax: syntax)
            return lines.isEmpty ? nil : "ACTIVE REFERENCES: " + lines.joined(separator: " ")
        case .start:
            return labeled("FIRST FRAME", ir.startState)
        case .action:
            var values: [String] = []
            if !clean(ir.subject).isEmpty { values.append(clean(ir.subject)) }
            values.append(contentsOf: ir.timedActionBeats.map {
                "t=\(formatSeconds($0.timeSeconds)): \(clean($0.action))"
            })
            if !clean(ir.temporalStructure).isEmpty {
                values.append(clean(ir.temporalStructure))
            }
            return values.isEmpty ? nil : "ACTION: " + values.joined(separator: " ")
        case .blocking:
            return ir.blocking.isEmpty ? nil : "BLOCKING / PERFORMANCE: "
                + ir.blocking.map(clean).filter { !$0.isEmpty }.joined(separator: " ")
        case .setting:
            return labeled("SETTING", ir.setting)
        case .optics:
            let values = [ir.composition, ir.camera].map(clean).filter { !$0.isEmpty }
            return values.isEmpty ? nil : "OPTICS / CAMERA: " + values.joined(separator: " ")
        case .light:
            return labeled("LIGHTING / COLOR", ir.light)
        case .style:
            return labeled("STYLE", ir.style)
        case .ending:
            var values = [clean(ir.endState)].filter { !$0.isEmpty }
            if let transition = ir.transitionIntent, !clean(transition).isEmpty {
                values.append("Transition: \(clean(transition))")
            }
            return values.isEmpty ? nil : "ENDING STATE: " + values.joined(separator: " ")
        case .locks:
            return ir.continuityLocks.isEmpty ? nil : "POSITIVE LOCKS: "
                + ir.continuityLocks.map(clean).filter { !$0.isEmpty }.joined(separator: "; ") + "."
        case .exclusions:
            return ir.exclusions.isEmpty ? nil : "EXCLUSIONS: "
                + ir.exclusions.map(clean).filter { !$0.isEmpty }.joined(separator: "; ") + "."
        case .output:
            let duration = ir.durationSeconds.map {
                String(format: "%.3g", $0) + "s"
            } ?? "automatic duration"
            let aspect = clean(ir.aspectRatio).isEmpty ? "provider aspect" : clean(ir.aspectRatio)
            return "OUTPUT: \(duration), \(aspect), mode \(clean(ir.modeID))."
        }
    }

    private static func referenceLines(
        _ references: [VideoPromptReferenceV1],
        syntax: ReferenceSyntax
    ) -> [String] {
        var lines = references.map { reference in
            let label = referenceLabel(reference, syntax: syntax)
            let identity = reference.identityLabel
            switch reference.role {
            case .character:
                return "\(label) defines <\(identity)> identity, wardrobe state, and visible design."
            case .location:
                return "\(label) defines <\(identity)> layout, materials, and spatial continuity."
            case .prop:
                return "\(label) defines <\(identity)> appearance, scale, and ownership."
            case .style:
                return "\(label) defines the approved visual treatment only."
            case .lighting:
                return "\(label) defines lighting direction, color, and material response."
            case .motion:
                return "\(label) defines motion and pacing only, not identity."
            case .audioTiming:
                return "\(label) defines timing and rhythm only; preserve the project track."
            case .voice:
                return "\(label) defines <\(identity)> voice timbre and delivery only; do not reuse its words."
            case .startFrame:
                return "\(label) is the exact first frame at t=0."
            case .endFrame:
                return "\(label) is the exact final frame at the requested duration."
            case .sourceVideo:
                return "\(label) is the exact source video for this operation."
            case .other:
                return "\(label) performs the approved job <\(identity)> only."
            }
        }
        if references.filter({ $0.role == .character }).count > 1 {
            lines.append("Keep every named character bound to its own reference; do not interchange appearances.")
        }
        return lines
    }

    private static func referenceLabel(
        _ reference: VideoPromptReferenceV1,
        syntax: ReferenceSyntax
    ) -> String {
        switch syntax {
        case .seedance:
            return reference.providerLabel
        case .h3:
            switch reference.modality {
            case .image: return "<Picture \(reference.modalityIndex)>"
            case .video: return "<Video \(reference.modalityIndex)>"
            case .audio: return "<Audio \(reference.modalityIndex)>"
            case .geometry: return "<Clay Render \(reference.modalityIndex)>"
            }
        case .descriptive:
            switch reference.modality {
            case .image: return "Reference image \(reference.modalityIndex)"
            case .video: return "Reference video \(reference.modalityIndex)"
            case .audio: return "Reference audio \(reference.modalityIndex)"
            case .geometry: return "Reference geometry \(reference.modalityIndex)"
            }
        }
    }

    private static func validate(
        _ ir: VideoPromptIRV1,
        dialect: VideoPromptDialectV1
    ) throws {
        guard ir.schema == videoPromptIRV1Schema else {
            throw VideoPromptCompilationErrorV1.unsupportedIRSchema(ir.schema)
        }
        guard dialect.version > 0,
              !clean(dialect.id).isEmpty,
              !clean(dialect.evidence).isEmpty else {
            throw VideoPromptCompilationErrorV1.invalidDialect
        }
        guard !clean(ir.modeID).isEmpty else {
            throw VideoPromptCompilationErrorV1.invalidMode
        }
        guard ir.references.map(\.planIndex) == Array(ir.references.indices) else {
            throw VideoPromptCompilationErrorV1.invalidReferenceOrder
        }
        for modality in VideoPromptReferenceModalityV1.allCasesForValidation {
            let actual = ir.references.filter { $0.modality == modality }.map(\.modalityIndex)
            let expected = actual.isEmpty ? [] : Array(1...actual.count)
            guard actual == expected else {
                throw VideoPromptCompilationErrorV1.invalidReferenceOrder
            }
        }
        for reference in ir.references {
            switch reference.role {
            case .startFrame, .endFrame:
                guard reference.modality == .image else {
                    throw VideoPromptCompilationErrorV1.invalidReferenceRole
                }
            case .sourceVideo, .motion:
                guard reference.modality == .video else {
                    throw VideoPromptCompilationErrorV1.invalidReferenceRole
                }
            case .audioTiming, .voice:
                guard reference.modality == .audio || reference.modality == .video else {
                    throw VideoPromptCompilationErrorV1.invalidReferenceRole
                }
            default:
                break
            }
        }
    }

    private static func labeled(_ label: String, _ value: String) -> String? {
        let value = clean(value)
        return value.isEmpty ? nil : "\(label): \(value)"
    }

    private static func clean(_ value: String) -> String {
        SlopStripper.strip(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

private extension VideoPromptReferenceModalityV1 {
    static let allCasesForValidation: [Self] = [.image, .video, .audio, .geometry]
}
