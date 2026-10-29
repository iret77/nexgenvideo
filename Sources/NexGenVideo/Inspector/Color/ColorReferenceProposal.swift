import Foundation

struct ColorReferenceProposal: Codable, Sendable, Equatable {
    let comparisonID: UUID
    let clipID: String
    let referenceID: String
    let rationale: String
    let grade: [String: Double]

    static let ranges: [String: ClosedRange<Double>] = [
        "exposure": -3...3, "contrast": 0.5...1.5, "saturation": 0...2,
        "vibrance": -1...1, "temperature": 2000...11000, "tint": -100...100,
        "highlights": -1...1, "shadows": -1...1, "blacks": -1...1, "whites": -1...1,
    ]

    static var schema: [String: Any] {
        let controls = ranges.mapValues { ["type": "number", "minimum": $0.lowerBound, "maximum": $0.upperBound] as [String: Any] }
        return ["type": "object", "additionalProperties": false,
            "properties": [
                "comparisonID": ["type": "string"], "clipID": ["type": "string"], "referenceID": ["type": "string"],
                "rationale": ["type": "string", "minLength": 1],
                "grade": ["type": "object", "additionalProperties": false, "minProperties": 1, "properties": controls],
            ], "required": ["comparisonID", "clipID", "referenceID", "rationale", "grade"]]
    }

    func validate() throws {
        guard !clipID.isEmpty, !referenceID.isEmpty, !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !grade.isEmpty, grade.allSatisfy({ key, value in value.isFinite && Self.ranges[key]?.contains(value) == true }) else {
            throw ToolError("The color proposal must contain supported finite controls and an explanation.")
        }
    }

    var applyArguments: [String: Any] { grade.reduce(into: ["clipIds": [clipID]]) { $0[$1.key] = $1.value } }
}

struct ColorReferenceMeasurements: Decodable, Sendable {
    struct Levels: Decodable, Sendable { let black: Double; let white: Double; let mean: Double; let clipLowPct: Double; let clipHighPct: Double }
    struct Balance: Decodable, Sendable { let warmCool: Double; let greenMagenta: Double }
    struct Readout: Decodable, Sendable { let luma: Levels; let saturation: Double; let meanRGB: [Double]; let balance: Balance }
    struct Gap: Decodable, Sendable { let lumaBlack: Double; let lumaWhite: Double; let lumaMean: Double; let warmCool: Double; let greenMagenta: Double; let saturation: Double; let hints: [String] }
    let clip: Readout
    let reference: Readout
    let gap: Gap
}
