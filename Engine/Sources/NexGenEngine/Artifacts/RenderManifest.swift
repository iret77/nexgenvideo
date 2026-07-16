import Foundation

/// Per-shot render/frame manifest — the generic, format-neutral ledger of
/// which shots have been rendered, where their outputs live, and what they
/// cost. Persisted at `renders/manifest-<phase>.json`. Port of
/// `render/manifest.py`.
public let renderManifestSchemaVersion = "render_manifest/v1"

/// Port of `render/manifest.py::RenderStatus` (`Literal["pending", "rendered", "failed"]`).
public enum RenderStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case rendered
    case failed
}

/// In-memory / clean form. Port of `render/manifest.py::RenderEntry`.
public struct RenderEntry: Codable, Sendable, Equatable {
    public var shotId: String
    public var phase: String
    public var status: RenderStatus
    /// Local path or remote URL of the rendered artifact, or nil if not done.
    public var output: String?
    public var costEur: Double
    public var updatedAt: String?
    /// The rendered clip's extracted last frame, project-root-relative — set when the NEXT shot chains
    /// off this one (`chain_with_previous_end`). Feeds the successor's start-frame condition (#196).
    /// Port of `RenderResult.last_frame_path`.
    public var lastFramePath: String?
    /// What this render was ACTUALLY conditioned on, stamped by `record_render` from the submitted
    /// generation input — the audit counterpart to what `next_render_shot` planned. `plan_adherence`
    /// compares the two (#231). Nil on manifests written before the fields existed.
    public var startFramePath: String?
    public var referencePaths: [String]?

    public init(
        shotId: String, phase: String, status: RenderStatus = .pending, output: String? = nil,
        costEur: Double = 0.0, updatedAt: String? = nil, lastFramePath: String? = nil,
        startFramePath: String? = nil, referencePaths: [String]? = nil
    ) {
        self.shotId = shotId
        self.phase = phase
        self.status = status
        self.output = output
        self.costEur = costEur
        self.updatedAt = updatedAt
        self.lastFramePath = lastFramePath
        self.startFramePath = startFramePath
        self.referencePaths = referencePaths
    }
}

/// In-memory / clean form. Port of `render/manifest.py::RenderManifest`.
///
/// On disk, this is NOT a 1:1 `Codable` mapping: the wire format is a legacy
/// monolith shape (`_to_disk`/`_from_disk`) kept for continuity with existing
/// readers (`render.costs.already_spent_in_project`, `show.formatters.show_renders`).
/// Custom `init(from:)`/`encode(to:)` below reproduce that shape exactly.
public struct RenderManifest: Sendable, Equatable {
    public var project: String
    public var phase: String
    public var schema_: String
    public var entries: [String: RenderEntry]

    public init(
        project: String, phase: String, schema_: String = renderManifestSchemaVersion,
        entries: [String: RenderEntry] = [:]
    ) {
        self.project = project
        self.phase = phase
        self.schema_ = schema_
        self.entries = entries
    }
}

extension RenderManifest: Codable {
    private enum TopLevelKeys: String, CodingKey {
        case project
        case phase
        case schema
        case shots
        case results
    }

    /// One flat row in the `shots`/`results` arrays: canonical keys plus the
    /// legacy mirror keys (`eur_spent` == `cost_eur`, `out_path` == `output`).
    /// Modeled with `String`/`Bool`/etc. optionals rather than a keyed
    /// container walk, so a malformed row (wrong JSON type, missing
    /// `shot_id`) can be detected and skipped rather than aborting the whole
    /// decode — mirroring `_from_disk`'s `dict.get`-based tolerance exactly.
    /// `status` is decoded as a raw `String?`, not `RenderStatus?`: pydantic's
    /// `RenderEntry` still validates the `Literal` status field even inside
    /// the tolerant `_from_disk` loop, so an unrecognized status value must
    /// propagate as a decode error (not be silently dropped like a
    /// non-dict/missing-shot_id row is).
    private struct Row: Decodable {
        let shotId: String?
        let phase: String?
        let status: String?
        let output: String?
        let outPath: String?
        let costEur: Double?
        let eurSpent: Double?
        let updatedAt: String?
        let lastFramePath: String?
        let startFramePath: String?
        let referencePaths: [String]?

