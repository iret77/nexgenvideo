import Foundation

/// Storyboard v1: a per-section sequence of steps bridging the Treatment
/// (story) and the Shotlist (technical execution). Port of
/// `storyboard/schema.py`.
public let storyboardSchemaVersion = "storyboard/v1"

/// Step-ID convention `<section_id>.<NN>`, e.g. `verse1.03`. Port of
/// `storyboard/schema.py::STEP_ID_RE`.
private let stepIDPattern = #"^[a-z0-9_]+\.\d{2}$"#

/// A step's function within its section. Port of
/// `storyboard/schema.py::StepFunction`.
public enum StepFunction: String, Codable, Sendable, CaseIterable {
    case story
    case moodInsert = "mood-insert"
    case performance
    case cutaway
    case structuralAnchor = "structural-anchor"
    case transition
}

/// One storyboard step. Port of `storyboard/schema.py::Step`.
public struct Step: Codable, Sendable, Equatable {
    public var id: String
    public var function: StepFunction
    /// A step's source intent flows into its shots (hybrid production, issue #129).
    /// Defaults to `.generated` so every existing storyboard decodes unchanged.
    public var sourceMode: SourceMode
    public var subject: String
    public var camera: String
    public var settingHint: String
    public var locationViewRequest: String
    public var characterViewRequest: [String: String]
    public var propRequest: [String]
    public var framing: String
    public var visibleZones: [String]
    public var zoneIntroduces: [String]
    public var cameraSetup: [String: String]
    public var characterBlocking: [[String: String]]
    public var notes: String

    private enum CodingKeys: String, CodingKey {
        case id
        case function
        case sourceMode = "source_mode"
        case subject
        case camera
        case settingHint = "setting_hint"
        case locationViewRequest = "location_view_request"
        case characterViewRequest = "character_view_request"
        case propRequest = "prop_request"
        case framing
        case visibleZones = "visible_zones"
        case zoneIntroduces = "zone_introduces"
        case cameraSetup = "camera_setup"
        case characterBlocking = "character_blocking"
        case notes
    }

    public init(
        id: String,
        function: StepFunction,
        sourceMode: SourceMode = .generated,
        subject: String,
        camera: String,
        settingHint: String = "",
        locationViewRequest: String = "",
        characterViewRequest: [String: String] = [:],
        propRequest: [String] = [],
        framing: String = "",
        visibleZones: [String] = [],
        zoneIntroduces: [String] = [],
        cameraSetup: [String: String] = [:],
        characterBlocking: [[String: String]] = [],
        notes: String = ""
    ) throws {
        self.id = id
        self.function = function
        self.sourceMode = sourceMode
        self.subject = subject
        self.camera = camera
        self.settingHint = settingHint
        self.locationViewRequest = locationViewRequest
        self.characterViewRequest = characterViewRequest
        self.propRequest = propRequest
        self.framing = framing
        self.visibleZones = visibleZones
        self.zoneIntroduces = zoneIntroduces
        self.cameraSetup = cameraSetup
        self.characterBlocking = characterBlocking
        self.notes = notes
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        function = try container.decode(StepFunction.self, forKey: .function)
        sourceMode = try container.decodeIfPresent(SourceMode.self, forKey: .sourceMode) ?? .generated
        subject = try container.decode(String.self, forKey: .subject)
        camera = try container.decode(String.self, forKey: .camera)
        settingHint = try container.decodeIfPresent(String.self, forKey: .settingHint) ?? ""
        locationViewRequest = try container.decodeIfPresent(String.self, forKey: .locationViewRequest) ?? ""
        characterViewRequest =
            try container.decodeIfPresent([String: String].self, forKey: .characterViewRequest) ?? [:]
        propRequest = try container.decodeIfPresent([String].self, forKey: .propRequest) ?? []
        framing = try container.decodeIfPresent(String.self, forKey: .framing) ?? ""
        visibleZones = try container.decodeIfPresent([String].self, forKey: .visibleZones) ?? []
        zoneIntroduces = try container.decodeIfPresent([String].self, forKey: .zoneIntroduces) ?? []
        cameraSetup = try container.decodeIfPresent([String: String].self, forKey: .cameraSetup) ?? [:]
        characterBlocking =
            try container.decodeIfPresent([[String: String]].self, forKey: .characterBlocking) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        try validate()
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case invalidID(String)
        case emptySubject
        case emptyCamera
    }

