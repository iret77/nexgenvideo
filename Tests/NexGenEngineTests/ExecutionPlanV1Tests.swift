import Foundation
import Testing
@testable import NexGenEngine

@Suite("Format-neutral execution plan")
struct ExecutionPlanV1Tests {
    private let digest = String(repeating: "a", count: 64)

    @Test("a songless imported plan validates without provider fields")
    func importedPlan() throws {
        let plan = makePlan(
            shots: [
                ExecutionShotV1(
                    id: "shot-001",
                    sourceMode: .imported,
                    sourceAssetID: "asset-source-001",
                    startState: ExecutionStateV1(summary: "The actor waits at the doorway."),
                    endState: ExecutionStateV1(summary: "The actor has entered the room."),
                    primaryAction: "The actor enters the room.",
                    camera: ExecutionCameraPlanV1(movementID: "core.static"),
                    renderability: .green,
                    acceptance: [criterion()]
                ),
            ]
        )

        try ExecutionPlanValidator.validate(plan)
        let data = try ExecutionPlanCanonicalCodec.encode(plan)
        #expect(try ExecutionPlanCanonicalCodec.decodePlan(data) == plan)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.localizedCaseInsensitiveContains("song"))
        #expect(!text.localizedCaseInsensitiveContains("seedance"))
        #expect(!text.localizedCaseInsensitiveContains("provider"))
    }