        enum CodingKeys: String, CodingKey {
            case shotId = "shot_id"
            case phase
            case status
            case output
            case outPath = "out_path"
            case costEur = "cost_eur"
            case eurSpent = "eur_spent"
            case updatedAt = "updated_at"
            case lastFramePath = "last_frame_path"
            case startFramePath = "start_frame_path"
            case referencePaths = "reference_paths"
        }
    }

    private struct RowOut: Encodable {
        let shotId: String
        let phase: String
        let status: RenderStatus
        let output: String?
        let costEur: Double
        let updatedAt: String?
        let eurSpent: Double
        let outPath: String?
        let lastFramePath: String?
        let startFramePath: String?
        let referencePaths: [String]?

        enum CodingKeys: String, CodingKey {
            case shotId = "shot_id"
            case phase
            case status
            case output
            case costEur = "cost_eur"
            case updatedAt = "updated_at"
            case eurSpent = "eur_spent"
            case outPath = "out_path"
            case lastFramePath = "last_frame_path"
            case startFramePath = "start_frame_path"
            case referencePaths = "reference_paths"
        }
    }

    /// Port of `_from_disk`. Rows that aren't objects, or whose `shot_id`
    /// isn't a string, are skipped entirely. A row with an unrecognized
    /// `status` value still propagates as a decode error, matching pydantic's
    /// `Literal` validation on `RenderEntry.status`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TopLevelKeys.self)
        project = try container.decodeIfPresent(String.self, forKey: .project) ?? ""
        phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? ""
        schema_ = try container.decodeIfPresent(String.self, forKey: .schema) ?? renderManifestSchemaVersion

        // Rows that fail to decode as `Row` at all (e.g. a JSON string/number
        // instead of an object) are skipped via `decodeIfPresent`'s per-element
        // tolerance below — `[Row?]` lets each element fail independently.
        var rawRows = try container.decodeIfPresent([FailableRow].self, forKey: .shots)
        if rawRows == nil {
            rawRows = try container.decodeIfPresent([FailableRow].self, forKey: .results)
        }

        var entries: [String: RenderEntry] = [:]
        for failable in rawRows ?? [] {
            guard let row = failable.row, let shotId = row.shotId else { continue }
            let status: RenderStatus
            if let rawStatus = row.status {
                guard let parsed = RenderStatus(rawValue: rawStatus) else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: container.codingPath + [TopLevelKeys.shots],
                            debugDescription: "unrecognized render status \(rawStatus.debugDescription) for shot \(shotId)"
                        )
                    )
                }
                status = parsed
            } else {
                status = .pending
            }
            let cost = row.costEur ?? row.eurSpent ?? 0.0
            let output = row.output ?? row.outPath
            entries[shotId] = RenderEntry(
                shotId: shotId,
                phase: row.phase ?? phase,
                status: status,
                output: output,
                costEur: cost,
                updatedAt: row.updatedAt,
                lastFramePath: row.lastFramePath,
                startFramePath: row.startFramePath,
                referencePaths: row.referencePaths
            )
        }
        self.entries = entries
    }

    /// Decodes one array element tolerantly: if the element isn't a `Row`
    /// shape at all (e.g. a bare string/number), `row` is nil rather than
    /// failing the whole array decode.
    private struct FailableRow: Decodable {
        let row: Row?
        init(from decoder: Decoder) throws {
            row = try? Row(from: decoder)
        }
    }

    /// Port of `_to_disk`. Writes both `shots` and `results` (mirror of `shots`,
    /// legacy formatter compat) with dual-mirror-key rows.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TopLevelKeys.self)
        try container.encode(project, forKey: .project)
        try container.encode(phase, forKey: .phase)
        try container.encode(schema_, forKey: .schema)

        let rows = entries.values.map { entry in
            RowOut(
                shotId: entry.shotId, phase: entry.phase, status: entry.status, output: entry.output,
                costEur: entry.costEur, updatedAt: entry.updatedAt, eurSpent: entry.costEur,
                outPath: entry.output, lastFramePath: entry.lastFramePath,
                startFramePath: entry.startFramePath, referencePaths: entry.referencePaths
            )
        }
        try container.encode(rows, forKey: .shots)
        try container.encode(rows, forKey: .results)
    }
}

