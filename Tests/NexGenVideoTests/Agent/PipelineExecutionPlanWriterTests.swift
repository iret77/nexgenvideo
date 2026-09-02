import Foundation
import Testing
@testable import NexGenEngine
@testable import NexGenVideo

@Suite("Pipeline execution plan writer")
struct PipelineExecutionPlanWriterTests {
    @Test("writer persists canonical bytes and revalidates exact referenced bytes")
    func canonicalWriteAndLineage() throws {
        let dataRoot = try makeDataRoot()
        defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }

        let briefData = Data("project: Fixture\n".utf8)
        let briefURL = PipelineLayout.url(PipelineLayout.briefFile, in: dataRoot)
        try briefData.write(to: briefURL, options: .atomic)

        let sourcePath = "import/source.mov"
        let sourceURL = PipelineLayout.url(sourcePath, in: dataRoot)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sourceData = Data("fixture-media-bytes".utf8)
        try sourceData.write(to: sourceURL, options: .atomic)

        let extensionPath = "execution/extensions/fixture/context.v1.json"
        let extensionURL = PipelineLayout.url(extensionPath, in: dataRoot)
        try FileManager.default.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let extensionData = Data("{\"kind\":\"fixture\"}".utf8)
        try extensionData.write(to: extensionURL, options: .atomic)

        let extensionReference = PackArtifactExtensionReferenceV1(
            id: "fixture.context",
            schema: "fixture-context/v1",
            path: extensionPath,
            sha256: FileDigest.sha256(of: extensionData)
        )
        let context = ProjectCreativeContextV1(
            projectID: "fixture-project",
            artifacts: [
                CanonicalArtifactReferenceV1(
                    id: "brief",
                    role: "core.brief",
                    path: PipelineLayout.briefFile,
                    sha256: FileDigest.sha256(of: briefData)
                ),
            ],
            media: [
                ProjectMediaReferenceV1(
                    id: "source-001",
                    role: "source.video",
                    path: sourcePath,
                    sha256: FileDigest.sha256(of: sourceData)
                ),
            ],
            extensions: [extensionReference]
        )
        let contextData = try ExecutionPlanCanonicalCodec.encode(context)
        let plan = ExecutionPlanV1(
            id: "plan-001",
            projectID: "fixture-project",
            creativeContext: CanonicalArtifactReferenceV1(
                id: ExecutionPlanV1.creativeContextArtifactID,
                role: ExecutionPlanV1.creativeContextArtifactRole,
                path: PipelineLayout.creativeContextFile,
                sha256: FileDigest.sha256(of: contextData)
            ),
            extensionReferences: [extensionReference],
            shots: [
                ExecutionShotV1(
                    id: "shot-001",
                    sourceMode: .imported,
                    sourceAssetID: "source-001",
                    startState: ExecutionStateV1(summary: "The source clip begins."),
                    endState: ExecutionStateV1(summary: "The source clip ends."),
                    primaryAction: "Use the selected source clip.",
                    camera: ExecutionCameraPlanV1(movementID: "core.source"),
                    renderability: .green,
                    acceptance: [
                        ExecutionAcceptanceCriterionV1(
                            id: "accept-001",
                            requirement: "The source clip remains intact.",
                            severity: "required"
                        ),
                    ]
                ),
            ]
        )

        let firstURL = try PipelineExecutionPlanWriter.write(
            plan: plan,
            context: context,
            dataRoot: dataRoot
        )
        let firstBytes = try Data(contentsOf: firstURL)
        let firstLineage = try PipelineExecutionPlanWriter.lineageSnapshot(dataRoot: dataRoot)
        _ = try PipelineExecutionPlanWriter.write(
            plan: plan,
            context: context,
            dataRoot: dataRoot
        )
        #expect(try Data(contentsOf: firstURL) == firstBytes)
        #expect(try PipelineExecutionPlanWriter.lineageSnapshot(dataRoot: dataRoot) == firstLineage)
        try PipelineExecutionPlanWriter.requireCurrent(dataRoot: dataRoot)

