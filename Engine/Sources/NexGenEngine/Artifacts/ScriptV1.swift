import Foundation

public struct ScriptV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "script/v1"
    public static let currentPath = "script/current.v1.json"

    public struct SourceAnchor: Codable, Sendable, Equatable {
        public let sourceID: String
        public let startByte: Int
        public let endByte: Int
        public let excerptSHA256: String

        public init(sourceID: String, startByte: Int, endByte: Int, excerptSHA256: String) {
            self.sourceID = sourceID
            self.startByte = startByte
            self.endByte = endByte
            self.excerptSHA256 = excerptSHA256
        }
    }

    public struct Event: Codable, Sendable, Equatable {
        public let id: String
        public let action: String
        public let dialogue: String?
        public let treatmentBeatIDs: [String]
        public let sourceAnchors: [SourceAnchor]

        public init(id: String, action: String, dialogue: String? = nil, treatmentBeatIDs: [String], sourceAnchors: [SourceAnchor] = []) {
            self.id = id
            self.action = action
            self.dialogue = dialogue
            self.treatmentBeatIDs = treatmentBeatIDs
            self.sourceAnchors = sourceAnchors
        }
    }

    public struct Scene: Codable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let adaptation: String
        public let events: [Event]

        public init(id: String, title: String, adaptation: String, events: [Event]) {
            self.id = id
            self.title = title
            self.adaptation = adaptation
            self.events = events
        }
    }

    public let schema: String
    public let header: PlanningArtifactHeaderV1
    public let summary: String
    public let scenes: [Scene]

    public init(schema: String = schemaVersion, header: PlanningArtifactHeaderV1, summary: String, scenes: [Scene]) {
        self.schema = schema
        self.header = header
        self.summary = summary
        self.scenes = scenes
    }

    public static func versionPath(_ revision: Int) -> String { "script/v\(revision).v1.json" }
    public var events: [Event] { scenes.flatMap(\.events) }
}

public enum ScriptValidatorV1 {
    public static func validate(_ value: ScriptV1, treatmentBeatIDs: Set<String>, sourceBytes: [String: Data] = [:]) throws {
        try PlanningValidation.require(value.schema == ScriptV1.schemaVersion, "script.schema")
        try value.header.validate()
        try PlanningValidation.text(value.summary, "script.summary")
        try PlanningValidation.require(!value.scenes.isEmpty && !treatmentBeatIDs.isEmpty, "script.scenes")
        try PlanningValidation.unique(value.scenes.map(\.id), "script.sceneIDs")
        try PlanningValidation.unique(value.events.map(\.id), "script.eventIDs")
        var covered = Set<String>()
        for scene in value.scenes {
            try PlanningValidation.identifier(scene.id, "script.scene.id")
            try PlanningValidation.text(scene.title, "script.scene.title")
            try PlanningValidation.text(scene.adaptation, "script.scene.adaptation")
            try PlanningValidation.require(!scene.events.isEmpty, "script.scene.events")
            for event in scene.events {
                try PlanningValidation.identifier(event.id, "script.event.id")
                try PlanningValidation.text(event.action, "script.event.action")
                try PlanningValidation.unique(event.treatmentBeatIDs, "script.event.beatIDs")
                try PlanningValidation.require(!event.treatmentBeatIDs.isEmpty
                    && Set(event.treatmentBeatIDs).isSubset(of: treatmentBeatIDs), "script.event.beatCoverage")
                covered.formUnion(event.treatmentBeatIDs)
                for anchor in event.sourceAnchors {
                    try PlanningValidation.hash(anchor.excerptSHA256, "script.source.excerptSHA256")
                    guard let bytes = sourceBytes[anchor.sourceID], anchor.startByte >= 0,
                          anchor.endByte > anchor.startByte, anchor.endByte <= bytes.count else {
                        throw ProductionPlanningError.invalid("script.source.byteRange")
                    }
                    let excerpt = bytes.subdata(in: anchor.startByte..<anchor.endByte)
                    try PlanningValidation.require(value.header.inputs.contains {
                        $0.id == anchor.sourceID && $0.sha256 == FileDigest.sha256(of: bytes)
                    }, "script.source.binding")
                    try PlanningValidation.require(String(data: excerpt, encoding: .utf8) != nil, "script.source.utf8Range")
                    try PlanningValidation.require(FileDigest.sha256(of: excerpt) == anchor.excerptSHA256, "script.source.excerpt")
                }
            }
        }
        try PlanningValidation.require(covered == treatmentBeatIDs, "script.treatmentCoverage")
    }
}
