import Foundation
import Testing
import MusicvideoPlugin
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

    @Test("finds a manifest inside the assembled pack resource bundle")
    func findsManifestInAssembledPack() throws {
        let bundle = try makeDataRoot().appendingPathComponent("musicvideo.ngvpack", isDirectory: true)
        let json = """
        {"phases": [{"phase": "analysis", "steps": [
          {"id": "analysis.song", "attachAs": "song", "title": "Track",
           "required": true, "accept": ["audio"]}
        ]}]}
        """
        try write(
            "Contents/Resources/MusicvideoPlugin_MusicvideoPlugin.bundle/MusicvideoPack/hardsteps.json",
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
    }

    // MARK: - Dialog construction

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

    @Test("a workflow hard step completes locally without creating an agent turn")
    @MainActor
    func workflowStepDoesNotBecomeChat() async throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-intake-\(UUID().uuidString).ngv", isDirectory: true)
        let editor = EditorViewModel()
        defer {
            editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: package)
        }
        try Fixtures.prepareProjectPackage(at: package)
        _ = try ProjectScaffold.initProject(home: package, name: "workflow-intake", mode: .beat)
        editor.projectURL = package

        let dialog = AgentDialog(
            hardStep: step("brief.script", phase: "brief", kind: .script),
            isRepeat: false
        )
        editor.agentService.pendingDialog = dialog
        let messageCount = editor.agentService.messages.count
        editor.agentService.submitDialog(
            dialog,
            result: AgentDialogResult(
                selectedLabels: [:],
                toggles: [:],
                direction: ""
            )
        )

        #expect(editor.agentService.pendingDialog == nil)
        #expect(editor.agentService.messages.count == messageCount)
        #expect(!editor.agentService.isStreaming)
        await Task.yield()
    }

    @Test("required track intake cannot advance without a file")
    @MainActor
    func requiredTrackStaysOpen() async {
        let editor = EditorViewModel()
        let dialog = AgentDialog(
            hardStep: step("project_init.song", phase: "project_init", kind: .song, required: true),
            isRepeat: false
        )
        editor.agentService.pendingDialog = dialog
        editor.agentService.submitDialog(
            dialog,
            result: AgentDialogResult(selectedLabels: [:], toggles: [:], direction: "")
        )
        await Task.yield()

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
            "beats": [0.5, 1.0, 1.5],
            "downbeats": [0.5, 2.5],
            "duration_s": 12.0,
            "bpm": 120.0,
            "tempo_multiplier": 1.0,
            "sections": [[
                "index": 0,
                "start": 0.0,
                "end": 12.0,
                "cluster": 0,
            ]],
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