    /// Port of `Step._id_format` and `Step._nonempty` (subject, camera).
    public func validate() throws {
        guard id.range(of: stepIDPattern, options: .regularExpression) != nil else {
            throw ValidationError.invalidID(id)
        }
        guard !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptySubject
        }
        guard !camera.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyCamera
        }
    }
}

/// One section of the storyboard (e.g. a song's `verse1`). Port of
/// `storyboard/schema.py::Section`.
public struct Section: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var timeStart: Double
    public var timeEnd: Double
    public var energy: String
    public var function: String
    public var patternOverride: String?
    public var steps: [Step]

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case timeStart = "time_start"
        case timeEnd = "time_end"
        case energy
        case function
        case patternOverride = "pattern_override"
        case steps
    }

    public init(
        id: String,
        label: String = "",
        timeStart: Double = 0.0,
        timeEnd: Double = 0.0,
        energy: String = "",
        function: String = "",
        patternOverride: String? = nil,
        steps: [Step] = []
    ) throws {
        self.id = id
        self.label = label
        self.timeStart = timeStart
        self.timeEnd = timeEnd
        self.energy = energy
        self.function = function
        self.patternOverride = patternOverride
        self.steps = steps
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        timeStart = try container.decodeIfPresent(Double.self, forKey: .timeStart) ?? 0.0
        timeEnd = try container.decodeIfPresent(Double.self, forKey: .timeEnd) ?? 0.0
        energy = try container.decodeIfPresent(String.self, forKey: .energy) ?? ""
        function = try container.decodeIfPresent(String.self, forKey: .function) ?? ""
        patternOverride = try container.decodeIfPresent(String.self, forKey: .patternOverride)
        steps = try container.decodeIfPresent([Step].self, forKey: .steps) ?? []
        try validate()
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case mixedStepPrefixes(expected: String, found: String)
    }

    /// Port of `Section._steps_have_section_prefix`: all step IDs must share
    /// the prefix (substring before the first ".") of the first step.
    public func validate() throws {
        guard let first = steps.first else { return }
        let prefix = first.id.split(separator: ".", maxSplits: 1).first.map(String.init) ?? first.id
        for step in steps {
            let stepPrefix = step.id.split(separator: ".", maxSplits: 1).first.map(String.init) ?? step.id
            guard stepPrefix == prefix else {
                throw ValidationError.mixedStepPrefixes(expected: prefix, found: step.id)
            }
        }
    }
}

/// Storyboard metadata. Port of `storyboard/schema.py::StoryboardMeta`.
public struct StoryboardMeta: Codable, Sendable, Equatable {
    public var project: String
    public var version: Int
    public var generated: String
    public var origin: String
    public var generator: String
    public var summaryOneline: String
    public var notes: String?

    private enum CodingKeys: String, CodingKey {
        case project
        case version
        case generated
        case origin
        case generator
        case summaryOneline = "summary_oneline"
        case notes
    }

    public init(
        project: String,
        version: Int,
        generated: String,
        origin: String = "agent_proposal",
        generator: String = "storyboard-agent@v0.5",
        summaryOneline: String = "",
        notes: String? = nil
    ) throws {
        self.project = project
        self.version = version
        self.generated = generated
        self.origin = origin
        self.generator = generator
        self.summaryOneline = summaryOneline
        self.notes = notes
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(String.self, forKey: .project)
        version = try container.decode(Int.self, forKey: .version)
        generated = try container.decode(String.self, forKey: .generated)
        origin = try container.decodeIfPresent(String.self, forKey: .origin) ?? "agent_proposal"
        generator = try container.decodeIfPresent(String.self, forKey: .generator) ?? "storyboard-agent@v0.5"
        summaryOneline = try container.decodeIfPresent(String.self, forKey: .summaryOneline) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        try validate()
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case versionNotPositive(Int)
    }

    /// Mirrors pydantic's `Field(ge=1)` on `version`.
    public func validate() throws {
        guard version >= 1 else { throw ValidationError.versionNotPositive(version) }
    }
}

/// Storyboard v1. Port of `storyboard/schema.py::Storyboard`.
public struct Storyboard: Codable, Sendable, Equatable {
    public var schema: String
    public var meta: StoryboardMeta
    public var sections: [Section]

    private enum CodingKeys: String, CodingKey {
        case schema
        case meta
        case sections
    }

