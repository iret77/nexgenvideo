import Foundation

/// Treatment (K3): a versioned director's treatment ahead of the shotlist.
/// Port of `treatment/schema.py`. Persisted as Markdown with a YAML
/// frontmatter header, not plain YAML — versions are never overwritten
/// (`treatment/v1.md`, `v2.md`, ...), with `treatment/current.md` a copy of
/// the latest.
public let treatmentSchemaVersion = "treatment/v1"

/// Port of `treatment/schema.py::TreatmentMeta.origin` (`Literal[...]`).
public enum TreatmentOrigin: String, Codable, Sendable, CaseIterable {
    case agentProposal = "agent_proposal"
    case agentRevision = "agent_revision"
    case userSupplied = "user_supplied"
    case userRevision = "user_revision"
    case brainstormClaude = "brainstorm_claude"
    case brainstormOpenai = "brainstorm_openai"
    case brainstormGemini = "brainstorm_gemini"
    case brainstormSynthesis = "brainstorm_synthesis"
}

/// The frontmatter header of a treatment file. Port of
/// `treatment/schema.py::TreatmentMeta`.
public struct TreatmentMeta: Codable, Sendable, Equatable {
    public var schema: String
    public var project: String
    /// Python: `Annotated[int, Field(ge=1)]`, enforced in `validate()`.
    public var version: Int
    public var generated: String
    public var origin: TreatmentOrigin
    public var generator: String
    public var summaryOneline: String
    public var title: String?
    public var notes: String?

    private enum CodingKeys: String, CodingKey {
        case schema
        case project
        case version
        case generated
        case origin
        case generator
        case summaryOneline = "summary_oneline"
        case title
        case notes
    }

    public init(
        schema: String = treatmentSchemaVersion,
        project: String,
        version: Int,
        generated: String,
        origin: TreatmentOrigin,
        generator: String,
        summaryOneline: String,
        title: String? = nil,
        notes: String? = nil
    ) throws {
        self.schema = schema
        self.project = project
        self.version = version
        self.generated = generated
        self.origin = origin
        self.generator = generator
        self.summaryOneline = summaryOneline
        self.title = title
        self.notes = notes
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? treatmentSchemaVersion
        project = try container.decode(String.self, forKey: .project)
        version = try container.decode(Int.self, forKey: .version)
        generated = try container.decode(String.self, forKey: .generated)
        origin = try container.decode(TreatmentOrigin.self, forKey: .origin)
        generator = try container.decode(String.self, forKey: .generator)
        summaryOneline = try container.decode(String.self, forKey: .summaryOneline)
        title = try container.decodeIfPresent(String.self, forKey: .title)
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

/// Markdown treatment body + its frontmatter header. Port of
/// `treatment/schema.py::Treatment`.
public struct Treatment: Sendable, Equatable {
    public var meta: TreatmentMeta
    public var bodyMarkdown: String

    public init(meta: TreatmentMeta, bodyMarkdown: String) {
        self.meta = meta
        self.bodyMarkdown = bodyMarkdown
    }

    public enum ParseError: Swift.Error, Sendable, Equatable {
        case missingFrontmatter
    }

    /// Inverse of `serialized()`. Port of the `_FRONTMATTER_RE` match in
    /// `treatment/schema.py::load`: a literal `---` line, YAML frontmatter,
    /// a literal `---` line, then the body verbatim.
    public static func parsing(_ raw: String) throws -> Treatment {
        guard raw.hasPrefix("---") else { throw ParseError.missingFrontmatter }
        // Split on the first two "---" lines rather than the Python DOTALL
        // regex — equivalent for well-formed input, and avoids requiring a
        // trailing newline after the raw string's very first line.
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { throw ParseError.missingFrontmatter }
        guard let closingIndex = lines.dropFirst().firstIndex(where: { $0 == "---" }) else {
            throw ParseError.missingFrontmatter
        }
        let frontmatterLines = lines[1..<closingIndex]
        let bodyLines = lines[(closingIndex + 1)...]
        let frontmatter = frontmatterLines.joined(separator: "\n")
        let body = bodyLines.joined(separator: "\n")
        let meta = try YAMLCoding.decode(TreatmentMeta.self, from: frontmatter)
        return Treatment(meta: meta, bodyMarkdown: body)
    }

    /// Inverse of `parsing(_:)`. Port of `treatment/schema.py::save`'s content
    /// assembly: `f"---\n{frontmatter}\n---\n{treatment.body_markdown}"`,
    /// where `frontmatter` is the YAML dump of meta, stripped of trailing
    /// whitespace.
    public func serialized() throws -> String {
        let frontmatter = try YAMLCoding.encode(meta).trimmingCharacters(in: .whitespacesAndNewlines)
        return "---\n\(frontmatter)\n---\n\(bodyMarkdown)"
    }
}

/// Disk I/O for the treatment version family, mirroring the free functions in
/// `treatment/schema.py`. Kept as a narrow set of static functions over
/// `PipelineLayout` paths rather than folded into `ArtifactStore`, since the
/// artifact is Markdown+frontmatter, not Codable-shaped YAML.
public enum TreatmentStore {
    /// Port of `treatment/schema.py::versions`.
    public static func versions(dataRoot: URL) -> [Int] {
        let dir = PipelineLayout.url(PipelineLayout.treatmentDir, in: dataRoot)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        var out: [Int] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("v"), name.hasSuffix(".md") else { continue }
            let middle = name.dropFirst().dropLast(3)
            if let n = Int(middle) { out.append(n) }
        }
        return out.sorted()
    }

    /// Port of `treatment/schema.py::next_version`.
    public static func nextVersion(dataRoot: URL) -> Int {
        (versions(dataRoot: dataRoot).last ?? 0) + 1
    }

    public enum LoadError: Swift.Error, Sendable, Equatable {
        case noTreatment(URL)
    }

    /// Port of `treatment/schema.py::load`. Loads the given `version`, or the
    /// latest if `nil`.
    public static func load(dataRoot: URL, version: Int? = nil) throws -> Treatment {
        let vs = versions(dataRoot: dataRoot)
        guard let latest = vs.last else {
            throw LoadError.noTreatment(PipelineLayout.url(PipelineLayout.treatmentDir, in: dataRoot))
        }
        let v = version ?? latest
        let url = PipelineLayout.url(PipelineLayout.treatmentVersionFile(v), in: dataRoot)
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try Treatment.parsing(raw)
    }

    /// Port of `treatment/schema.py::save`. Always writes both `vN.md` and
    /// `current.md`.
    @discardableResult
    public static func save(_ treatment: Treatment, to dataRoot: URL) throws -> URL {
        let content = try treatment.serialized()
        let versionURL = PipelineLayout.url(
            PipelineLayout.treatmentVersionFile(treatment.meta.version), in: dataRoot
        )
        try FileManager.default.createDirectory(
            at: versionURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: versionURL, atomically: true, encoding: .utf8)
        let currentURL = PipelineLayout.url(PipelineLayout.treatmentCurrentFile, in: dataRoot)
        try content.write(to: currentURL, atomically: true, encoding: .utf8)
        return versionURL
    }
}