    @Test("generated and enhanced shots declare requirements while imported shots do not")
    func sourceModeOwnership() throws {
        let requirement = GenerationRequirementV1(
            modalityID: "video",
            modeIDs: ["image-to-video"],
            visibleEntityCount: 1,
            sourceVideoAssetID: "source-video"
        )
        let enhanced = ExecutionShotV1(
            id: "shot-001",
            sourceMode: .aiEnhanced,
            sourceAssetID: "source-video",
            startState: ExecutionStateV1(summary: "Source starts."),
            endState: ExecutionStateV1(summary: "Source ends."),
            primaryAction: "Preserve the performance.",
            camera: ExecutionCameraPlanV1(movementID: "core.source"),
            renderability: .green,
            acceptance: [criterion()],
            generationRequirement: requirement
        )
        try ExecutionPlanValidator.validate(makePlan(shots: [enhanced]))

        let invalid = ExecutionShotV1(
            id: "shot-001",
            sourceMode: .imported,
            sourceAssetID: "source-video",
            startState: ExecutionStateV1(summary: "Source starts."),
            endState: ExecutionStateV1(summary: "Source ends."),
            primaryAction: "Use the source.",
            camera: ExecutionCameraPlanV1(movementID: "core.source"),
            renderability: .green,
            acceptance: [criterion()],
            generationRequirement: requirement
        )
        #expect(throws: ExecutionPlanValidationError.invalidSourceBinding(shotID: "shot-001")) {
            try ExecutionPlanValidator.validate(makePlan(shots: [invalid]))
        }
    }

    @Test("only the explicit shotlist-v4 adapter creates a readable legacy projection")
    func legacyIncomplete() throws {
        let shot = try Shot(
            id: "s001",
            section: "scene",
            timeStart: 0,
            timeEnd: 4,
            durationS: 4,
            type: .performance,
            sourceMode: .imported,
            description: "The source performance continues.",
            visualPrompt: "Preserve the source.",
            mood: "restrained",
            sourcePath: "import/source.mov"
        )
        let song = try Song(
            title: "Fixture",
            audioPath: "audio/track.wav",
            analysisPath: "analysis/analysis.json",
            bpm: 120,
            durationS: 4
        )
        let shotlist = try Shotlist(
            schema_: shotlistSchemaVersion,
            mode: .section,
            project: "project-001",
            song: song,
            generated: "2026-08-31",
            generator: "legacy-fixture",
            shots: [shot]
        )
        let context = ProjectCreativeContextV1(
            projectID: "project-001",
            artifacts: [],
            media: [
                ProjectMediaReferenceV1(
                    id: "source-001",
                    role: "source.video",
                    path: "import/source.mov",
                    sha256: digest
                ),
            ]
        )
        let plan = try ShotlistV4ExecutionPlanAdapter.project(
            shotlist,
            planID: "legacy-projection",
            context: context
        )

        #expect(plan.completeness == .legacyIncomplete)
        #expect(!plan.incompleteReasons.isEmpty)
        #expect(plan.shots.map(\.sourceMode) == [.imported])
        #expect(plan.shots.map(\.sourceAssetID) == ["source-001" as String?])
        let data = try ExecutionPlanCanonicalCodec.encode(plan)
        #expect(throws: ExecutionPlanValidationError.planIncomplete(plan.incompleteReasons)) {
            _ = try ExecutionPlanCanonicalCodec.decodePlan(data)
        }
    }

    @Test("execution-plan source modes reject the legacy live_action alias")
    func sourceModeIsClosed() throws {
        let plan = makePlan(
            shots: [
                ExecutionShotV1(
                    id: "shot-001",
                    sourceMode: .imported,
                    sourceAssetID: "source-001",
                    startState: ExecutionStateV1(summary: "The source begins."),
                    endState: ExecutionStateV1(summary: "The source ends."),
                    primaryAction: "Use the selected source.",
                    camera: ExecutionCameraPlanV1(movementID: "core.source"),
                    renderability: .green,
                    acceptance: [criterion()]
                ),
            ]
        )
        let encoded = String(
            decoding: try ExecutionPlanCanonicalCodec.encode(plan),
            as: UTF8.self
        )
        let legacyAlias = encoded.replacingOccurrences(
            of: #""source_mode":"imported""#,
            with: #""source_mode":"live_action""#
        )
        #expect(legacyAlias != encoded)
        #expect(throws: (any Error).self) {
            _ = try ExecutionPlanCanonicalCodec.decodePlan(Data(legacyAlias.utf8))
        }
    }

    @Test("unknown schemas fail closed")
    func futureSchema() {
        let plan = ExecutionPlanV1(
            schema: "execution-plan/v99",
            id: "plan-001",
            projectID: "project-001",
            creativeContext: CanonicalArtifactReferenceV1(
                id: ExecutionPlanV1.creativeContextArtifactID,
                role: ExecutionPlanV1.creativeContextArtifactRole,
                path: "execution/creative-context.v1.json",
                sha256: digest
            ),
            shots: []
        )

        #expect(throws: ExecutionPlanValidationError.unsupportedSchema("execution-plan/v99")) {
            try ExecutionPlanValidator.validate(plan)
        }
    }

    @Test("canonical encoding is deterministic")
    func canonicalEncoding() throws {
        let plan = makePlan(shots: [])
        #expect(
            try ExecutionPlanCanonicalCodec.encode(plan)
                == ExecutionPlanCanonicalCodec.encode(plan)
        )
    }

    @Test("execution references must resolve to media bound by the creative context")
    func contextualMediaReferences() throws {
        let shot = ExecutionShotV1(
            id: "shot-001",
            sourceMode: .imported,
            sourceAssetID: "source-001",
            startState: ExecutionStateV1(summary: "The source begins."),
            endState: ExecutionStateV1(summary: "The source ends."),
            primaryAction: "Use the selected source.",
            camera: ExecutionCameraPlanV1(movementID: "core.source"),
            renderability: .green,
            acceptance: [criterion()]
        )
        let matching = ProjectCreativeContextV1(
            projectID: "project-001",
            artifacts: [],
            media: [
                ProjectMediaReferenceV1(
                    id: "source-001",
                    role: "source.video",
                    path: "import/source.mov",
                    sha256: digest
                ),
            ]
        )
        let plan = makePlan(
            shots: [shot],
            contextSHA256: FileDigest.sha256(
                of: try ExecutionPlanCanonicalCodec.encode(matching)
            )
        )
        try ExecutionPlanValidator.validate(plan, against: matching)

        let missing = ProjectCreativeContextV1(projectID: "project-001", artifacts: [])
        let missingPlan = makePlan(
            shots: [shot],
            contextSHA256: FileDigest.sha256(
                of: try ExecutionPlanCanonicalCodec.encode(missing)
            )
        )
        #expect(
            throws: ExecutionPlanValidationError.unknownMediaReference(
                shotID: "shot-001",
                assetID: "source-001"
            )
        ) {
            try ExecutionPlanValidator.validate(missingPlan, against: missing)
        }
    }

    @Test("reference demands resolve to exact media in the creative context")
    func referenceDemandBinding() throws {
        let requirement = GenerationRequirementV1(
            modalityID: "video",
            modeIDs: ["reference-to-video"],
            visibleEntityCount: 1,
            referenceDemandIDs: ["look-reference-001"]
        )
        let shot = ExecutionShotV1(
            id: "shot-001",
            sourceMode: .generated,
            startState: ExecutionStateV1(summary: "The generated shot begins."),
            endState: ExecutionStateV1(summary: "The generated shot ends."),
            primaryAction: "The performer turns toward camera.",
            camera: ExecutionCameraPlanV1(movementID: "core.static"),
            renderability: .green,
            acceptance: [criterion()],
            generationRequirement: requirement
        )
        let matching = ProjectCreativeContextV1(
            projectID: "project-001",
            artifacts: [],
            media: [
                ProjectMediaReferenceV1(
                    id: "look-reference-001",
                    role: "reference.look",
                    path: "import/look.png",
                    sha256: digest
                ),
            ]
        )
        let plan = makePlan(
            shots: [shot],
            contextSHA256: FileDigest.sha256(
                of: try ExecutionPlanCanonicalCodec.encode(matching)
            )
        )
        try ExecutionPlanValidator.validate(plan, against: matching)

        let missing = ProjectCreativeContextV1(projectID: "project-001", artifacts: [])
        let missingPlan = makePlan(
            shots: [shot],
            contextSHA256: FileDigest.sha256(
                of: try ExecutionPlanCanonicalCodec.encode(missing)
            )
        )
        #expect(
            throws: ExecutionPlanValidationError.unknownMediaReference(
                shotID: "shot-001",
                assetID: "look-reference-001"
            )
        ) {
            try ExecutionPlanValidator.validate(missingPlan, against: missing)
        }
    }

    @Test("context inputs cannot name writer outputs or unconstrained pack extensions")
    func referencePathConstraints() {
        let outputAsInput = ProjectCreativeContextV1(
            projectID: "project-001",
            artifacts: [
                CanonicalArtifactReferenceV1(
                    id: "self",
                    role: "invalid.self",
                    path: PipelineLayout.executionPlanFile,
                    sha256: digest
                ),
            ]
        )
        #expect(
            throws: ExecutionPlanValidationError.forbiddenOutputReference(
                PipelineLayout.executionPlanFile
            )
        ) {
            try ExecutionPlanValidator.validate(outputAsInput)
        }

        let invalidSchema = ProjectCreativeContextV1(
            projectID: "project-001",
            artifacts: [],
            extensions: [
                PackArtifactExtensionReferenceV1(
                    id: "fixture.context",
                    schema: "Fixture Context",
                    path: "execution/extensions/fixture/context.json",
                    sha256: digest
                ),
            ]
        )
        #expect(
            throws: ExecutionPlanValidationError.invalidExtensionSchema("Fixture Context")
        ) {
            try ExecutionPlanValidator.validate(invalidSchema)
        }

        let escapedExtension = ProjectCreativeContextV1(
            projectID: "project-001",
            artifacts: [],
            extensions: [
                PackArtifactExtensionReferenceV1(
                    id: "fixture.context",
                    schema: "fixture-context/v1",
                    path: "import/context.json",
                    sha256: digest
                ),
            ]
        )
        #expect(
            throws: ExecutionPlanValidationError.invalidReferencePath("import/context.json")
        ) {
            try ExecutionPlanValidator.validate(escapedExtension)
        }
    }

    @Test("project-local references reject leaf and intermediate symbolic links")
    func rejectsSymbolicLinks() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let dataRoot = projectRoot.appendingPathComponent("pipeline")
        let realDirectory = projectRoot.appendingPathComponent("real-media")
        try FileManager.default.createDirectory(
            at: dataRoot.appendingPathComponent("import"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        let realFile = realDirectory.appendingPathComponent("source.mov")
        try Data("fixture".utf8).write(to: realFile)
        let leafLink = dataRoot.appendingPathComponent("import/leaf.mov")
        try FileManager.default.createSymbolicLink(
            at: leafLink,
            withDestinationURL: realFile
        )
        #expect(
            throws: ProjectLocalFileError.symbolicLink("import/leaf.mov")
        ) {
            _ = try ProjectLocalFile.resolve("import/leaf.mov", dataRoot: dataRoot)
        }

        try FileManager.default.removeItem(at: dataRoot.appendingPathComponent("import"))
        try FileManager.default.createSymbolicLink(
            at: dataRoot.appendingPathComponent("import"),
            withDestinationURL: realDirectory
        )
        #expect(
            throws: ProjectLocalFileError.symbolicLink("import/source.mov")
        ) {
            _ = try ProjectLocalFile.resolve("import/source.mov", dataRoot: dataRoot)
        }
    }

    private func makePlan(
        shots: [ExecutionShotV1],
        contextSHA256: String? = nil
    ) -> ExecutionPlanV1 {
        ExecutionPlanV1(
            id: "plan-001",
            projectID: "project-001",
            creativeContext: CanonicalArtifactReferenceV1(
                id: ExecutionPlanV1.creativeContextArtifactID,
                role: ExecutionPlanV1.creativeContextArtifactRole,
                path: "execution/creative-context.v1.json",
                sha256: contextSHA256 ?? digest
            ),
            shots: shots
        )
    }

    private func criterion() -> ExecutionAcceptanceCriterionV1 {
        ExecutionAcceptanceCriterionV1(
            id: "accept-001",
            requirement: "The intended action remains legible.",
            severity: "required"
        )
    }
}