    public init(schema: String = storyboardSchemaVersion, meta: StoryboardMeta, sections: [Section] = []) throws {
        self.schema = schema
        self.meta = meta
        self.sections = sections
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? storyboardSchemaVersion
        meta = try container.decode(StoryboardMeta.self, forKey: .meta)
        sections = try container.decodeIfPresent([Section].self, forKey: .sections) ?? []
        try validate()
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case wrongSchema(String)
        case duplicateStepID(String)
    }

    /// Port of `Storyboard._schema_const` and `Storyboard._step_ids_unique`.
    public func validate() throws {
        guard schema == storyboardSchemaVersion else {
            throw ValidationError.wrongSchema(schema)
        }
        var seen: Set<String> = []
        for step in allSteps() {
            guard !seen.contains(step.id) else { throw ValidationError.duplicateStepID(step.id) }
            seen.insert(step.id)
        }
    }

    /// Port of `Storyboard.all_steps`.
    public func allSteps() -> [Step] {
        sections.flatMap(\.steps)
    }

    /// Aggregate: which location needs which sheet views. Port of
    /// `Storyboard.location_view_demand`.
    public func locationViewDemand() -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for step in allSteps() {
            let view = step.locationViewRequest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !view.isEmpty else { continue }
            let hint = step.settingHint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hint.isEmpty else { continue }
            let head = hint.split(separator: ",", maxSplits: 1).first.map(String.init) ?? hint
            let normalizedHead = Self.normalizeHead(head)
            guard !normalizedHead.isEmpty else { continue }
            out[normalizedHead, default: []].insert(view)
        }
        return out
    }

    /// Port of `re.sub(r"[^a-z0-9]+", "_", head).strip("_")`, applied to
    /// `head.strip().lower()`.
    private static func normalizeHead(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let collapsed = lowered.replacingOccurrences(
            of: "[^a-z0-9]+", with: "_", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

/// Disk I/O for the storyboard version family, mirroring the free functions
/// in `storyboard/schema.py`. Kept as static functions over `PipelineLayout`
/// paths rather than folded into `ArtifactStore`: `load` returns an Optional
/// on a missing file (not a thrown not-found), matching the Python
/// `-> Storyboard | None` signature.
public enum StoryboardStore {
    /// Which storyboard version to load. Mirrors Python's `version: int | "current"`.
    public enum Version: Sendable, Equatable {
        case current
        case number(Int)
    }

    /// Port of `storyboard/schema.py::next_version`.
    public static func nextVersion(dataRoot: URL) -> Int {
        let dir = PipelineLayout.url(PipelineLayout.storyboardDir, in: dataRoot)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return 1 }
        var nums: [Int] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("v"), name.hasSuffix(".yaml") else { continue }
            let middle = name.dropFirst().dropLast(5)
            if let n = Int(middle) { nums.append(n) }
        }
        return (nums.max() ?? 0) + 1
    }

    /// Port of `storyboard/schema.py::save`. Always writes `vN.yaml`; writes
    /// `current.yaml` too unless `writeCurrent` is false.
    @discardableResult
    public static func save(_ storyboard: Storyboard, to dataRoot: URL, writeCurrent: Bool = true) throws -> URL {
        let yaml = try YAMLCoding.encode(storyboard)
        let versionURL = PipelineLayout.url(
            PipelineLayout.storyboardVersionFile(storyboard.meta.version), in: dataRoot
        )
        try FileManager.default.createDirectory(
            at: versionURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try yaml.write(to: versionURL, atomically: true, encoding: .utf8)
        if writeCurrent {
            let currentURL = PipelineLayout.url(PipelineLayout.storyboardCurrentFile, in: dataRoot)
            try yaml.write(to: currentURL, atomically: true, encoding: .utf8)
        }
        return versionURL
    }

    /// Port of `storyboard/schema.py::load`. Returns `nil` if the file
    /// doesn't exist, matching Python's `-> Storyboard | None` (not throwing
    /// not-found).
    public static func load(dataRoot: URL, version: Version = .current) throws -> Storyboard? {
        let relativePath: String
        switch version {
        case .current:
            relativePath = PipelineLayout.storyboardCurrentFile
        case .number(let n):
            relativePath = PipelineLayout.storyboardVersionFile(n)
        }
        let url = PipelineLayout.url(relativePath, in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try YAMLCoding.decode(Storyboard.self, from: text)
    }
}