        let contextURL = PipelineLayout.url(PipelineLayout.creativeContextFile, in: dataRoot)
        var tornContextData = contextData
        tornContextData.append(0x20)
        try tornContextData.write(to: contextURL, options: .atomic)
        #expect(throws: (any Error).self) {
            try PipelineExecutionPlanWriter.requireCurrent(dataRoot: dataRoot)
        }
        try contextData.write(to: contextURL, options: .atomic)
        try PipelineExecutionPlanWriter.requireCurrent(dataRoot: dataRoot)

        try Data("different-media-bytes".utf8).write(to: sourceURL, options: .atomic)
        #expect(throws: (any Error).self) {
            try PipelineExecutionPlanWriter.requireCurrent(dataRoot: dataRoot)
        }
        try sourceData.write(to: sourceURL, options: .atomic)
        try PipelineExecutionPlanWriter.requireCurrent(dataRoot: dataRoot)

        try Data("project: Tampered\n".utf8).write(to: briefURL, options: .atomic)
        #expect(throws: (any Error).self) {
            try PipelineExecutionPlanWriter.requireCurrent(dataRoot: dataRoot)
        }
    }

    @Test("plan and creative context cannot belong to different projects")
    func projectMismatch() throws {
        let dataRoot = try makeDataRoot()
        defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }

        let context = ProjectCreativeContextV1(
            projectID: "context-project",
            artifacts: [],
            media: [
                ProjectMediaReferenceV1(
                    id: "source-001",
                    role: "source.video",
                    path: "import/source.mov",
                    sha256: String(repeating: "a", count: 64)
                ),
            ]
        )
        let contextData = try ExecutionPlanCanonicalCodec.encode(context)
        let plan = ExecutionPlanV1(
            id: "plan-001",
            projectID: "other-project",
            creativeContext: CanonicalArtifactReferenceV1(
                id: ExecutionPlanV1.creativeContextArtifactID,
                role: ExecutionPlanV1.creativeContextArtifactRole,
                path: PipelineLayout.creativeContextFile,
                sha256: FileDigest.sha256(of: contextData)
            ),
            shots: [importedShot()]
        )

        #expect(
            throws: ExecutionPlanValidationError.projectMismatch(
                plan: "other-project",
                context: "context-project"
            )
        ) {
            _ = try PipelineExecutionPlanWriter.write(
                plan: plan,
                context: context,
                dataRoot: dataRoot
            )
        }
    }

    @Test("plan project identity must match project.yaml")
    func projectMetadataBinding() throws {
        let dataRoot = try makeDataRoot(project: "project-on-disk")
        defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }

        let context = ProjectCreativeContextV1(
            projectID: "other-project",
            artifacts: [],
            media: [
                ProjectMediaReferenceV1(
                    id: "source-001",
                    role: "source.video",
                    path: "import/source.mov",
                    sha256: String(repeating: "a", count: 64)
                ),
            ]
        )
        let contextData = try ExecutionPlanCanonicalCodec.encode(context)
        let plan = ExecutionPlanV1(
            id: "plan-001",
            projectID: "other-project",
            creativeContext: CanonicalArtifactReferenceV1(
                id: ExecutionPlanV1.creativeContextArtifactID,
                role: ExecutionPlanV1.creativeContextArtifactRole,
                path: PipelineLayout.creativeContextFile,
                sha256: FileDigest.sha256(of: contextData)
            ),
            shots: [importedShot()]
        )

        #expect(
            throws: PipelineExecutionPlanError.projectMetadataMismatch(
                expected: "project-on-disk",
                actual: "other-project"
            )
        ) {
            _ = try PipelineExecutionPlanWriter.write(
                plan: plan,
                context: context,
                dataRoot: dataRoot
            )
        }
    }

    private func makeDataRoot(project: String = "fixture-project") throws -> URL {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let dataRoot = projectRoot.appendingPathComponent("pipeline")
        try FileManager.default.createDirectory(
            at: dataRoot,
            withIntermediateDirectories: true
        )
        try YAMLArtifactStore(dataRoot: dataRoot).save(
            ProjectMeta(project: project, mode: .generic),
            to: PipelineLayout.projectFile
        )
        return dataRoot
    }

    private func importedShot() -> ExecutionShotV1 {
        ExecutionShotV1(
            id: "shot-001",
            sourceMode: .imported,
            sourceAssetID: "source-001",
            startState: ExecutionStateV1(summary: "The source begins."),
            endState: ExecutionStateV1(summary: "The source ends."),
            primaryAction: "Use the selected source.",
            camera: ExecutionCameraPlanV1(movementID: "core.source"),
            renderability: .green,
            acceptance: [
                ExecutionAcceptanceCriterionV1(
                    id: "accept-001",
                    requirement: "The source remains intact.",
                    severity: "required"
                ),
            ]
        )
    }
}
