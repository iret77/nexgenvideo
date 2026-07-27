import Foundation

public let pipelineLineageSchemaVersion = "pipeline_lineage/v1"

public struct PhaseLineageSnapshot: Sendable, Equatable {
    public let inputFingerprint: String
    public let artifactFingerprint: String

    public init(inputFingerprint: String, artifactFingerprint: String) {
        self.inputFingerprint = inputFingerprint
        self.artifactFingerprint = artifactFingerprint
    }
}

public struct PhaseLineageEntry: Codable, Sendable, Equatable {
    public let inputFingerprint: String
    public let artifactFingerprint: String
    public let recordedAt: String

    private enum CodingKeys: String, CodingKey {
        case inputFingerprint = "input_fingerprint"
        case artifactFingerprint = "artifact_fingerprint"
        case recordedAt = "recorded_at"
    }

    public init(snapshot: PhaseLineageSnapshot, recordedAt: String) {
        inputFingerprint = snapshot.inputFingerprint
        artifactFingerprint = snapshot.artifactFingerprint
        self.recordedAt = recordedAt
    }

    public var snapshot: PhaseLineageSnapshot {
        PhaseLineageSnapshot(
            inputFingerprint: inputFingerprint,
            artifactFingerprint: artifactFingerprint
        )
    }
}

public struct PipelineLineage: Codable, Sendable, Equatable {
    public let schema: String
    public let project: String
    public var phases: [String: PhaseLineageEntry]

    public init(
        schema: String = pipelineLineageSchemaVersion,
        project: String,
        phases: [String: PhaseLineageEntry] = [:]
    ) {
        self.schema = schema
        self.project = project
        self.phases = phases
    }
}

public enum PipelineLineageStore {
    public static func record(
        phase: String,
        snapshot: PhaseLineageSnapshot,
        dataRoot: URL,
        now: () -> String = currentTimestamp
    ) throws {
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(
            ProjectMeta.self,
            at: PipelineLayout.projectFile
        )
        var lineage = try loadIfPresent(dataRoot: dataRoot)
            ?? PipelineLineage(project: project.project)
        guard lineage.schema == pipelineLineageSchemaVersion,
              lineage.project == project.project else {
            throw GateBlocked(
                "Pipeline lineage belongs to a different project or schema."
            )
        }
        lineage.phases[phase] = PhaseLineageEntry(
            snapshot: snapshot,
            recordedAt: now()
        )
        try JSONArtifactStore(dataRoot: dataRoot).save(
            lineage,
            to: PipelineLayout.lineageFile
        )
    }

    public static func requireCurrent(
        phase: String,
        snapshot: PhaseLineageSnapshot,
        dataRoot: URL
    ) throws {
        guard let lineage = try loadIfPresent(dataRoot: dataRoot),
              lineage.schema == pipelineLineageSchemaVersion,
              let entry = lineage.phases[phase] else {
            throw GateBlocked(
                "Can't approve \"\(phase)\": its artifact has no verified input lineage. "
                    + "Rebuild it through the phase's schema-validated tools."
            )
        }
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(
            ProjectMeta.self,
            at: PipelineLayout.projectFile
        )
        guard lineage.project == project.project else {
            throw GateBlocked(
                "Can't approve \"\(phase)\": its input lineage belongs to another project."
            )
        }
        guard entry.inputFingerprint == snapshot.inputFingerprint else {
            throw GateBlocked(
                "Can't approve \"\(phase)\": an upstream input changed after this artifact "
                    + "was written. Rebuild the phase from the current pipeline state."
            )
        }
        guard entry.artifactFingerprint == snapshot.artifactFingerprint else {
            throw GateBlocked(
                "Can't approve \"\(phase)\": its persisted artifact changed outside the "
                    + "schema-validated phase writer. Rebuild the phase."
            )
        }
    }

    public static func loadIfPresent(dataRoot: URL) throws -> PipelineLineage? {
        let url = PipelineLayout.url(PipelineLayout.lineageFile, in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONArtifactStore(dataRoot: dataRoot).load(
            PipelineLineage.self,
            at: PipelineLayout.lineageFile
        )
    }
}
