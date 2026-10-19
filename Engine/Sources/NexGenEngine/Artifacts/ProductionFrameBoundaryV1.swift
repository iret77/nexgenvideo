import Foundation

public struct ProductionFrameBoundaryV1: Codable, Sendable, Equatable {
    public let characterCount: Int
    public let characterPositions: String
    public let gaze: String
    public let visibleZones: [String]
    public let framing: String?
    public let cameraAngle: String?
    public let cameraHeight: String?

    public init(characterCount: Int, characterPositions: String, gaze: String, visibleZones: [String],
                framing: String? = nil, cameraAngle: String? = nil, cameraHeight: String? = nil) {
        self.characterCount = characterCount
        self.characterPositions = characterPositions
        self.gaze = gaze
        self.visibleZones = visibleZones
        self.framing = framing
        self.cameraAngle = cameraAngle
        self.cameraHeight = cameraHeight
    }

    public func validate(movingCamera: Bool) throws {
        try PlanningValidation.require(characterCount >= 0, "frameBoundary.characterCount")
        if characterCount > 0 {
            try PlanningValidation.text(characterPositions, "frameBoundary.characterPositions")
            try PlanningValidation.text(gaze, "frameBoundary.gaze")
        }
        try PlanningValidation.unique(visibleZones, "frameBoundary.visibleZones")
        for zone in visibleZones { try PlanningValidation.text(zone, "frameBoundary.visibleZone") }
        for field in [framing, cameraAngle, cameraHeight].compactMap({ $0 }) {
            try PlanningValidation.text(field, "frameBoundary.camera")
        }
        try PlanningValidation.require(!movingCamera || (framing != nil && cameraAngle != nil && cameraHeight != nil),
                                       "frameBoundary.movingCamera")
    }

    public var promptConstraints: [String] {
        var values = ["Visible characters: \(characterCount)"]
        if characterCount > 0 { values += ["Character positions: " + characterPositions, "Gaze: " + gaze] }
        values += ["Visible zones: " + (visibleZones.isEmpty ? "none" : visibleZones.joined(separator: ", "))]
        if let framing { values.append("Framing: " + framing) }
        if let cameraAngle { values.append("Camera angle: " + cameraAngle) }
        if let cameraHeight { values.append("Camera height: " + cameraHeight) }
        return values
    }
}