/// Port of `render/manifest.py::next_unrendered`. First shot ID (in the given
/// order) whose entry is missing or not `.rendered`.
public func nextUnrendered(orderedShotIds: [String], manifest: RenderManifest) -> String? {
    for shotId in orderedShotIds {
        let entry = manifest.entries[shotId]
        if entry == nil || entry?.status != .rendered { return shotId }
    }
    return nil
}

/// Port of `render/manifest.py::record`. Upserts the entry for `shotId`;
/// `updatedAt` defaults to `now()` when nil. Python's `_now()` here uses the
/// same `timespec="seconds"` + `+00:00`-suffix shape as Gates.swift's
/// `currentTimestamp()`, so it's reused rather than duplicated (unlike the
/// Ledger's differently-formatted `_now()`).
public func record(
    _ manifest: inout RenderManifest, shotId: String, output: String?, costEur: Double,
    status: RenderStatus = .rendered, phase: String, updatedAt: String? = nil,
    lastFramePath: String? = nil, now: () -> String = currentTimestamp
) {
    manifest.entries[shotId] = RenderEntry(
        shotId: shotId, phase: phase, status: status, output: output, costEur: costEur,
        updatedAt: updatedAt ?? now(), lastFramePath: lastFramePath
    )
}

/// Port of `render/manifest.py::spent`. Sum of all entries' `costEur`,
/// rounded to 2 decimal places.
public func spent(_ manifest: RenderManifest) -> Double {
    let total = manifest.entries.values.reduce(0.0) { $0 + $1.costEur }
    return (total * 100).rounded() / 100
}

/// Port of `render/manifest.py::summary`.
public struct RenderSummary: Sendable, Equatable {
    public let total: Int
    public let rendered: Int
    public let pending: Int
    public let failed: Int
    public let spentEur: Double
}

public func summary(orderedShotIds: [String], manifest: RenderManifest) -> RenderSummary {
    var rendered = 0, failed = 0, pending = 0
    for shotId in orderedShotIds {
        switch manifest.entries[shotId]?.status {
        case .none: pending += 1
        case .rendered: rendered += 1
        case .failed: failed += 1
        case .pending: pending += 1
        }
    }
    return RenderSummary(
        total: orderedShotIds.count, rendered: rendered, pending: pending, failed: failed,
        spentEur: spent(manifest)
    )
}

/// Port of `render/manifest.py::load`. Returns an empty manifest (not
/// throwing) if the file doesn't exist — `project` defaults to
/// `dataRoot.lastPathComponent`, faithfully mirroring the Python quirk
/// (`project_dir.name`) even though real v2 data roots are named `pipeline`.
public func loadRenderManifest(dataRoot: URL, phase: String) throws -> RenderManifest {
    let relativePath = PipelineLayout.renderManifestFile(phase: phase)
    let url = PipelineLayout.url(relativePath, in: dataRoot)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return RenderManifest(project: dataRoot.lastPathComponent, phase: phase)
    }
    return try JSONArtifactStore(dataRoot: dataRoot).load(RenderManifest.self, at: relativePath)
}

/// Port of `render/manifest.py::save`.
public func saveRenderManifest(_ manifest: RenderManifest, dataRoot: URL) throws {
    let relativePath = PipelineLayout.renderManifestFile(phase: manifest.phase)
    try JSONArtifactStore(dataRoot: dataRoot).save(manifest, to: relativePath)
}
