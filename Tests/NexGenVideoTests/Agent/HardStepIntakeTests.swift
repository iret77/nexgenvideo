import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenVideo
import NexGenEngine

@Suite("Hard-step intake")
struct HardStepIntakeTests {

    // MARK: - Helpers

    private func makeDataRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngv-intake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ relPath: String, in root: URL, contents: String = "x") throws {
        let url = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeApprovedAnalysis(in dataRoot: URL) throws {
        let trackURL = dataRoot.appendingPathComponent("audio/track.wav")
        try FileManager.default.createDirectory(
            at: trackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture-track".utf8).write(to: trackURL)
        let trackHash = try FileDigest.sha256(of: trackURL)
        let analysisURL = dataRoot.appendingPathComponent("analysis/track.json")
        try FileManager.default.createDirectory(
            at: analysisURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let analysis: [String: Any] = [
            "schema": analysisSchemaVersion,
            "project": "hard-step-intake",
            "song_path": "audio/track.wav",
            "song_sha256": trackHash,
            "sample_rate": 44_100,
            "duration_s": 12.0,
            "bpm": 120.0,
            "tempo_multiplier": 1.0,
            "beats": [0.5, 1.0, 1.5, 2.0, 2.5],
            "downbeats": [0.5, 2.5],
            "sections": [[
                "index": 0, "start": 0.0, "end": 12.0, "cluster": 0,
                "source": "measured_system_hierarchy",
            ]],
            "structure_candidates": [
                ["source": "librosa", "sections": [[
                    "index": 0, "start": 0.0, "end": 12.0, "cluster": 0,
                ]]],
                ["source": "essentia", "sections": [[
                    "index": 0, "start": 0.0, "end": 12.0, "cluster": 0,
                ]]],
            ],
            "structure_resolution": [
                "version": "adaptive-structure/v5",
                "status": "resolved",
                "method": "music_understanding_hierarchy",
                "detector_sources": ["apple_music_understanding"],
                "minimum_section_bars": 0,
                "candidate_boundary_count": 0,
                "consensus_boundary_count": 0,
                "alignment_marker_count": 0,
                "resolved_alignment_marker_count": 0,
                "accepted_boundary_count": 0,
                "discarded_boundary_count": 0,
                "boundary_evidence": [[
                    "time": 0.0,
                    "kind": "system_hierarchy",
                    "detector_sources": ["apple_music_understanding"],
                ]],
                "hierarchy": [
                    "source": "apple_music_understanding",
                    "sections": [["start": 0.0, "end": 12.0]],
                    "segments": [["start": 0.0, "end": 12.0]],
                    "phrases": [["start": 0.0, "end": 12.0]],
                ],
                "detail": "Measured system hierarchy.",
            ],
            "downbeat_source": "music-understanding",
            "pipeline_stages": ["structure", "music_understanding"],
            "stage_diagnostics": [[
                "stage": "music_understanding",
                "status": "succeeded",
                "detail": "Measured system hierarchy.",
            ]],
            "alignment": [],
            "interpretation": [
                "section_labels": [[
                    "index": "0", "label": "intro", "confidence": "1.0",
                ]],
                "anomalies": [],
                "overall_character": "Measured opening.",
            ],
        ]
        try JSONSerialization.data(withJSONObject: analysis).write(to: analysisURL)
        try AnalysisMeasurementProofStore.save(
            AnalysisMeasurementProof(
                project: "hard-step-intake",
                songSHA256: trackHash,
                lyricsAlignment: nil
            ),
            dataRoot: dataRoot
        )
        let registry = PackCatalog.registry(activePack: "musicvideo")
        guard let lineage = registry.phaseLineageProviders["analysis"],
              let requirement = registry.gateRequirements["analysis"] else {
            throw CocoaError(.fileNoSuchFile)
        }
        try PipelineLineageStore.record(
            phase: "analysis",
            snapshot: try lineage(dataRoot),
            dataRoot: dataRoot
        )
        try requirement(dataRoot)
    }

    private func step(_ id: String, phase: String = "p", kind: HardStep.Kind,
                      required: Bool = false, repeatable: Bool = false) -> HardStep {
        HardStep(id: id, phase: phase, kind: kind, accept: [], multiple: false,
                 required: required, repeatable: repeatable, title: id, intro: nil,
                 prompt: nil, namePrompt: nil, addAnotherLabel: nil,
                 itemTitle: nil, skipLabel: nil, doneLabel: nil, addFileLabel: nil,
                 symbol: "tray", confirmLabel: "Continue", textField: nil)
    }

    // MARK: - Manifest decoding

    @Test("decodes phases and steps in declared order, tolerating unknown keys")
    func decodesManifest() throws {
        let json = """
        {
          "schema": "hardsteps/1.0",
          "unknownTopLevel": 42,
          "phases": [
            {
              "phase": "project_init",
              "somethingNew": true,
              "steps": [
                {"id": "a", "attachAs": "script", "title": "Script", "futureField": "ignored"},
                {"id": "b", "attachAs": "character", "title": "Characters",
                 "multiple": true, "repeatable": true, "namePrompt": "Name",
                 "itemTitle": "Character", "skipLabel": "Skip", "doneLabel": "Done",
                 "addFileLabel": "Add image"}
              ]
            },
            {
              "phase": "analysis",
              "steps": [
                {"id": "c", "attachAs": "song", "title": "Track", "required": true,
                 "textField": {"placeholder": "or paste", "multiline": true}}
              ]
            }
          ]
        }
        """
        let manifest = try HardStepManifest.decode(Data(json.utf8))
        let initSteps = manifest.steps(for: "project_init")
        #expect(initSteps.map(\.id) == ["a", "b"])
        #expect(initSteps[0].kind == .script)
        #expect(initSteps[1].repeatable)
        #expect(initSteps[1].multiple)
        #expect(initSteps[1].namePrompt == "Name")
        #expect(initSteps[1].itemTitle == "Character")
        #expect(initSteps[1].skipLabel == "Skip")
        #expect(initSteps[1].doneLabel == "Done")
        #expect(initSteps[1].addFileLabel == "Add image")

        let analysisSteps = manifest.steps(for: "analysis")
        #expect(analysisSteps.map(\.id) == ["c"])
        #expect(analysisSteps[0].required)
        #expect(analysisSteps[0].textField?.multiline == true)
        #expect(manifest.steps(for: "nope").isEmpty)
    }

    @Test("a step naming an unsupported attachAs is dropped, its siblings survive")
    func dropsUnknownKind() throws {
        let json = """
        {"phases": [{"phase": "p", "steps": [
          {"id": "future", "attachAs": "hologram", "title": "Hologram"},
          {"id": "keep", "attachAs": "lyrics", "title": "Lyrics"}
        ]}]}
        """
        let manifest = try HardStepManifest.decode(Data(json.utf8))
        #expect(manifest.steps(for: "p").map(\.id) == ["keep"])
    }

    @Test("a pack directory without hardsteps.json yields no manifest")
    func missingFileYieldsNoSteps() throws {
        let dir = try makeDataRoot()
        #expect(HardStepManifest.load(packResourceDir: dir) == nil)
        #expect(HardStepManifest.empty.allSteps.isEmpty)
    }

    @Test("a malformed manifest yields no manifest rather than throwing at the caller")
    func malformedFileYieldsNil() throws {
        let dir = try makeDataRoot()
        try write(HardStepManifest.resourceName, in: dir, contents: "{ not json")
        #expect(HardStepManifest.load(packResourceDir: dir) == nil)
    }

    @Test("finds a manifest in the canonical assembled pack resources")
    func findsManifestInAssembledPack() throws {
        let bundle = try makeDataRoot().appendingPathComponent("musicvideo.ngvpack", isDirectory: true)
        let json = """
        {"phases": [{"phase": "analysis", "steps": [
          {"id": "analysis.song", "attachAs": "song", "title": "Track",
           "required": true, "accept": ["audio"]}
        ]}]}
        """
        try write(
            "Contents/Resources/MusicvideoPack/hardsteps.json",
            in: bundle,
            contents: json
        )

        let manifest = try #require(HardStepManifest.load(bundleURL: bundle))
        #expect(manifest.steps(for: "analysis").first?.kind == .song)
    }

    // MARK: - Satisfaction

    @Test("every kind reads unsatisfied against an empty data root")
    func unsatisfiedWhenEmpty() throws {
        let root = try makeDataRoot()
        for kind in HardStep.Kind.allCases {
            if IntakeSatisfaction.isSatisfied(kind, dataRoot: root) {
                Issue.record("\(kind) should be unsatisfied in an empty data root")
            }
        }
    }

    @Test("each kind is satisfied by its own artifact")
    func satisfiedByArtifact() throws {
        let root = try makeDataRoot()
        try write("audio/track.mp3", in: root)
        try write("lyrics/lyrics.txt", in: root, contents: "[Verse]")
        try write("import/script.md", in: root, contents: "# Story")
        try write("import/characters/mia/front.png", in: root)
        try write("import/locations/bar/wide.png", in: root)
        try write("import/mood.png", in: root)

        for kind in HardStep.Kind.allCases {
            if !IntakeSatisfaction.isSatisfied(kind, dataRoot: root) {
                Issue.record("\(kind) should be satisfied")
            }
        }
    }

    @Test("an empty lyrics file does not satisfy the lyrics step")
    func emptyFileIsNotSatisfaction() throws {
        let root = try makeDataRoot()
        try write("lyrics/lyrics.txt", in: root, contents: "")
        #expect(!IntakeSatisfaction.isSatisfied(.lyrics, dataRoot: root))
    }

    @Test("a scaffolded but empty identity directory is not a prepared identity")
    func gitkeepIsNotAnIdentity() throws {
        let root = try makeDataRoot()
        try write("import/characters/.gitkeep", in: root)
        try write("import/characters/mia/.gitkeep", in: root)
        #expect(!IntakeSatisfaction.isSatisfied(.character, dataRoot: root))
    }

    @Test("identity fingerprint counts populated identities so a repeat offer can tell them apart")
    func identityFingerprintCounts() throws {
        let root = try makeDataRoot()
        #expect(IntakeSatisfaction.fingerprint(.character, dataRoot: root) == 0)
        try write("import/characters/mia/front.png", in: root)
        #expect(IntakeSatisfaction.fingerprint(.character, dataRoot: root) == 1)
        try write("import/characters/rex/front.png", in: root)
        #expect(IntakeSatisfaction.fingerprint(.character, dataRoot: root) == 2)
    }

    @Test("a subdirectory of import/ is an identity anchor, not a style reference")
    func styleCountsLooseFilesOnly() throws {
        let root = try makeDataRoot()
        try write("import/characters/mia/front.png", in: root)
        #expect(!IntakeSatisfaction.isSatisfied(.style, dataRoot: root))
    }

    // MARK: - Decline ledger

    @Test("a declined optional step is never offered again")
    func declinedStepIsNotOffered() throws {
        let root = try makeDataRoot()
        let script = step("s.script", kind: .script)
        let steps = [script, step("s.style", kind: .style)]

        #expect(IntakePlanner.next(steps, dataRoot: root, ledger: IntakeLedger.load(dataRoot: root))?.id == "s.script")

        let ledger = try IntakeLedger.recordDecline(script, dataRoot: root)
        #expect(ledger.isDeclined("s.script"))
        #expect(IntakePlanner.next(steps, dataRoot: root, ledger: ledger)?.id == "s.style")
        // Durable: a fresh read of the sidecar still knows.
        #expect(IntakeLedger.load(dataRoot: root).isDeclined("s.script"))
    }

    @Test("a required step can never be recorded as declined")
    func requiredStepCannotBeDeclined() throws {
        let root = try makeDataRoot()
        let song = step("s.song", kind: .song, required: true)

        let ledger = try IntakeLedger.recordDecline(song, dataRoot: root)
        #expect(!ledger.isDeclined("s.song"))
        #expect(!IntakeLedger.load(dataRoot: root).isDeclined("s.song"))
        #expect(IntakePlanner.next([song], dataRoot: root, ledger: ledger)?.id == "s.song")
    }

    @Test("a missing or malformed ledger reads as nothing declined")
    func brokenLedgerAsksAgain() throws {
        let root = try makeDataRoot()
        #expect(IntakeLedger.load(dataRoot: root).declined.isEmpty)
        try write(IntakeLedger.filename, in: root, contents: "}}not json{{")
        #expect(IntakeLedger.load(dataRoot: root).declined.isEmpty)
    }

    @Test("declines from the former Project Init cards migrate to their Brief ids")
    func formerCreativeDeclinesSurviveUpgrade() throws {
        let root = try makeDataRoot()
        try write(
            IntakeLedger.filename,
            in: root,
            contents: """
            {
              "schema": "intake/1.0",
              "declined": [
                "project_init.script",
                "project_init.characters",
                "project_init.locations",
                "project_init.style"
              ]
            }
            """
        )

        let ledger = IntakeLedger.load(dataRoot: root)
        #expect(ledger.declined == Set([
            "brief.script",
            "brief.characters",
            "brief.locations",
            "brief.style",
        ]))
    }

    // MARK: - Ordering

    @Test("pending steps come in declared order")
    func pendingKeepsDeclaredOrder() throws {
        let root = try makeDataRoot()
        let steps = [step("one", kind: .script), step("two", kind: .character), step("three", kind: .style)]
        let pending = IntakePlanner.pending(steps, dataRoot: root, ledger: IntakeLedger())
        #expect(pending.map(\.id) == ["one", "two", "three"])
    }

    @Test("a satisfied step drops out and the next one moves up")
    func satisfiedStepIsSkipped() throws {
        let root = try makeDataRoot()
        try write("import/script.md", in: root, contents: "# Story")
        let steps = [step("one", kind: .script), step("two", kind: .character)]
        #expect(IntakePlanner.next(steps, dataRoot: root, ledger: IntakeLedger())?.id == "two")
    }

    @Test("a phase whose material is all present asks nothing")
    func midPipelineProjectAsksNothing() throws {
        let root = try makeDataRoot()
        try write("audio/track.mp3", in: root)
        try write("lyrics/lyrics.txt", in: root, contents: "[Verse]")
        let steps = [step("song", kind: .song, required: true), step("lyrics", kind: .lyrics)]
        #expect(IntakePlanner.pending(steps, dataRoot: root, ledger: IntakeLedger()).isEmpty)
    }

    @Test("a phase with no declared steps asks nothing")
    func emptyPhaseAsksNothing() throws {
        let root = try makeDataRoot()
        #expect(IntakePlanner.next([], dataRoot: root, ledger: IntakeLedger()) == nil)
    }

    @Test("preloaded Media assets do not silently satisfy Track or Lyrics")
    @MainActor
    func mediaLibraryIsCandidateNotAssignment() throws {
        let root = try makeDataRoot()
        let track = MediaAsset(
            id: "library-track",
            url: root.appendingPathComponent("media/song.wav"),
            type: .audio,
            name: "song"
        )
        let lyrics = MediaAsset(
            id: "library-lyrics",
            url: root.appendingPathComponent("media/lyrics.txt"),
            type: .document,
            name: "lyrics"
        )
        let library = [track, lyrics]
        #expect(library.count == 2)
        #expect(!IntakeSatisfaction.isSatisfied(.song, dataRoot: root))
        #expect(!IntakeSatisfaction.isSatisfied(.lyrics, dataRoot: root))

        let manifestURL = try #require(PackKnowledge.hardStepManifestURL())
        let manifest = try HardStepManifest.decode(try Data(contentsOf: manifestURL))
        let first = try #require(
            IntakePlanner.next(
                manifest.steps(for: "project_init"),
                dataRoot: root,
                ledger: IntakeLedger()
            )
        )
        let dialog = AgentDialog(hardStep: first, isRepeat: false)
        #expect(dialog.title == "Track")
        #expect(dialog.fileIntake?.required == true)
    }

    @Test("the visible first card stays Track when Media already contains track and lyrics")
    @MainActor
    func visibleFirstCardIgnoresUnassignedLibraryAssets() async throws {
        PackCatalog.register(MusicvideoPack())
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("visible-first-card-\(UUID().uuidString).ngv", isDirectory: true)
        let editor = EditorViewModel()
        defer {
            editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: package)
        }
        try Fixtures.prepareProjectPackage(at: package)
        try ProjectPluginSettings.setActivePlugin("musicvideo", projectURL: package)
        _ = try ProjectScaffold.initProject(
            home: package,
            name: "visible-first-card",
            mode: .beat,
            extraDirs: PackCatalog.projectDirs(activePack: "musicvideo")
        )
        editor.projectURL = package
        let workingRoot = try #require(editor.workingRoot)
        editor.mediaAssets = [
            MediaAsset(
                id: "library-track",
                url: workingRoot.appendingPathComponent("media/song.wav"),
                type: .audio,
                name: "song"
            ),
            MediaAsset(
                id: "library-lyrics",
                url: workingRoot.appendingPathComponent("media/lyrics.txt"),
                type: .document,
                name: "lyrics"
            ),
        ]

        let firstRefresh = Task { @MainActor in
            await editor.refreshEngineState()
            return editor.projectState?.nextPhaseName
        }
        let secondRefresh = Task { @MainActor in
            await editor.refreshEngineState()
            return editor.projectState?.nextPhaseName
        }
        #expect(await firstRefresh.value == "project_init")
        #expect(await secondRefresh.value == "project_init")
        _ = editor.pipelineAgentHarness.reconcile(editor: editor)

        #expect(editor.projectState?.nextPhaseName == "project_init")
        #expect(editor.agentService.pendingDialog?.title == "Track")
        #expect(editor.agentService.pendingDialog?.fileIntake?.attachAs == "song")
    }

    @Test("Existing story becomes visible only after the analysis frontier is approved")
    @MainActor
    func visibleCreativeIntakeWaitsForAnalysis() async throws {
        PackCatalog.register(MusicvideoPack())
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("creative-frontier-\(UUID().uuidString).ngv", isDirectory: true)
        let editor = EditorViewModel()
        defer {
            editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: package)
        }
        try Fixtures.prepareProjectPackage(at: package)
        try ProjectPluginSettings.setActivePlugin("musicvideo", projectURL: package)
        let packageDataRoot = try ProjectScaffold.initProject(
            home: package,
            name: "creative-frontier",
            mode: .beat,
            extraDirs: PackCatalog.projectDirs(activePack: "musicvideo")
        )
        let packageStore = YAMLArtifactStore(dataRoot: packageDataRoot)
        var packageGates = try packageStore.load(Gates.self, at: PipelineLayout.gatesFile)
        GatesOperations.approve(&packageGates, phase: "project_init")
        try packageStore.save(packageGates, to: PipelineLayout.gatesFile)
        editor.projectURL = package

        await editor.refreshEngineState()
        #expect(editor.projectState?.nextPhaseName == "analysis")
        #expect(editor.agentService.pendingDialog == nil)

        let storyDialog = AgentDialog(
            id: "story-too-early",
            title: "Choose the story",
            symbol: "book",
            intro: nil,
            costHint: nil,
            confirmLabel: "Continue",
            textField: nil,
            sections: []
        )
        #expect(throws: ToolError.self) {
            try editor.pipelineAgentHarness.guardAgentDecision(
                storyDialog,
                editor: editor
            )
        }
        let liveDataRoot = try #require(
            editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
        )
        let liveStore = YAMLArtifactStore(dataRoot: liveDataRoot)
        var liveGates = try liveStore.load(Gates.self, at: PipelineLayout.gatesFile)
        GatesOperations.approve(&liveGates, phase: "analysis")
        try liveStore.save(liveGates, to: PipelineLayout.gatesFile)

        await editor.refreshEngineState()
        _ = editor.pipelineAgentHarness.reconcile(editor: editor)
        #expect(editor.projectState?.nextPhaseName == "brief")
        #expect(editor.agentService.pendingDialog?.title == "Existing story")
        #expect(editor.agentService.pendingDialog?.fileIntake?.attachAs == "script")
        let prompt = try editor.pipelineAgentHarness.agentPrompt(
            dataRoot: liveDataRoot
        )
        let normalizedPrompt = prompt?
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        #expect(prompt?.contains("# Phase K1 — Brief") == true)
        #expect(normalizedPrompt?.contains("If it is absent, this is greenfield") == true)

        let staleStoryDialog = try #require(editor.agentService.pendingDialog)
        var advancedGates = try liveStore.load(Gates.self, at: PipelineLayout.gatesFile)
        GatesOperations.approve(&advancedGates, phase: "brief")
        try liveStore.save(advancedGates, to: PipelineLayout.gatesFile)
        await editor.refreshEngineState()
        editor.agentService.submitDialog(
            staleStoryDialog,
            result: AgentDialogResult(
                selectedLabels: [:],
                toggles: [:],
                direction: "A story that must not be written from a stale card."
            )
        )

        #expect(editor.agentService.pendingDialog?.id == staleStoryDialog.id)
        #expect(editor.agentService.dialogSubmissionError?.contains("earlier phase") == true)
        #expect(!FileManager.default.fileExists(
            atPath: liveDataRoot.appendingPathComponent("import/script.md").path
        ))
    }

    @Test("repeatable intake advances directly and Done finishes without attaching an empty item")
    @MainActor
    func repeatableIntakeDoneFinishesWithoutEmptyAttachment() async throws {
        PackCatalog.register(MusicvideoPack())
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("repeatable-intake-done-\(UUID().uuidString).ngv", isDirectory: true)
        let editor = EditorViewModel()
        defer {
            editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: package)
        }
        try Fixtures.prepareProjectPackage(at: package)
        try ProjectPluginSettings.setActivePlugin("musicvideo", projectURL: package)
        let packageDataRoot = try ProjectScaffold.initProject(
            home: package,
            name: "repeatable-intake-done",
            mode: .beat,
            extraDirs: PackCatalog.projectDirs(activePack: "musicvideo")
        )
        let packageStore = YAMLArtifactStore(dataRoot: packageDataRoot)
        try writeApprovedAnalysis(in: packageDataRoot)
        var packageGates = try packageStore.load(Gates.self, at: PipelineLayout.gatesFile)
        GatesOperations.approve(&packageGates, phase: "project_init")
        GatesOperations.approve(&packageGates, phase: "analysis")
        try packageStore.save(packageGates, to: PipelineLayout.gatesFile)
        editor.projectURL = package

        await editor.refreshEngineState()
        let dataRoot = try #require(
            editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
        )
        let manifestURL = try #require(PackKnowledge.hardStepManifestURL())
        let manifest = try HardStepManifest.decode(try Data(contentsOf: manifestURL))
        let script = try #require(
            manifest.steps(for: "brief").first { $0.kind == .script }
        )
        _ = try IntakeLedger.recordDecline(script, dataRoot: dataRoot)
        editor.agentService.pendingDialog = nil
        editor.pipelineAgentHarness.reset()
        _ = editor.pipelineAgentHarness.reconcile(editor: editor)

        let first = try #require(editor.agentService.pendingDialog)
        #expect(first.title == "Prepared character 1")
        try write("fixtures/first.png", in: dataRoot)
        editor.agentService.submitDialog(
            first,
            result: AgentDialogResult(
                selectedLabels: [:],
                toggles: [:],
                direction: "Character One",
                fileURLs: [dataRoot.appendingPathComponent("fixtures/first.png")]
            )
        )
        #expect(editor.agentService.submittingDialogID == first.id)
        editor.agentService.completeDialog(first)

        #expect(editor.agentService.pendingDialog != nil)
        #expect(editor.agentService.submittingDialogID == first.id)
        #expect(editor.agentService.isComposerBlocked)
        let awaitedSecond = await waitForDialog(
            titled: "Prepared character 2",
            service: editor.agentService
        )
        let second = try #require(awaitedSecond)
        #expect(second.title == "Prepared character 2")
        let firstRecord = try #require(
            editor.agentService.messages.last?.userPresentation?.workflowRecord
        )
        #expect(firstRecord.title == "Prepared character 1")
        #expect(firstRecord.phase == "brief")
        #expect(firstRecord.detail == "Character One")
        #expect(firstRecord.attachmentNames == ["first.png"])
        #expect(firstRecord.outcome == .attached)
        try write("fixtures/second.png", in: dataRoot)
        editor.agentService.submitDialog(
            second,
            result: AgentDialogResult(
                selectedLabels: [:],
                toggles: [:],
                direction: "Character Two",
                fileURLs: [dataRoot.appendingPathComponent("fixtures/second.png")]
            )
        )

        #expect(editor.agentService.pendingDialog != nil)
        #expect(editor.agentService.isComposerBlocked)
        let awaitedThird = await waitForDialog(
            titled: "Prepared character 3",
            service: editor.agentService
        )
        let third = try #require(awaitedThird)
        #expect(!IntakeLedger.load(dataRoot: dataRoot).isDeclined("brief.characters"))
        editor.agentService.completeDialog(first)
        #expect(editor.agentService.pendingDialog?.id == third.id)
        #expect(!IntakeLedger.load(dataRoot: dataRoot).isDeclined("brief.characters"))
        editor.agentService.completeDialog(third)
        #expect(editor.agentService.pendingDialog?.title == "Prepared location 1")
        #expect(editor.agentService.dialogSubmissionError == nil)
        #expect(IntakeLedger.load(dataRoot: dataRoot).isDeclined("brief.characters"))
        #expect(editor.agentService.isComposerBlocked)

        let firstLocation = try #require(editor.agentService.pendingDialog)
        try write("fixtures/location-first.png", in: dataRoot)
        editor.agentService.submitDialog(
            firstLocation,
            result: AgentDialogResult(
                selectedLabels: [:],
                toggles: [:],
                direction: "Shared location",
                fileURLs: [dataRoot.appendingPathComponent("fixtures/location-first.png")]
            )
        )
        let awaitedSecondLocation = await waitForDialog(
            titled: "Prepared location 2",
            service: editor.agentService
        )
        let secondLocation = try #require(awaitedSecondLocation)
        try write("fixtures/location-second.png", in: dataRoot)
        editor.agentService.submitDialog(
            secondLocation,
            result: AgentDialogResult(
                selectedLabels: [:],
                toggles: [:],
                direction: "Shared location",
                fileURLs: [dataRoot.appendingPathComponent("fixtures/location-second.png")]
            )
        )
        let awaitedThirdLocation = await waitForDialog(
            titled: "Prepared location 3",
            service: editor.agentService
        )
        let thirdLocation = try #require(awaitedThirdLocation)
        #expect(!IntakeLedger.load(dataRoot: dataRoot).isDeclined("brief.locations"))
        editor.agentService.completeDialog(thirdLocation)
        #expect(editor.agentService.pendingDialog?.title == "Style references")
        #expect(IntakeLedger.load(dataRoot: dataRoot).isDeclined("brief.locations"))
    }

    @Test("workflow intake failures keep the current card mounted")
    @MainActor
    func workflowIntakeFailureKeepsCardMounted() async throws {
        PackCatalog.register(MusicvideoPack())
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("location-intake-failure-\(UUID().uuidString).ngv", isDirectory: true)
        let editor = EditorViewModel()
        defer {
            editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: package)
        }
        try Fixtures.prepareProjectPackage(at: package)
        try ProjectPluginSettings.setActivePlugin("musicvideo", projectURL: package)
        let packageDataRoot = try ProjectScaffold.initProject(
            home: package,
            name: "location-intake-failure",
            mode: .beat,
            extraDirs: PackCatalog.projectDirs(activePack: "musicvideo")
        )
        let packageStore = YAMLArtifactStore(dataRoot: packageDataRoot)
        var packageGates = try packageStore.load(Gates.self, at: PipelineLayout.gatesFile)
        GatesOperations.approve(&packageGates, phase: "project_init")
        GatesOperations.approve(&packageGates, phase: "analysis")
        try packageStore.save(packageGates, to: PipelineLayout.gatesFile)
        editor.projectURL = package

        await editor.refreshEngineState()
        let dataRoot = try #require(
            editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
        )
        let manifestURL = try #require(PackKnowledge.hardStepManifestURL())
        let manifest = try HardStepManifest.decode(try Data(contentsOf: manifestURL))
        for kind in [HardStep.Kind.script, .character] {
            let step = try #require(manifest.steps(for: "brief").first { $0.kind == kind })
            _ = try IntakeLedger.recordDecline(step, dataRoot: dataRoot)
        }
        editor.agentService.pendingDialog = nil
        editor.pipelineAgentHarness.reset()
        _ = editor.pipelineAgentHarness.reconcile(editor: editor)

        let location = try #require(editor.agentService.pendingDialog)
        try Data("invalid gates".utf8).write(
            to: dataRoot.appendingPathComponent(PipelineLayout.gatesFile),
            options: .atomic
        )
        editor.agentService.cancelDialog()

        #expect(editor.agentService.pendingDialog?.id == location.id)
        #expect(editor.agentService.dialogSubmissionError != nil)
        #expect(editor.agentService.isComposerBlocked)
    }

    // MARK: - Dialog construction

    @MainActor
    private func waitForDialog(
        titled title: String,
        service: AgentService
    ) async -> AgentDialog? {
        for _ in 0..<1_000 {
            if service.pendingDialog?.title == title {
                return service.pendingDialog
            }
            await Task.yield()
        }
        return nil
    }

    @Test("a step becomes a file-intake dialog routed by its attachAs")
    func stepBecomesDialog() {
        let characters = HardStep(
            id: "init.characters", phase: "project_init", kind: .character,
            accept: ["image"], multiple: true, required: false, repeatable: true,
            title: "Prepared characters", intro: "First one.", prompt: "Drop the images",
            namePrompt: "Character name", addAnotherLabel: "Another one?",
            itemTitle: "Prepared character", skipLabel: "Skip",
            doneLabel: "Done", addFileLabel: "Add another image…",
            symbol: "person", confirmLabel: "Attach", textField: nil)

        let first = AgentDialog(hardStep: characters, isRepeat: false)
        #expect(first.title == "Prepared character 1")
        #expect(first.intro == "First one.")
        #expect(first.sections.isEmpty)
        #expect(first.fileIntake?.attachAs == "character")
        #expect(first.fileIntake?.allowsMultiple == true)
        #expect(first.fileIntake?.namePrompt == "Character name")
        #expect(first.fileIntake?.completionLabel == "Skip")
        #expect(first.fileIntake?.addFileLabel == "Add another image…")
        #expect(first.purpose == .workflowIntake)
        #expect(first.fileIntake?.required == false)
        #expect(!first.permitsSubmission(
            hasFiles: false, direction: "", isSubmitting: false
        ))
        #expect(!first.permitsSubmission(
            hasFiles: true, direction: "", isSubmitting: false
        ))
        #expect(!first.permitsSubmission(
            hasFiles: false, direction: "Claude Mouse", isSubmitting: false
        ))
        #expect(!first.permitsSubmission(
            hasFiles: true, direction: "---", isSubmitting: false
        ))
        #expect(first.permitsSubmission(
            hasFiles: true, direction: "Claude Mouse", isSubmitting: false
        ))
        #expect(!first.permitsSubmission(
            hasFiles: true, direction: "Claude Mouse", isSubmitting: true
        ))

        let repeated = AgentDialog(hardStep: characters, isRepeat: true)
        #expect(repeated.title == "Prepared character 2")
        #expect(repeated.intro == "Another one?")
        #expect(repeated.fileIntake?.completionLabel == "Done")
        #expect(repeated.id != first.id)
        #expect(repeated.permitsCompletion(
            hasFiles: false, direction: "", isSubmitting: false
        ))
        #expect(!repeated.permitsCompletion(
            hasFiles: true, direction: "", isSubmitting: false
        ))
        #expect(!repeated.permitsCompletion(
            hasFiles: false, direction: "Claude Mouse", isSubmitting: false
        ))
        #expect(!repeated.permitsCompletion(
            hasFiles: false, direction: "", isSubmitting: true
        ))
        #expect(!repeated.hasRepeatableIntakeDraft(hasFiles: false, direction: ""))
        #expect(repeated.hasRepeatableIntakeDraft(hasFiles: true, direction: ""))
        #expect(repeated.hasRepeatableIntakeDraft(
            hasFiles: false, direction: "Claude Mouse"
        ))

        let third = AgentDialog(hardStep: characters, isRepeat: true, itemNumber: 3)
        #expect(third.title == "Prepared character 3")
    }

    @Test("older pinned packs receive the safe repeatable-intake defaults from the host")
    func legacyRepeatableStepGetsHostDefaults() {
        let legacy = HardStep(
            id: "brief.characters", phase: "brief", kind: .character,
            accept: ["image"], multiple: true, required: false, repeatable: true,
            title: "Prepared characters", intro: nil, prompt: "Drop the images",
            namePrompt: "Character name", addAnotherLabel: nil,
            itemTitle: nil, skipLabel: nil, doneLabel: nil, addFileLabel: nil,
            symbol: "person", confirmLabel: "Attach", textField: nil
        )

        let first = AgentDialog(hardStep: legacy, isRepeat: false, itemNumber: 1)
        #expect(first.title == "Prepared character 1")
        #expect(first.fileIntake?.completionLabel == "Skip")
        #expect(first.fileIntake?.addFileLabel == "Add another image…")

        let third = AgentDialog(hardStep: legacy, isRepeat: true, itemNumber: 3)
        #expect(third.title == "Prepared character 3")
        #expect(third.fileIntake?.completionLabel == "Done")
    }

    @Test("a workflow hard step leaves a durable transcript record without starting the agent")
    @MainActor
    func workflowStepDoesNotBecomeChat() async throws {
        PackCatalog.register(MusicvideoPack())
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-intake-\(UUID().uuidString).ngv", isDirectory: true)
        let editor = EditorViewModel()
        defer {
            editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: package)
        }
        try Fixtures.prepareProjectPackage(at: package)
        try ProjectPluginSettings.setActivePlugin("musicvideo", projectURL: package)
        let packageDataRoot = try ProjectScaffold.initProject(
            home: package,
            name: "workflow-intake",
            mode: .beat,
            extraDirs: PackCatalog.projectDirs(activePack: "musicvideo")
        )
        let packageStore = YAMLArtifactStore(dataRoot: packageDataRoot)
        try writeApprovedAnalysis(in: packageDataRoot)
        var packageGates = try packageStore.load(Gates.self, at: PipelineLayout.gatesFile)
        GatesOperations.approve(&packageGates, phase: "project_init")
        GatesOperations.approve(&packageGates, phase: "analysis")
        try packageStore.save(packageGates, to: PipelineLayout.gatesFile)
        editor.projectURL = package

        await editor.refreshEngineState()
        let dataRoot = try #require(
            editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
        )
        let dialog = try #require(editor.agentService.pendingDialog)
        #expect(dialog.title == "Existing story")
        #expect(dialog.purpose == .workflowIntake)
        let messageCount = editor.agentService.messages.count
        editor.agentService.submitDialog(
            dialog,
            result: AgentDialogResult(
                selectedLabels: [:],
                toggles: [:],
                direction: ""
            )
        )

        #expect(editor.agentService.pendingDialog?.title == "Prepared character 1")
        #expect(IntakeLedger.load(dataRoot: dataRoot).isDeclined("brief.script"))
        #expect(editor.agentService.messages.count == messageCount + 1)
        let recordMessage = try #require(editor.agentService.messages.last)
        #expect(recordMessage.blocks.isEmpty)
        #expect(recordMessage.userPresentation?.workflowRecord?.title == "Existing story")
        #expect(recordMessage.userPresentation?.workflowRecord?.outcome == .skipped)
        #expect(editor.agentService.streamError == nil)
        #expect(!editor.agentService.isStreaming)
        await editor.refreshEngineState()
        #expect(editor.agentService.pendingDialog?.title == "Prepared character 1")
        #expect(editor.agentService.messages.count == messageCount + 1)
        #expect(editor.agentService.streamError == nil)
    }

    @Test("required track intake cannot advance without a file")
    @MainActor
    func requiredTrackStaysOpen() async throws {
        PackCatalog.register(MusicvideoPack())
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("required-track-intake-\(UUID().uuidString).ngv", isDirectory: true)
        let editor = EditorViewModel()
        defer {
            editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: package)
        }
        try Fixtures.prepareProjectPackage(at: package)
        try ProjectPluginSettings.setActivePlugin("musicvideo", projectURL: package)
        let packageDataRoot = try ProjectScaffold.initProject(
            home: package,
            name: "required-track-intake",
            mode: .beat,
            extraDirs: PackCatalog.projectDirs(activePack: "musicvideo")
        )
        editor.projectURL = package

        await editor.refreshEngineState()
        let dialog = try #require(editor.agentService.pendingDialog)
        #expect(dialog.title == "Track")
        #expect(dialog.purpose == .workflowIntake)
        editor.agentService.completeDialog(dialog)
        #expect(editor.agentService.pendingDialog?.id == dialog.id)
        #expect(!IntakeLedger.load(dataRoot: packageDataRoot).isDeclined("project_init.song"))
        editor.agentService.submitDialog(
            dialog,
            result: AgentDialogResult(selectedLabels: [:], toggles: [:], direction: "")
        )
        for _ in 0..<1_000 {
            if editor.agentService.dialogSubmissionError != nil { break }
            await Task.yield()
        }

        #expect(editor.agentService.pendingDialog?.id == dialog.id)
        #expect(editor.agentService.dialogSubmissionError == "Choose a track before continuing.")
        #expect(!editor.agentService.isStreaming)
    }

    @Test("the SHIPPED manifest decodes and keeps every step it declares")
    func shippedManifestIsUsable() throws {
        // Loads the real `hardsteps.json`, not a literal. An unknown `attachAs` is dropped silently at
        // decode time (so a newer pack degrades instead of crashing an older host) — which means a typo
        // like "characters" would remove that step with nothing to notice. Comparing the decoded count
        // against the raw file is what catches it.
        let url = try #require(PackKnowledge.hardStepManifestURL())
        let data = try Data(contentsOf: url)
        let manifest = try HardStepManifest.decode(data)

        let raw = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawPhases = try #require(raw["phases"] as? [[String: Any]])
        let rawStepCount = rawPhases.reduce(0) { $0 + (($1["steps"] as? [[String: Any]])?.count ?? 0) }

        if manifest.allSteps.count != rawStepCount {
            let kept = Set(manifest.allSteps.map(\.id))
            let declared = rawPhases.flatMap { ($0["steps"] as? [[String: Any]]) ?? [] }
                .compactMap { $0["id"] as? String }
            Issue.record("dropped at decode (unknown attachAs?): \(declared.filter { !kept.contains($0) })")
        }
        let characters = try #require(manifest.allSteps.first { $0.id == "brief.characters" })
        #expect(characters.itemTitle == "Prepared character")
        #expect(characters.skipLabel == "Skip")
        #expect(characters.doneLabel == "Done")
        #expect(characters.addFileLabel == "Add another image…")
    }

    @Test("startup is exactly required track, then optional lyrics")
    func songStepSurvivesShipped() throws {
        let url = try #require(PackKnowledge.hardStepManifestURL())
        let manifest = try HardStepManifest.decode(try Data(contentsOf: url))
        let startup = manifest.steps(for: "project_init")
        #expect(startup.map(\.kind) == [.song, .lyrics])
        let song = try #require(startup.first { $0.kind == .song })
        #expect(song.required)
        #expect(song.accept.contains("audio"))
        #expect(manifest.steps(for: "analysis").isEmpty)
    }

    @Test("creative material is optional and belongs to Brief after analysis")
    func creativeStepsSurviveShipped() throws {
        let url = try #require(PackKnowledge.hardStepManifestURL())
        let manifest = try HardStepManifest.decode(try Data(contentsOf: url))
        #expect(
            manifest.steps(for: "brief").map(\.kind)
                == [.script, .character, .location, .style]
        )
        #expect(manifest.steps(for: "brief").allSatisfy { !$0.required })
    }

    @Test("greenfield and existing-story intake paths are both valid")
    func creativeMaterialPathsAreBothValid() throws {
        let url = try #require(PackKnowledge.hardStepManifestURL())
        let manifest = try HardStepManifest.decode(try Data(contentsOf: url))
        let creative = manifest.steps(for: "brief")

        let greenfield = try makeDataRoot()
        var greenfieldLedger = IntakeLedger()
        for step in creative {
            greenfieldLedger = try IntakeLedger.recordDecline(
                step,
                dataRoot: greenfield
            )
        }
        #expect(greenfieldLedger.declined.count == creative.count)
        #expect(
            IntakePlanner.next(
                creative,
                dataRoot: greenfield,
                ledger: IntakeLedger.load(dataRoot: greenfield)
            ) == nil
        )
        #expect(!IntakeSatisfaction.isSatisfied(.script, dataRoot: greenfield))

        let existingStory = try makeDataRoot()
        try write("import/script.md", in: existingStory, contents: "# Existing story")
        #expect(
            IntakePlanner.next(
                creative,
                dataRoot: existingStory,
                ledger: IntakeLedger()
            )?.kind == .character
        )
        #expect(IntakeSatisfaction.isSatisfied(.script, dataRoot: existingStory))

        let instructions = AgentInstructions.serverInstructions
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        #expect(instructions.contains(
            "A missing story file means greenfield creation from the analyzed song"
        ))
        #expect(instructions.contains(
            "preserve that existing story and identity material as source truth"
        ))
    }

    @Test("release contract routes Track and Lyrics through analysis before Existing story")
    func releaseContractTrace() throws {
        let manifestURL = try #require(PackKnowledge.hardStepManifestURL())
        let manifest = try HardStepManifest.decode(try Data(contentsOf: manifestURL))
        let registry = EngineRegistry()
        MusicvideoPack().register(registry)
        let order = PhaseOrder.merged(packPlacements: registry.phasePlacements)
        #expect(Array(order.prefix(3)) == ["project_init", "analysis", "brief"])

        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-contract-\(UUID().uuidString).ngv", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let dataRoot = try ProjectScaffold.initProject(
            home: package,
            name: "workflow-contract",
            mode: .beat,
            extraDirs: registry.projectDirs
        )
        let store = YAMLArtifactStore(dataRoot: dataRoot)

        var snapshot = try ProjectStateBuilder.buildSnapshot(
            dataRoot: dataRoot,
            packPlacements: registry.phasePlacements
        )
        #expect(snapshot.nextPhase == "project_init")
        var ledger = IntakeLedger()
        var visible = IntakePlanner.next(
            manifest.steps(for: snapshot.nextPhase!),
            dataRoot: dataRoot,
            ledger: ledger
        )
        #expect(visible?.kind == .song)
        #expect(visible?.required == true)

        try write("audio/track.wav", in: dataRoot)
        let trackURL = dataRoot.appendingPathComponent("audio/track.wav")
        visible = IntakePlanner.next(
            manifest.steps(for: snapshot.nextPhase!),
            dataRoot: dataRoot,
            ledger: ledger
        )
        #expect(visible?.kind == .lyrics)
        let lyrics = try #require(visible)
        ledger = try IntakeLedger.recordDecline(
            lyrics,
            dataRoot: dataRoot
        )
        #expect(
            IntakePlanner.next(
                manifest.steps(for: snapshot.nextPhase!),
                dataRoot: dataRoot,
                ledger: ledger
            ) == nil
        )

        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        GatesOperations.approve(&gates, phase: "project_init")
        try store.save(gates, to: PipelineLayout.gatesFile)
        snapshot = try ProjectStateBuilder.buildSnapshot(
            dataRoot: dataRoot,
            packPlacements: registry.phasePlacements
        )
        #expect(snapshot.nextPhase == "analysis")
        #expect(manifest.steps(for: "analysis").isEmpty)

        let analysisDir = dataRoot.appendingPathComponent("analysis", isDirectory: true)
        try FileManager.default.createDirectory(at: analysisDir, withIntermediateDirectories: true)
        let analysis: [String: Any] = [
            "schema": analysisSchemaVersion,
            "project": "workflow-contract",
            "song_path": "audio/track.wav",
            "song_sha256": try FileDigest.sha256(of: trackURL),
            "sample_rate": 44_100,
            "beats": [0.5, 1.0, 1.5, 2.0, 2.5],
            "downbeats": [0.5, 2.5],
            "duration_s": 12.0,
            "bpm": 120.0,
            "tempo_multiplier": 1.0,
            "sections": [[
                "index": 0,
                "start": 0.0,
                "end": 12.0,
                "cluster": 0,
                "source": "measured_system_hierarchy",
            ]],
            "structure_candidates": [
                ["source": "librosa", "sections": [[
                    "index": 0, "start": 0.0, "end": 12.0, "cluster": 0,
                ]]],
                ["source": "essentia", "sections": [[
                    "index": 0, "start": 0.0, "end": 12.0, "cluster": 0,
                ]]],
            ],
            "structure_resolution": [
                "version": "adaptive-structure/v5",
                "status": "resolved",
                "method": "music_understanding_hierarchy",
                "detector_sources": ["apple_music_understanding"],
                "minimum_section_bars": 0,
                "candidate_boundary_count": 0,
                "consensus_boundary_count": 0,
                "alignment_marker_count": 0,
                "resolved_alignment_marker_count": 0,
                "accepted_boundary_count": 0,
                "discarded_boundary_count": 0,
                "boundary_evidence": [[
                    "time": 0.0,
                    "kind": "system_hierarchy",
                    "detector_sources": ["apple_music_understanding"],
                ]],
                "hierarchy": [
                    "source": "apple_music_understanding",
                    "sections": [["start": 0.0, "end": 12.0]],
                    "segments": [["start": 0.0, "end": 12.0]],
                    "phrases": [["start": 0.0, "end": 12.0]],
                ],
                "detail": "Measured system hierarchy.",
            ],
            "downbeat_source": "music-understanding",
            "pipeline_stages": ["structure", "music_understanding"],
            "stage_diagnostics": [[
                "stage": "music_understanding",
                "status": "succeeded",
                "detail": "Measured system hierarchy.",
            ]],
            "alignment": [],
            "interpretation": [
                "section_labels": [[
                    "index": "0",
                    "label": "intro",
                    "confidence": "1.0",
                ]],
                "anomalies": [],
                "overall_character": "Measured opening.",
            ],
        ]
        try JSONSerialization.data(withJSONObject: analysis).write(
            to: analysisDir.appendingPathComponent("track.json")
        )
        try AnalysisMeasurementProofStore.save(
            AnalysisMeasurementProof(
                project: "workflow-contract",
                songSHA256: try FileDigest.sha256(of: trackURL),
                lyricsAlignment: nil
            ),
            dataRoot: dataRoot
        )
        let analysisLineage = try #require(
            registry.phaseLineageProviders["analysis"]
        )
        try PipelineLineageStore.record(
            phase: "analysis",
            snapshot: try analysisLineage(dataRoot),
            dataRoot: dataRoot
        )
        let analysisRequirement = try #require(registry.gateRequirements["analysis"])
        try analysisRequirement(dataRoot)
        GatesOperations.approve(&gates, phase: "analysis")
        try store.save(gates, to: PipelineLayout.gatesFile)
        snapshot = try ProjectStateBuilder.buildSnapshot(
            dataRoot: dataRoot,
            packPlacements: registry.phasePlacements
        )
        #expect(snapshot.nextPhase == "brief")
        visible = IntakePlanner.next(
            manifest.steps(for: snapshot.nextPhase!),
            dataRoot: dataRoot,
            ledger: IntakeLedger.load(dataRoot: dataRoot)
        )
        #expect(visible?.kind == .script)
        #expect(visible?.title == "Existing story")
        #expect(visible?.required == false)
    }
}
