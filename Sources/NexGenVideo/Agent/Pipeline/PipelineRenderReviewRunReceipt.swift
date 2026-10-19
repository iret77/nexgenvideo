import Foundation
import NexGenEngine

enum PipelineRenderReviewRunReceipt {
    struct Authorization: Codable, Sendable, Equatable {
        let schema: String
        let id: UUID
        let runID: UUID
        let manifest: CanonicalArtifactReferenceV1
        let backend: String
        let requestedModelID: String?
        let phaseGrantID: UUID?
        let pageCount: Int
        let maximumSynthesisContexts: Int
        let bounds: AgentReviewChildBounds
        let costDescription: String
        let approvedAt: String
    }

    struct Observation: Codable, Sendable, Equatable {
        let itemID: String
        let text: String
    }

    struct Submission: Codable, Sendable, Equatable {
        let manifestID: String
        let pageID: String
        let observations: [Observation]
        let findings: [RenderReviewV1.Finding]

        func validate(manifestID expectedManifest: String, pageID expectedPage: String,
                      itemIDs: [String], shotIDs: Set<String>, references: [CanonicalArtifactReferenceV1],
                      kind: AgentReviewChildKind = .page) throws {
            let allowedReferences = Set(try references.map { try PlanningWriterIO.json($0) })
            guard manifestID == expectedManifest, pageID == expectedPage,
                  Set(observations.map(\.itemID)) == Set(itemIDs), observations.count == itemIDs.count,
                  observations.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.utf8.count <= 512
                      && readable($0.text) }),
                  findings.count <= 8, Set(findings.map(\.id)).count == findings.count else { throw invalid() }
            for finding in findings {
                guard !finding.id.isEmpty, finding.id.utf8.count <= 96,
                      finding.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                        || (97...122).contains($0) || [45, 46, 95].contains($0) }),
                      !finding.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      finding.message.utf8.count <= 1024, readable(finding.message), !finding.shotIDs.isEmpty,
                      finding.shotIDs.count <= 64, Set(finding.shotIDs).count == finding.shotIDs.count,
                      Set(finding.shotIDs).isSubset(of: shotIDs), !finding.evidence.isEmpty, finding.evidence.count <= 4,
                      finding.acceptance == nil, finding.acceptanceReason == nil,
                      try finding.evidence.allSatisfy({ allowedReferences.contains(try PlanningWriterIO.json($0)) }) else { throw invalid() }
            }
            try PipelineRenderReviewSummary.requireBounded(self, kind: kind)
        }

        func namespacedFindings(reviewID: String) -> [RenderReviewV1.Finding] {
            let prefix = String(FileDigest.sha256(of: Data((manifestID + "/" + pageID + "/" + reviewID).utf8)).prefix(24))
            return findings.map { .init(id: prefix + "." + $0.id, kind: $0.kind, category: $0.category,
                shotIDs: $0.shotIDs, message: $0.message, evidence: $0.evidence) }
        }
    }

    struct DeliveredImage: Codable, Sendable, Equatable {
        let reference: CanonicalArtifactReferenceV1
        let mediaType: String
        let width: Int
        let height: Int
        let byteCount: Int
    }

    struct Delivery: Codable, Sendable, Equatable {
        let schema: String
        let authorization: CanonicalArtifactReferenceV1
        let manifest: CanonicalArtifactReferenceV1
        let kind: AgentReviewChildKind
        let pageID: String
        let itemIDs: [String]
        let shotIDs: [String]
        let sourceReceipts: [CanonicalArtifactReferenceV1]
        let requestedModelID: String?
        let bootstrap: String
        let systemInstructions: String
        let toolSchemasJSON: String
        let deliveredText: String
        let deliveredImages: [DeliveredImage]
        let toolResultSHA256: String
        let readEvidence: AgentReviewChildCallEvidence
    }

    struct Page: Codable, Sendable, Equatable {
        let schema: String
        let authorization: CanonicalArtifactReferenceV1
        let delivery: CanonicalArtifactReferenceV1
        let submission: Submission
        let writeEvidence: AgentReviewChildCallEvidence
    }

    struct Aggregate: Codable, Sendable, Equatable {
        let schema: String
        let runID: UUID
        let manifest: CanonicalArtifactReferenceV1
        let authorizations: [CanonicalArtifactReferenceV1]
        let pages: [CanonicalArtifactReferenceV1]
        let reductions: [CanonicalArtifactReferenceV1]
        let synthesis: CanonicalArtifactReferenceV1
        let findings: [RenderReviewV1.Finding]
        let completedAt: String
    }

    static var tools: [AgentRuntimeToolSchema] {
        let reference = object(["id": string, "role": string, "path": string,
            "sha256": ["type": "string", "pattern": "^[a-f0-9]{64}$"]])
        let finding = object(["id": ["type": "string", "pattern": "^[A-Za-z0-9_.-]{1,96}$"],
            "kind": ["type": "string", "enum": ["structuralError", "unresolved", "semanticConcern", "creativeAdvice", "information"]],
            "category": ["type": "string", "enum": SequenceReviewCategoryV1.allCases.map(\.rawValue)],
            "shotIDs": ["type": "array", "items": string, "minItems": 1, "maxItems": 64, "uniqueItems": true],
            "message": ["type": "string", "minLength": 1, "maxLength": 1024],
            "evidence": ["type": "array", "items": reference, "minItems": 1, "maxItems": 4]])
        return [
            .init(name: AgentReviewChildRequest.readTool,
                description: "Read the one host-bound review context. It contains every item you must inspect. Images are delivered once; repeated reads return its receipt only.",
                inputSchema: object([:])),
            .init(name: AgentReviewChildRequest.writeTool,
                description: "Record one specific observation for every supplied item ID and any additional findings. Do not claim unseen motion, audio or future predecessor renders. Existing findings are retained by the host; only the native user can accept an eligible concern. Text limits are UTF-8 byte limits.",
                inputSchema: object(["manifestID": string, "pageID": string,
                    "observations": ["type": "array", "items": object(["itemID": string,
                        "text": ["type": "string", "minLength": 1, "maxLength": 512]])],
                    "findings": ["type": "array", "maxItems": 8, "items": finding]]))
        ]
    }

    static func decodeSubmission(_ json: String) throws -> Submission {
        let bytes = Data(json.utf8)
        guard bytes.count <= 64 * 1024,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["manifestID", "pageID", "observations", "findings"] else { throw invalid() }
        guard let schema = tools.first(where: { $0.name == AgentReviewChildRequest.writeTool }) else { throw invalid() }
        try validateToolInput(in: object, against: schema.inputSchema, path: AgentReviewChildRequest.writeTool)
        return try JSONDecoder().decode(Submission.self, from: bytes)
    }

    static func contentSHA256(_ content: [ToolResult.Block]) throws -> String {
        FileDigest.sha256(of: try PlanningWriterIO.json(content))
    }

    static func publish<T: Encodable>(_ value: T, path: String, id: String, role: String,
                                     dataRoot: URL) throws -> CanonicalArtifactReferenceV1 {
        let bytes = try PlanningWriterIO.json(value)
        let parent = (path as NSString).deletingLastPathComponent
        let directory = try ProjectLocalFile.ensureDirectory(parent, dataRoot: dataRoot)
        let destination = directory.appendingPathComponent((path as NSString).lastPathComponent)
        let staged = directory.appendingPathComponent(".review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try bytes.write(to: staged, options: [.atomic])
        do { try FileManager.default.linkItem(at: staged, to: destination) }
        catch {
            guard let existing = try? ProjectLocalFile.resolve(path, dataRoot: dataRoot),
                  existing.standardizedFileURL == destination.standardizedFileURL,
                  try Data(contentsOf: existing) == bytes else { throw error }
        }
        return PlanningWriterIO.reference(path, id: id, role: role, bytes: bytes)
    }

    private static var string: [String: Any] { ["type": "string", "minLength": 1] }

    private static func readable(_ text: String) -> Bool {
        let normalized = text.precomposedStringWithCanonicalMapping
        let scalars = Array(normalized.unicodeScalars)
        func property(_ scalar: Unicode.Scalar, _ name: String) -> Bool {
            String(scalar).range(of: "\\A\\p{\(name)}\\z", options: .regularExpression) != nil
        }
        let joiningScripts = [
            "Adlam", "Ahom", "Arabic", "Balinese", "Batak", "Bengali", "Bhaiksuki", "Brahmi", "Chakma", "Chorasmian",
            "Devanagari", "Dives_Akuru", "Dogra", "Grantha", "Gujarati", "Gunjala_Gondi", "Gurmukhi", "Gurung_Khema",
            "Hanifi_Rohingya", "Hanunoo", "Javanese", "Kaithi", "Kannada", "Kawi", "Kharoshthi", "Khmer", "Khojki",
            "Khudawadi", "Lao", "Malayalam", "Mandaic", "Manichaean", "Masaram_Gondi", "Meetei_Mayek", "Modi",
            "Mongolian", "Myanmar", "Nandinagari", "Newa", "Nko", "Old_Uyghur", "Oriya", "Phags_Pa", "Psalter_Pahlavi",
            "Rejang", "Saurashtra", "Sharada", "Siddham", "Sinhala", "Sogdian", "Soyombo", "Sundanese", "Syloti_Nagri",
            "Syriac", "Tagalog", "Tai_Tham", "Takri", "Tamil", "Telugu", "Thai", "Tibetan", "Tifinagh", "Tirhuta",
            "Tulu_Tigalari", "Zanabazar_Square"
        ]
        func sameScript(_ range: ClosedRange<Int>) -> Bool {
            let significant = range.filter {
                !property(scalars[$0], "Script=Common") && !property(scalars[$0], "Script=Inherited")
            }
            guard let first = significant.first,
                  let script = joiningScripts.first(where: { property(scalars[first], "Script=\($0)") }) else { return false }
            return significant.allSatisfy { property(scalars[$0], "Script=\(script)") }
        }
        func letter(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
            default: return false
            }
        }
        func nonzeroMark(_ scalar: Unicode.Scalar) -> Bool {
            scalar.properties.generalCategory == .nonspacingMark && scalar.properties.canonicalCombiningClass.rawValue != 0
        }
        func viramaStart(_ index: Int) -> Int? {
            var previous = index - 1
            while previous >= 0, nonzeroMark(scalars[previous]), scalars[previous].properties.canonicalCombiningClass.rawValue != 9 {
                previous -= 1
            }
            guard previous >= 0, scalars[previous].properties.canonicalCombiningClass.rawValue == 9 else { return nil }
            previous -= 1
            while previous >= 0, scalars[previous].properties.generalCategory == .nonspacingMark { previous -= 1 }
            return previous >= 0 && letter(scalars[previous]) ? previous : nil
        }
        func emojiVariationBase(_ value: UInt32) -> Bool {
            // Unicode 17 emoji-variation-sequences.txt; Emoji alone also includes invalid selector bases.
            switch value {
            case 0x23, 0x2a, 0x30...0x39, 0xa9, 0xae, 0x203c, 0x2049, 0x2122, 0x2139, 0x2194...0x2199, 0x21a9...0x21aa,
                 0x231a...0x231b, 0x2328, 0x23cf, 0x23e9...0x23f3, 0x23f8...0x23fa, 0x24c2, 0x25aa...0x25ab, 0x25b6, 0x25c0,
                 0x25fb...0x25fe, 0x2600...0x2604, 0x260e, 0x2611, 0x2614...0x2615, 0x2618, 0x261d, 0x2620, 0x2622...0x2623,
                 0x2626, 0x262a, 0x262e...0x262f, 0x2638...0x263a, 0x2640, 0x2642, 0x2648...0x2653, 0x265f...0x2660, 0x2663,
                 0x2665...0x2666, 0x2668, 0x267b, 0x267e...0x267f, 0x2692...0x2697, 0x2699, 0x269b...0x269c, 0x26a0...0x26a1,
                 0x26a7, 0x26aa...0x26ab, 0x26b0...0x26b1, 0x26bd...0x26be, 0x26c4...0x26c5, 0x26c8, 0x26ce...0x26cf, 0x26d1,
                 0x26d3...0x26d4, 0x26e9...0x26ea, 0x26f0...0x26f5, 0x26f7...0x26fa, 0x26fd, 0x2702, 0x2705, 0x2708...0x270d,
                 0x270f, 0x2712, 0x2714, 0x2716, 0x271d, 0x2721, 0x2728, 0x2733...0x2734, 0x2744, 0x2747, 0x274c, 0x274e,
                 0x2753...0x2755, 0x2757, 0x2763...0x2764, 0x2795...0x2797, 0x27a1, 0x27b0, 0x27bf, 0x2934...0x2935,
                 0x2b05...0x2b07, 0x2b1b...0x2b1c, 0x2b50, 0x2b55, 0x3030, 0x303d, 0x3297, 0x3299, 0x1f004,
                 0x1f170...0x1f171, 0x1f17e...0x1f17f, 0x1f202, 0x1f21a, 0x1f22f, 0x1f237, 0x1f30d...0x1f30f, 0x1f315,
                 0x1f31c, 0x1f321, 0x1f324...0x1f32c, 0x1f336, 0x1f378, 0x1f37d, 0x1f393, 0x1f396...0x1f397,
                 0x1f399...0x1f39b, 0x1f39e...0x1f39f, 0x1f3a7, 0x1f3ac...0x1f3ae, 0x1f3c2, 0x1f3c4, 0x1f3c6,
                 0x1f3ca...0x1f3ce, 0x1f3d4...0x1f3e0, 0x1f3ed, 0x1f3f3, 0x1f3f5, 0x1f3f7, 0x1f408, 0x1f415, 0x1f41f,
                 0x1f426, 0x1f43f, 0x1f441...0x1f442, 0x1f446...0x1f449, 0x1f44d...0x1f44e, 0x1f453, 0x1f46a, 0x1f47d,
                 0x1f4a3, 0x1f4b0, 0x1f4b3, 0x1f4bb, 0x1f4bf, 0x1f4cb, 0x1f4da, 0x1f4df, 0x1f4e4...0x1f4e6,
                 0x1f4ea...0x1f4ed, 0x1f4f7, 0x1f4f9...0x1f4fb, 0x1f4fd, 0x1f508, 0x1f50d, 0x1f512...0x1f513,
                 0x1f549...0x1f54a, 0x1f550...0x1f567, 0x1f56f...0x1f570, 0x1f573...0x1f579, 0x1f587, 0x1f58a...0x1f58d,
                 0x1f590, 0x1f5a5, 0x1f5a8, 0x1f5b1...0x1f5b2, 0x1f5bc, 0x1f5c2...0x1f5c4, 0x1f5d1...0x1f5d3,
                 0x1f5dc...0x1f5de, 0x1f5e1, 0x1f5e3, 0x1f5e8, 0x1f5ef, 0x1f5f3, 0x1f5fa, 0x1f610, 0x1f687, 0x1f68d, 0x1f691,
                 0x1f694, 0x1f698, 0x1f6ad, 0x1f6b2, 0x1f6b9...0x1f6ba, 0x1f6bc, 0x1f6cb, 0x1f6cd...0x1f6cf,
                 0x1f6e0...0x1f6e5, 0x1f6e9, 0x1f6f0, 0x1f6f3: return true
            default: return false
            }
        }
        func contextual(_ index: Int) -> Bool {
            guard index > 0 else { return false }
            switch scalars[index].value {
            case 0xfe0e, 0xfe0f: return emojiVariationBase(scalars[index - 1].value)
            case 0x200c:
                var previous = index - 1
                while previous >= 0, property(scalars[previous], "Joining_Type=Transparent") { previous -= 1 }
                if previous >= 0, index + 1 < scalars.count,
                   property(scalars[previous], "Joining_Type=Dual_Joining") || property(scalars[previous], "Joining_Type=Left_Joining"),
                   property(scalars[index + 1], "Joining_Type=Dual_Joining") || property(scalars[index + 1], "Joining_Type=Right_Joining"),
                   sameScript(previous...(index + 1)) { return true }
                guard let start = viramaStart(index) else { return false }
                var next = index + 1
                while next < scalars.count, nonzeroMark(scalars[next]) { next += 1 }
                return next < scalars.count && letter(scalars[next]) && sameScript(start...next)
            case 0x200d:
                if let start = viramaStart(index), sameScript(start...index) {
                    return index + 1 == scalars.count || (!property(scalars[index + 1], "Indic_Syllabic_Category=Vowel_Dependent")
                        && ![0x200c, 0x200d, 0xfe0e, 0xfe0f].contains(scalars[index + 1].value))
                }
                guard index + 1 < scalars.count, property(scalars[index + 1], "Extended_Pictographic") else { return false }
                var previous = index - 1
                if scalars[previous].properties.isEmojiModifier { previous -= 1 }
                if previous >= 0, [0xfe0e, 0xfe0f].contains(scalars[previous].value) { previous -= 1 }
                return previous >= 0 && property(scalars[previous], "Extended_Pictographic")
            default: return false
            }
        }
        let subdivisionFlags: Set<String> = [
            "\u{1f3f4}\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}",
            "\u{1f3f4}\u{e0067}\u{e0062}\u{e0073}\u{e0063}\u{e0074}\u{e007f}",
            "\u{1f3f4}\u{e0067}\u{e0062}\u{e0077}\u{e006c}\u{e0073}\u{e007f}"
        ]
        var tagPositions = Set<Int>(), offset = 0
        for character in normalized {
            let count = character.unicodeScalars.count
            if subdivisionFlags.contains(String(character)) { tagPositions.formUnion((offset + 1)..<(offset + count)) }
            offset += count
        }
        var hasVisibleText = false
        for index in scalars.indices {
            let scalar = scalars[index]
            let joined = contextual(index) || tagPositions.contains(index)
            if scalar.properties.isBidiControl || scalar.properties.isNoncharacterCodePoint
                || (scalar.properties.isDefaultIgnorableCodePoint && !joined) { return false }
            switch scalar.properties.generalCategory {
            case .control: if ![9, 10, 13].contains(scalar.value) { return false }
            case .format: if !joined { return false }
            case .lineSeparator, .paragraphSeparator, .privateUse, .unassigned: return false
            case .nonspacingMark, .spacingMark, .enclosingMark: break
            default:
                if !scalar.properties.isWhitespace, !scalar.properties.isDefaultIgnorableCodePoint, scalar.value != 0x2800 {
                    hasVisibleText = true
                }
            }
        }
        return hasVisibleText
    }

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }

    private static func invalid() -> GateBlocked {
        GateBlocked("The model review must answer every item in its exact context without changing existing findings or accepting them.")
    }
}
