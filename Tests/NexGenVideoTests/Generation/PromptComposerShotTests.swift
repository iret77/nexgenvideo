import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo
@testable import MusicvideoPlugin

/// PromptComposer per-shot compile: deterministic camera/framing projection + compliance drift linter
/// on the running compile path (#197). Ports the camera/composition projection of
/// `frames/generate.py::_payload_from_shot` + the per-frame `lint_prompt_against_shot` call.
@Suite("prompt compose: shot projection + drift (#197)")
@MainActor
struct PromptComposerShotTests {
    static func shot(
        height: CameraHeight,
        framing: Framing,
        productionPlan: ShotProductionPlan? = nil,
        characterBlocking: [CharacterBlocking] = []
    ) throws -> Shot {
        try Shot(id: "s001", section: "verse", timeStart: 0, timeEnd: 4, durationS: 4,
                 type: .performance, description: "d", visualPrompt: "p", mood: "m",
                 characterRefs: characterBlocking.map(\.characterRef),
                 keyframeStrategy: .start, framing: framing,
                 cameraSetup: CameraSetup(height: height, angle: .frontal),
                 characterBlocking: characterBlocking,
                 productionPlan: productionPlan)
    }

    private static func project(
        shots: [Shot],
        ledger: Ledger,
        brief: Brief? = nil,
        musicvideo: Bool = false
    ) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-compiler-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = try ProjectScaffold.initProject(
            home: home,
            name: "prompt-test",
            mode: .section
        )
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        try store.save(ledger, to: PipelineLayout.ledgerFile)
        if let brief {
            try store.save(brief, to: PipelineLayout.briefFile)
        }
        let duration = shots.map(\.timeEnd).max() ?? 4
        let song = try Song(
            title: "Prompt test",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: duration
        )
        _ = try saveShotlist(
            Shotlist(
                schema_: shotlistSchemaVersion,
                mode: .section,
                project: "prompt-test",
                song: song,
                generated: "2026-09-09",
                generator: "test",
                shots: shots
            ),
            to: dataRoot
        )
        try Fixtures.prepareProjectPackage(at: home)
        if musicvideo {
            let pack = MusicvideoPack()
            PackCatalog.register(pack)
            let binding = try #require(ProjectPackBinding(
                id: pack.name,
                version: pack.version,
                projectSchema: "musicvideo/2.0.0"
            ))
            try ProjectPluginSettings.setActivePlugin(binding, projectURL: home)
        }
        return home
    }

    private static func removeProject(_ project: URL, editor: EditorViewModel) {
        editor.releaseWorkingCopy()
        if let key = ProjectIdentity.existingKey(for: project) {
            ProjectWorkingCopy.discard(key: key)
        }
        try? FileManager.default.removeItem(at: project)
    }

    @Test("shot camera + framing are projected into the compiled prompt from the spec")
    func projectsCamera() async throws {
        let shot = try Self.shot(height: .high, framing: .wide)
        let c = try await PromptComposer.compose(
            intent: "a lone figure stands at the edge of a rooftop overlooking the city",
            modality: .video, modelId: "fal/seedance-2.0", projectDir: nil,
            shot: PromptComposer.ShotProjection(shot))
        #expect(c.text.contains("high camera height"))
        #expect(c.text.contains("wide framing"))
    }

    @Test("drift linter fires in compose when the prompt contradicts the shot's camera height")
    func driftFires() async throws {
        let shot = try Self.shot(height: .eyeLevel, framing: .ms)
        let c = try await PromptComposer.compose(
            intent: "a lone figure on a rooftop, aerial view of the rooftop far below",
            modality: .video, modelId: "fal/seedance-2.0", projectDir: nil,
            shot: PromptComposer.ShotProjection(shot))
        #expect(c.notes.contains { $0.contains("CAMERA_HEIGHT_MISMATCH") })
    }

    @Test("without a shot, no camera is injected and no drift note is raised")
    func noShotNoProjection() async throws {
        let c = try await PromptComposer.compose(
            intent: "a lone figure on a rooftop, aerial view of the rooftop far below",
            modality: .video, modelId: "fal/seedance-2.0", projectDir: nil)
        #expect(!c.notes.contains { $0.contains("CAMERA_HEIGHT_MISMATCH") })
    }

    @Test("production plan projects motion only into video and continuity into both modalities")
    func projectsProductionPlan() async throws {
        let plan = try ShotProductionPlan(
            primaryAction: "the performer raises one hand",
            cameraMovement: .dollyIn,
            cameraMovementDetail: "35mm follow from full shot to medium close-up",
            narrativeBeat: .reaction,
            renderability: .green,
            matchActionCue: "raised hand reaches eye level",
            continuityLocks: ["red jacket remains zipped"]
        )
        let shot = try Self.shot(height: .eyeLevel, framing: .full, productionPlan: plan)
        let projection = PromptComposer.ShotProjection(shot)
        let video = try await PromptComposer.compose(
            intent: "the performer runs away while the camera pans right",
            modality: .video, modelId: "fal/seedance-2.0", projectDir: nil,
            setting: "inside the red rehearsal room",
            lighting: "soft window light from camera left",
            style: "restrained hand-drawn animation",
            shot: projection
        )
        let image = try await PromptComposer.compose(
            intent: "the performer holds the marked t=0 pose",
            modality: .image, modelId: "openai/gpt-image-2", projectDir: nil,
            setting: "caller supplied rehearsal room",
            lighting: "caller supplied window light",
            style: "caller supplied oil paint",
            shot: projection
        )

        #expect(video.text.contains("the performer raises one hand"))
        #expect(video.text.contains("Match-action cue: raised hand reaches eye level"))
        #expect(!image.text.contains("the performer raises one hand"))
        #expect(!image.text.contains("Match-action cue: raised hand reaches eye level"))
        #expect(video.text.contains("Continuity lock: red jacket remains zipped"))
        #expect(image.text.contains("Continuity lock: red jacket remains zipped"))
        #expect(video.text.contains("single controlled dolly-in"))
        #expect(!video.text.contains("runs away"))
        #expect(!video.text.contains("pans right"))
        #expect(!video.text.contains("inside the red rehearsal room"))
        #expect(!video.text.contains("soft window light from camera left"))
        #expect(!video.text.contains("restrained hand-drawn animation"))
        #expect(!image.text.contains("single controlled dolly-in"))
        #expect(!image.text.contains("35mm follow"))
        #expect(!image.text.contains("caller supplied rehearsal room"))
        #expect(!image.text.contains("caller supplied window light"))
        #expect(!image.text.contains("caller supplied oil paint"))
        #expect(ProductionPromptPolicy.videoPromptViolations(
            video.text,
            expectedMovement: plan.cameraMovement,
            expectedMovementDetail: plan.cameraMovementDetail
        ).isEmpty)
        #expect(ProductionPromptPolicy.stillPromptViolations(image.text).isEmpty)
        #expect(ComplianceLinter.lintLockedDirectives(
            video.text,
            lockedDirectives: shot.videoProductionPromptRequirements
        ).isEmpty)
        #expect(ComplianceLinter.lintLockedDirectives(
            image.text,
            lockedDirectives: shot.stillProductionPromptRequirements
        ).isEmpty)
    }

    @Test("planned still compilation blocks synonym camera motion in caller intent")
    func blocksStillCameraMotion() async throws {
        let plan = try ShotProductionPlan(
            primaryAction: "the performer raises one hand",
            cameraMovement: .dollyIn,
            renderability: .green
        )
        let shot = try Self.shot(
            height: .eyeLevel,
            framing: .full,
            productionPlan: plan
        )

        await #expect(throws: PromptComposer.ComposeError.self) {
            try await PromptComposer.compose(
                intent: "the performer holds still while the view glides forward",
                modality: .image,
                modelId: "openai/gpt-image-2",
                projectDir: nil,
                shot: PromptComposer.ShotProjection(shot)
            )
        }
    }

    @Test("camera-motion synonyms are rejected independently of exact plan prose")
    func rejectsCameraMotionSynonyms() {
        #expect(!ProductionPromptPolicy.stillPromptViolations("Static subject, pan left").isEmpty)
        #expect(!ProductionPromptPolicy.stillPromptViolations("Static subject, tilt up").isEmpty)
        #expect(!ProductionPromptPolicy.stillPromptViolations("Static subject, zoom in").isEmpty)
        #expect(!ProductionPromptPolicy.stillPromptViolations(
            "Static subject while the camera glides forward"
        ).isEmpty)
        for prompt in [
            "Static subject while the camera dollies forward",
            "Static subject while the camera dollies backward",
            "Static subject while the camera is dollying",
            "Static subject while the camera drifts forward",
            "Static subject while the camera creeps in",
            "Static subject while the camera eases back",
            "Static subject while the camera floats past",
            "Static subject while the camera crawls closer",
            "Static subject while the camera swoops down",
            "Static subject while the frame rises",
            "Static subject while the view descends",
        ] {
            #expect(!ProductionPromptPolicy.stillPromptViolations(prompt).isEmpty)
        }
        #expect(!ProductionPromptPolicy.videoPromptViolations(
            "Locked-off static camera. The camera dollies forward.",
            expectedMovement: .static,
            expectedMovementDetail: nil
        ).isEmpty)
        #expect(!ProductionPromptPolicy.videoPromptViolations(
            "Single controlled dolly-in. The view pans right.",
            expectedMovement: .dollyIn,
            expectedMovementDetail: nil
        ).isEmpty)
        #expect(!ProductionPromptPolicy.videoPromptViolations(
            "Single controlled pan. The camera pans right.",
            expectedMovement: .pan,
            expectedMovementDetail: nil
        ).isEmpty)
        #expect(!ProductionPromptPolicy.videoPromptViolations(
            "Single controlled pan. Single controlled pan.",
            expectedMovement: .pan,
            expectedMovementDetail: nil
        ).isEmpty)
        #expect(ProductionPromptPolicy.videoPromptViolations(
            "Single pedestal rise.",
            expectedMovement: .other,
            expectedMovementDetail: "single pedestal rise"
        ).isEmpty)
        #expect(!ProductionPromptPolicy.videoPromptViolations(
            "Single pedestal rise. The camera pans right.",
            expectedMovement: .other,
            expectedMovementDetail: "single pedestal rise"
        ).isEmpty)
    }

    @Test("risky plans project their exact rescue cut into render requirements")
    func projectsRescueCut() throws {
        let plan = try ShotProductionPlan(
            primaryAction: "the performer turns toward the doorway",
            cameraMovement: .static,
            renderability: .yellow,
            risks: [.complexInteraction],
            rescueCut: "cut to a close reaction at the doorway"
        )
        let shot = try Self.shot(
            height: .eyeLevel,
            framing: .full,
            productionPlan: plan
        )

        #expect(shot.videoProductionPromptRequirements.contains(
            "Approved rescue-cut fallback: cut to a close reaction at the doorway"
        ))
    }

    @Test("named blocking anchors project into video and still prompts")
    func projectsBlockingAnchor() async throws {
        let blocking = try CharacterBlocking(
            characterRef: "performer",
            position: "left third",
            pose: "standing",
            gaze: "toward the yard",
            relationToSet: "beside the doorway"
        )
        let plan = try ShotProductionPlan(
            primaryAction: "the performer waits",
            cameraMovement: .static,
            renderability: .green,
            blockingAnchors: [
                ProductionBlockingAnchor(
                    characterRef: "performer",
                    setAnchor: "hall doorway"
                ),
            ]
        )
        let shot = try Self.shot(
            height: .eyeLevel,
            framing: .full,
            productionPlan: plan,
            characterBlocking: [blocking]
        )
        let projection = PromptComposer.ShotProjection(shot)
        let video = try await PromptComposer.compose(
            intent: "the performer waits",
            modality: .video,
            modelId: "fal/seedance-2.0",
            projectDir: nil,
            shot: projection
        )
        let image = try await PromptComposer.compose(
            intent: "the performer waits",
            modality: .image,
            modelId: "openai/gpt-image-2",
            projectDir: nil,
            shot: projection
        )

        #expect(video.text.contains("hall doorway"))
        #expect(image.text.contains("hall doorway"))
    }

    @Test("host compiler scopes ledger objects to each shot")
    func compilerScopesLedgerObjects() async throws {
        let first = try Shot(
            id: "s001",
            section: "verse",
            timeStart: 0,
            timeEnd: 4,
            durationS: 4,
            type: .establishing,
            description: "Ari enters the observatory.",
            visualPrompt: "Ari enters the observatory.",
            mood: "quiet",
            characterRefs: ["ari"],
            locationRef: "observatory",
            propRefs: ["telescope"]
        )
        let second = try Shot(
            id: "s002",
            section: "chorus",
            timeStart: 4,
            timeEnd: 8,
            durationS: 4,
            type: .establishing,
            description: "Bea enters the greenhouse.",
            visualPrompt: "Bea enters the greenhouse.",
            mood: "bright",
            characterRefs: ["bea"],
            locationRef: "greenhouse",
            propRefs: ["watering-can"]
        )
        let ledger = Ledger(objects: [
            "film": ["grain": Attribute(tag: "fine film grain", locked: true)],
            "look": ["palette": Attribute(tag: "restrained amber palette", locked: true)],
            "character:ari": ["wardrobe": Attribute(tag: "Ari wears a blue wool coat", locked: true)],
            "character:bea": ["wardrobe": Attribute(tag: "Bea wears a green silk dress", locked: true)],
            "location:observatory": ["set": Attribute(tag: "brass observatory interior", locked: true)],
            "location:greenhouse": ["set": Attribute(tag: "glass greenhouse interior", locked: true)],
            "prop:telescope": ["finish": Attribute(tag: "weathered brass telescope", locked: true)],
            "prop:watering-can": ["finish": Attribute(tag: "red enamel watering can", locked: true)],
            "shot:s001": ["weather": Attribute(tag: "rain traces on the window", locked: true)],
            "shot:s002": ["weather": Attribute(tag: "sunlight through wet leaves", locked: true)],
        ])
        let project = try Self.project(shots: [first, second], ledger: ledger)
        let editor = EditorViewModel()
        editor.projectURL = project
        defer { Self.removeProject(project, editor: editor) }

        let firstPrompt = try await PromptCompiler.compile(
            intent: first.visualPrompt,
            modelId: "openai/gpt-image-2",
            modality: .image,
            editor: editor,
            shotId: first.id,
            shot: PromptComposer.ShotProjection(first)
        ).text
        let secondPrompt = try await PromptCompiler.compile(
            intent: second.visualPrompt,
            modelId: "openai/gpt-image-2",
            modality: .image,
            editor: editor,
            shotId: second.id,
            shot: PromptComposer.ShotProjection(second)
        ).text

        for expected in ["fine film grain", "restrained amber palette"] {
            #expect(firstPrompt.contains(expected))
            #expect(secondPrompt.contains(expected))
        }
        for expected in [
            "Ari wears a blue wool coat",
            "brass observatory interior", "weathered brass telescope", "rain traces on the window",
        ] {
            #expect(firstPrompt.contains(expected))
            #expect(!secondPrompt.contains(expected))
        }
        for expected in [
            "Bea wears a green silk dress",
            "glass greenhouse interior", "red enamel watering can", "sunlight through wet leaves",
        ] {
            #expect(secondPrompt.contains(expected))
            #expect(!firstPrompt.contains(expected))
        }
    }

    @Test("audio compilation excludes visual ledger directives")
    func audioExcludesVisualLedger() async throws {
        let shot = try Self.shot(height: .eyeLevel, framing: .full)
        let ledger = Ledger(objects: [
            "look": ["palette": Attribute(tag: "restrained amber palette", locked: true)],
            "character:performer": ["wardrobe": Attribute(tag: "blue wool coat", locked: true)],
        ])
        let project = try Self.project(shots: [shot], ledger: ledger)
        let editor = EditorViewModel()
        editor.projectURL = project
        defer { Self.removeProject(project, editor: editor) }

        let prompt = try await PromptCompiler.compile(
            intent: "Sparse room tone with a distant train.",
            modelId: "elevenlabs/sound-effects",
            modality: .audio,
            editor: editor
        ).text

        #expect(prompt == "Sparse room tone with a distant train.")
        #expect(!prompt.contains("amber palette"))
        #expect(!prompt.contains("blue wool coat"))
    }

    @Test("director pattern contributes lighting without overriding the shot camera")
    func patternDoesNotInjectCameraVocabulary() async throws {
        let shot = try Self.shot(height: .eyeLevel, framing: .full)
        let brief = try Brief(
            project: "prompt-test",
            generated: "2026-09-09",
            mission: .artPiece,
            targetPlatform: "film",
            aspectRatio: .landscape16x9,
            projectMode: "section",
            conceptType: .narrative,
            visualMedium: .liveActionStylized,
            visualMediumNotes: "A theatrical practical-light treatment with restrained color separation.",
            figures: .artistOnly,
            lyricsIntegration: .metaphorical,
            directorPattern: "one-shot-ok-go-precision"
        )
        let project = try Self.project(
            shots: [shot],
            ledger: Ledger(),
            brief: brief,
            musicvideo: true
        )
        let editor = EditorViewModel()
        editor.projectURL = project
        defer { Self.removeProject(project, editor: editor) }

        let prompt = try await PromptCompiler.compile(
            intent: "The performer holds a precise opening pose.",
            modelId: "openai/gpt-image-2",
            modality: .image,
            editor: editor,
            shotId: shot.id,
            shot: PromptComposer.ShotProjection(shot)
        ).text

        #expect(prompt.contains("fully pre-lit set with constant exposure"))
        #expect(!prompt.contains("continuous tracking shot"))
        #expect(!prompt.contains("Steadicam / gimbal long take"))
        #expect(!prompt.contains("synchronized lateral dolly"))
        #expect(!prompt.contains("single long crane move"))
    }

    @Test("host composer compiles the exact typed reference order")
    func compilerUsesTypedReferencePlan() async throws {
        let shot = try Self.shot(height: .eyeLevel, framing: .ms)
        let context = PromptComposer.VideoContext(
            modeID: "reference-to-video",
            dialect: VideoPromptDialectV1(
                id: "seedance-2.5",
                version: 1,
                family: .seedance,
                evidence: "fixture"
            ),
            references: [
                VideoPromptReferenceV1(
                    planIndex: 0,
                    modalityIndex: 1,
                    modality: .image,
                    role: .character,
                    semanticJobID: "character.identity",
                    assetID: "bea-profile",
                    entityID: "bea",
                    viewID: "profile"
                ),
                VideoPromptReferenceV1(
                    planIndex: 1,
                    modalityIndex: 2,
                    modality: .image,
                    role: .character,
                    semanticJobID: "character.identity",
                    assetID: "bea-front",
                    entityID: "bea",
                    viewID: "front"
                ),
            ],
            startState: "Bea faces left.",
            endState: "Bea faces camera.",
            blocking: ["bea: center frame"],
            timedActionBeats: [],
            continuityLocks: ["coat remains fastened"],
            transitionIntent: nil
        )

        let prompt = try await PromptComposer.compose(
            intent: "Bea turns toward camera.",
            modality: .video,
            modelId: "bytedance/seedance-2.5/reference-to-video",
            projectDir: nil,
            shot: PromptComposer.ShotProjection(shot),
            videoContext: context
        ).text

        #expect(prompt.contains("@Image1 defines <bea / profile>"))
        #expect(prompt.contains("@Image2 defines <bea / front>"))
        #expect(!prompt.contains("@Image3"))
        #expect(prompt.contains("FIRST FRAME: Bea faces left"))
        #expect(prompt.contains("ENDING STATE: Bea faces camera"))
    }
}
