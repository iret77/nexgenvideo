import Foundation

public struct StoryboardV2: Codable, Sendable, Equatable {
    public static let schemaVersion = "storyboard/v2"
    public static let currentPath = "storyboard/current.v2.yaml"

    public struct StoryStep: Codable, Sendable, Equatable {
        public let id: String
        public let sceneID: String
        public let eventIDs: [String]
        public let function: StepFunction
        public let action: String

        public init(id: String, sceneID: String, eventIDs: [String], function: StepFunction, action: String) {
            self.id = id
            self.sceneID = sceneID
            self.eventIDs = eventIDs
            self.function = function
            self.action = action
        }
    }

    public let schema: String
    public let header: PlanningArtifactHeaderV1
    public let summary: String
    public let steps: [StoryStep]

    public init(schema: String = schemaVersion, header: PlanningArtifactHeaderV1, summary: String, steps: [StoryStep]) {
        self.schema = schema
        self.header = header
        self.summary = summary
        self.steps = steps
    }

    public static func versionPath(_ revision: Int) -> String { "storyboard/v\(revision).v2.yaml" }
}

public struct StoryboardCausalityV2: Codable, Sendable, Equatable {
    public static let schemaVersion = "storyboard-causality/v2"
    public static let currentPath = "storyboard/causality-current.v2.json"

    public struct Binding: Codable, Sendable, Equatable {
        public let stepID: String
        public let beatIDs: [String]
        public let reason: String

        public init(stepID: String, beatIDs: [String], reason: String) {
            self.stepID = stepID
            self.beatIDs = beatIDs
            self.reason = reason
        }
    }

    public let schema: String
    public let header: PlanningArtifactHeaderV1
    public let bindings: [Binding]

    public init(schema: String = schemaVersion, header: PlanningArtifactHeaderV1, bindings: [Binding]) {
        self.schema = schema
        self.header = header
        self.bindings = bindings
    }

    public static func versionPath(_ revision: Int) -> String { "storyboard/causality/v\(revision).v2.json" }
}

public struct StoryboardIdentityV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "storyboard-identity/v1"
    public static let currentPath = "storyboard/identity-current.v1.json"

    public struct Entry: Codable, Sendable, Equatable {
        public let shotID: String
        public let primaryStepID: String
        public let actionSHA256: String
        public let introducedRevision: Int
        public let retiredRevision: Int?

        public init(shotID: String, primaryStepID: String, actionSHA256: String, introducedRevision: Int, retiredRevision: Int? = nil) {
            self.shotID = shotID
            self.primaryStepID = primaryStepID
            self.actionSHA256 = actionSHA256
            self.introducedRevision = introducedRevision
            self.retiredRevision = retiredRevision
        }
    }

    public let schema: String
    public let header: PlanningArtifactHeaderV1
    public let entries: [Entry]

    public init(schema: String = schemaVersion, header: PlanningArtifactHeaderV1, entries: [Entry]) {
        self.schema = schema
        self.header = header
        self.entries = entries
    }

    public static func versionPath(_ revision: Int) -> String { "storyboard/identity-v\(revision).v1.json" }
}

public enum StoryboardValidatorV2 {
    public static func validate(_ value: StoryboardV2, causality: StoryboardCausalityV2, script: ScriptV1) throws {
        try PlanningValidation.require(value.schema == StoryboardV2.schemaVersion
            && causality.schema == StoryboardCausalityV2.schemaVersion, "storyboard.schema")
        try value.header.validate()
        try causality.header.validate()
        try PlanningValidation.require(value.header.projectID == script.header.projectID
            && causality.header.projectID == value.header.projectID
            && causality.header.revision == value.header.revision, "storyboard.header")
        try PlanningValidation.text(value.summary, "storyboard.summary")
        try PlanningValidation.require(!value.steps.isEmpty, "storyboard.steps")
        try PlanningValidation.unique(value.steps.map(\.id), "storyboard.stepIDs")
        try PlanningValidation.unique(causality.bindings.map(\.stepID), "storyboard.causality.stepIDs")
        try PlanningValidation.unique(script.scenes.map(\.id), "script.sceneIDs")
        try PlanningValidation.require(Set(causality.bindings.map(\.stepID)) == Set(value.steps.map(\.id)), "storyboard.causality.coverage")
        let scenes = Dictionary(uniqueKeysWithValues: script.scenes.map { ($0.id, $0) })
        let bindings = Dictionary(uniqueKeysWithValues: causality.bindings.map { ($0.stepID, $0) })
        var coveredBeats = Set<String>()
        for step in value.steps {
            try PlanningValidation.identifier(step.id, "storyboard.step.id")
            try PlanningValidation.text(step.action, "storyboard.step.action")
            try PlanningValidation.unique(step.eventIDs, "storyboard.step.eventIDs")
            guard let scene = scenes[step.sceneID], !step.eventIDs.isEmpty,
                  Set(step.eventIDs).isSubset(of: Set(scene.events.map(\.id))),
                  let binding = bindings[step.id] else {
                throw ProductionPlanningError.invalid("storyboard.step.scriptReferences")
            }
            let allowed = Set(scene.events.filter { step.eventIDs.contains($0.id) }.flatMap(\.treatmentBeatIDs))
            try PlanningValidation.unique(binding.beatIDs, "storyboard.causality.beatIDs")
            try PlanningValidation.require(Set(binding.beatIDs).isSubset(of: allowed), "storyboard.causality.allowedBeats")
            try PlanningValidation.require(step.function != .story || !binding.beatIDs.isEmpty, "storyboard.causality.storyBeat")
            try PlanningValidation.text(binding.reason, "storyboard.causality.reason")
            coveredBeats.formUnion(binding.beatIDs)
        }
        try PlanningValidation.require(coveredBeats == Set(script.events.flatMap(\.treatmentBeatIDs)), "storyboard.causality.beatCoverage")
    }
}
