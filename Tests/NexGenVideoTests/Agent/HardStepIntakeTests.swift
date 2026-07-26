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
                 "multiple": true, "repeatable": true, "namePrompt": "Name"}
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

        let ledger = IntakeLedger.recordDecline(script, dataRoot: root)
        #expect(ledger.isDeclined("s.script"))
        #expect(IntakePlanner.next(steps, dataRoot: root, ledger: ledger)?.id == "s.style")
        // Durable: a fresh read of the sidecar still knows.
        #expect(IntakeLedger.load(dataRoot: root).isDeclined("s.script"))
    }

    @Test("a required step can never be recorded as declined")
    func requiredStepCannotBeDeclined() throws {
        let root = try makeDataRoot()
        let song = step("s.song", kind: .song, required: true)

        let ledger = IntakeLedger.recordDecline(song, dataRoot: root)
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

    // MARK: - Dialog construction

    @Test("a step becomes a file-intake dialog routed by its attachAs")
    func stepBecomesDialog() {
        let characters = HardStep(
            id: "init.characters", phase: "project_init", kind: .character,
            accept: ["image"], multiple: true, required: false, repeatable: true,
            title: "Prepared characters", intro: "First one.", prompt: "Drop the images",
            namePrompt: "Character name", addAnotherLabel: "Another one?",
            symbol: "person", confirmLabel: "Attach", textField: nil)

        let first = AgentDialog(hardStep: characters, isRepeat: false)
        #expect(first.title == "Prepared characters")
        #expect(first.intro == "First one.")
        #expect(first.sections.isEmpty)
        #expect(first.fileIntake?.attachAs == "character")
        #expect(first.fileIntake?.allowsMultiple == true)
        #expect(first.fileIntake?.namePrompt == "Character name")
        #expect(first.purpose == .workflowIntake)
        // Optional ⇒ confirmable with nothing, which is the user's "no, I don't have one".
        #expect(first.fileIntake?.required == false)

        let repeated = AgentDialog(hardStep: characters, isRepeat: true)
        #expect(repeated.intro == "Another one?")
        #expect(repeated.id != first.id)
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
            hardStep: step("project_init.script", phase: "project_init", kind: .script),
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
    }

    @Test("startup begins with required track, then optional lyrics")
    func songStepSurvivesShipped() throws {
        let url = try #require(PackKnowledge.hardStepManifestURL())
        let manifest = try HardStepManifest.decode(try Data(contentsOf: url))
        let startup = manifest.steps(for: "project_init")
        #expect(startup.prefix(2).map(\.kind) == [.song, .lyrics])
        let song = try #require(startup.first { $0.kind == .song })
        #expect(song.required)
        #expect(song.accept.contains("audio"))
        #expect(manifest.steps(for: "analysis").isEmpty)
    }

    @Test("the shipped startup has one canonical material order")
    func projectInitStepsSurviveShipped() throws {
        let url = try #require(PackKnowledge.hardStepManifestURL())
        let manifest = try HardStepManifest.decode(try Data(contentsOf: url))
        #expect(
            manifest.steps(for: "project_init").map(\.kind)
                == [.song, .lyrics, .script, .character, .location, .style]
        )
    }
}
