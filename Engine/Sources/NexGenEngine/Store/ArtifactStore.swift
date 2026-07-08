import Foundation

/// The canonical relative paths inside a data root, mirroring the Python
/// engine's save locations and `core/layout.py::CORE_SUBDIRS`. Values are
/// relative to the data root (the `_studio` directory in the v2 layout).
///
/// Verified against the Python schema `save` functions:
/// - `core/project.py`  → `project.yaml`
/// - `core/gates.py`    → `gates.yaml`
/// - `brief/schema.py`  → `brief.yaml`
/// - `ledger/schema.py` → `ledger.yaml`
/// - `bible/schema.py`  → `bible/bible.yaml`
/// - `treatment/schema.py` → `treatment/vN.md` (+ `current.md`)
/// - `storyboard/schema.py` → `storyboard/vN.yaml` (+ `current.yaml`)
/// - `shotlist/schema.py` → `shotlist/vN.yaml`
public enum StudioLayout {
    // MARK: Single-file artifacts (relative to the data root)

    public static let projectFile = "project.yaml"
    public static let gatesFile = "gates.yaml"
    public static let briefFile = "brief.yaml"
    public static let ledgerFile = "ledger.yaml"
    public static let bibleFile = "bible/bible.yaml"

    // MARK: Directories (relative to the data root)

    public static let bibleDir = "bible"
    public static let treatmentDir = "treatment"
    public static let storyboardDir = "storyboard"
    public static let shotlistDir = "shotlist"
    public static let framesDir = "frames"
    public static let rendersDir = "renders"

    /// Format-neutral data-root subdirs created at init — exact order and names
    /// from `core/layout.py::CORE_SUBDIRS`. Pack dirs come separately.
    public static let coreSubdirs: [String] = [
        "production_design/refs",
        "treatment",
        "storyboard",
        "bible",
        "shotlist",
        "frames",
        "renders",
        "import",
        "import/characters",
        "import/locations",
    ]

    /// User-facing zone dirs, siblings of `_studio` — `core/layout.py::USER_DIRS`.
    public static let userDirs: [String] = ["inbox", "review", "final"]

    /// Absolute URL of a layout entry within a data root.
    public static func url(_ relative: String, in dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(relative)
    }

    // MARK: Versioned families (treatment/storyboard/shotlist)

    /// `treatment/vN.md` — treatment.py's `_treatment_dir(...) / f"v{n}.md"`.
    public static func treatmentVersionFile(_ version: Int) -> String {
        "\(treatmentDir)/v\(version).md"
    }

    public static let treatmentCurrentFile = "treatment/current.md"

    /// `storyboard/vN.yaml` — storyboard.py's `_dir(...) / f"v{n}.yaml"`.
    public static func storyboardVersionFile(_ version: Int) -> String {
        "\(storyboardDir)/v\(version).yaml"
    }

    public static let storyboardCurrentFile = "storyboard/current.yaml"

    /// `shotlist/vN.yaml` — shotlist.py's `shotlist_path(...)`. Shotlist has
    /// no `current.yaml` mirror; the highest version wins on load.
    public static func shotlistVersionFile(_ version: Int) -> String {
        "\(shotlistDir)/v\(version).yaml"
    }

    /// `renders/manifest-<phase>.json` — render/manifest.py's `manifest_path`.
    public static func renderManifestFile(phase: String) -> String {
        "\(rendersDir)/manifest-\(phase).json"
    }
}

/// Loads and saves engine artifacts of a given `Codable` type by their
/// canonical location under a data root. Concrete artifact types land in M1;
/// this is the seam the store and its tests build on.
public protocol ArtifactStore: Sendable {
    /// The data root all artifact paths are resolved against.
    var dataRoot: URL { get }

    /// Decode an artifact from `relativePath` under the data root.
    func load<Artifact: Decodable>(_ type: Artifact.Type, at relativePath: String) throws -> Artifact

    /// Encode `artifact` to `relativePath` under the data root.
    func save<Artifact: Encodable>(_ artifact: Artifact, to relativePath: String) throws
}

/// A YAML-backed `ArtifactStore` over a data root on disk. Pure I/O + YAML —
/// no schema knowledge yet (that arrives with the M1 artifact types).
public struct YAMLArtifactStore: ArtifactStore {
    public let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    public func load<Artifact: Decodable>(_ type: Artifact.Type, at relativePath: String) throws -> Artifact {
        let url = StudioLayout.url(relativePath, in: dataRoot)
        return try YAMLCoding.decode(type, from: url)
    }

    public func save<Artifact: Encodable>(_ artifact: Artifact, to relativePath: String) throws {
        let url = StudioLayout.url(relativePath, in: dataRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let yaml = try YAMLCoding.encode(artifact)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A JSON-backed `ArtifactStore` over a data root on disk, for the one
/// artifact family the Python engine persists as JSON (`render/manifest.py`)
/// rather than YAML.
public struct JSONArtifactStore: ArtifactStore {
    public let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    public func load<Artifact: Decodable>(_ type: Artifact.Type, at relativePath: String) throws -> Artifact {
        let url = StudioLayout.url(relativePath, in: dataRoot)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    public func save<Artifact: Encodable>(_ artifact: Artifact, to relativePath: String) throws {
        let url = StudioLayout.url(relativePath, in: dataRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(artifact)
        try data.write(to: url, options: .atomic)
    }
}
