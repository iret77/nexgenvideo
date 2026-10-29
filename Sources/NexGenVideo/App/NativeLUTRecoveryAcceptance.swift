import AppKit
import NexGenEngine

@MainActor
enum NativeLUTRecoveryAcceptance {
    static func run(savedProject: URL, replacement: URL, output: URL, scale: Double) async throws -> [String: Any] {
        let name = "native-lut-recovery-\(Int(scale * 100))"
        let package = output.appendingPathComponent(name + ".ngv", isDirectory: true)
        let originalState = try ExportQueue.PathState.capture(savedProject)
        guard let originalDigest = originalState.digest else { throw GateBlocked("The original LUT project is missing.") }
        let replacementHash = try FileDigest.sha256(of: replacement)
        let expectedPath = "resources/luts/" + replacementHash + ".cube"
        try FileManager.default.copyItem(at: savedProject, to: package)
        let identity = try ProjectIdentity.regenerate(at: package)
        let timelineURL = package.appendingPathComponent(Project.timelineFilename)
        var timeline = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: timelineURL))
        guard let track = timeline.tracks.firstIndex(where: { $0.clips.contains { ($0.effects ?? []).contains { $0.type == "color.lut" } } }),
              let clip = timeline.tracks[track].clips.firstIndex(where: { ($0.effects ?? []).contains { $0.type == "color.lut" } }),
              var effects = timeline.tracks[track].clips[clip].effects,
              let lut = effects.firstIndex(where: { $0.type == "color.lut" }) else { throw GateBlocked("The recovery fixture needs the saved native LUT clip.") }
        let clipID = timeline.tracks[track].clips[clip].id
        let missing = output.appendingPathComponent("Unavailable legacy LUT/Old look.cube")
        guard !FileManager.default.fileExists(atPath: missing.path) else { throw GateBlocked("The legacy LUT fixture is unexpectedly available.") }
        effects[lut].params["path"] = .init(string: missing.path)
        effects[lut].params["name"] = .init(string: "Old look.cube")
        timeline.tracks[track].clips[clip].effects = effects
        try JSONEncoder().encode(timeline).write(to: timelineURL, options: .atomic)
        guard !timeline.tracks.flatMap(\.clips).flatMap({ $0.effects ?? [] }).contains(where: {
            $0.params["path"]?.string == expectedPath
        }) else { throw GateBlocked("The recovery fixture still references the replacement LUT.") }
        let savedReplacement = package.appendingPathComponent(expectedPath)
        if FileManager.default.fileExists(atPath: savedReplacement.path) {
            try FileManager.default.removeItem(at: savedReplacement)
        }
        guard !FileManager.default.fileExists(atPath: savedReplacement.path) else {
            throw GateBlocked("The recovery fixture already contains the replacement LUT.")
        }
        let document = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The missing-LUT project did not open.") }
        document.showWindows()
        NSApp.mainMenu = MainMenuBuilder.buildMenu()
        window.setContentSize(NSSize(width: 960, height: 640))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let editor = document.editorViewModel
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
        var closed = false
        defer { if !closed { document.close() } }
        do {
            try await driver.wait("legacy LUT recovery banner on open") {
                editor.unresolvedEffectResourceProblems.count == 1
                    && driver.text("editor.lut.offline", in: window) == "Old look.cube"
            }
            let broken = editor.timeline
            try driver.capture("missing-on-open", target: window)
            try await driver.click("editor.lut.review", in: window)
            try await driver.wait("native missing LUT inspector") {
                editor.selectedClipIds == [clipID] && editor.workspaceFocus == .postproduction
                    && driver.text("inspector.lut.offline", in: window) == "Old look.cube"
                    && driver.state("inspector.lut.remove", in: window) == true
            }
            try await driver.click("inspector.lut.remove", in: window)
            try await driver.wait("native missing LUT removal") {
                editor.unresolvedEffectResourceProblems.isEmpty
                    && editor.clipFor(id: clipID)?.effects?.contains(where: { $0.type == "color.lut" }) != true
            }
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("native missing LUT removal undo") {
                editor.timeline == broken && editor.unresolvedEffectResourceProblems.count == 1
            }
            try await driver.chooseFile(replacement, in: window, trigger: "inspector.lut.relink")
            try await driver.wait("native missing LUT relink") {
                editor.clipFor(id: clipID)?.effects?.first(where: { $0.type == "color.lut" })?.params["path"]?.string == expectedPath
                    && editor.unresolvedEffectResourceProblems.isEmpty
                    && driver.state("inspector.lut.choose", in: window) == true
                    && driver.text("inspector.lut.name", in: window) == replacement.lastPathComponent
            }
            try driver.capture("relinked", target: window)
            guard document.isDocumentEdited,
                  !FileManager.default.fileExists(atPath: savedReplacement.path),
                  let workingRoot = editor.workingRoot,
                  try FileDigest.sha256(of: workingRoot.appendingPathComponent(expectedPath)) == replacementHash,
                  try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: timelineURL)) == timeline else {
                throw GateBlocked("The recovery Save check has no unsaved native relink to prove.")
            }
            let repaired = editor.timeline
            try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
            try await driver.wait("native relink save", seconds: 30) {
                guard !document.isDocumentEdited, let bytes = try? Data(contentsOf: timelineURL),
                      let saved = try? JSONDecoder().decode(Timeline.self, from: bytes) else { return false }
                return saved == repaired
            }
            guard try FileDigest.sha256(of: package.appendingPathComponent(expectedPath)) == replacementHash else {
                throw GateBlocked("Saving the recovered project omitted the relinked LUT.")
            }
            document.close(); closed = true
            let reopened = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
            NSDocumentController.shared.addDocument(reopened)
            reopened.makeWindowControllers()
            defer { reopened.close() }
            guard reopened.editorViewModel.timeline == repaired, reopened.editorViewModel.unresolvedEffectResourceProblems.isEmpty,
                  let home = reopened.editorViewModel.workingRoot, ProjectIdentity.existingUUID(for: home) == identity,
                  try FileDigest.sha256(of: home.appendingPathComponent(expectedPath)) == replacementHash else {
                throw GateBlocked("The legacy LUT recovery did not survive reopening.")
            }
            let finalOriginalState = try ExportQueue.PathState.capture(savedProject)
            guard finalOriginalState == originalState else {
                throw GateBlocked("LUT recovery modified the original project package.")
            }
            var result = driver.result()
            result.merge(["openedWithVisibleProblem": true, "nativeRemoveUndo": true, "nativeRelink": true,
                "nativeSaveAndReopen": true, "replacementSHA256": replacementHash,
                "replacementAbsentBeforeSave": true, "originalProjectPreserved": true,
                "originalPackageSHA256Before": originalDigest,
                "originalPackageSHA256After": finalOriginalState.digest ?? ""]) { _, new in new }
            return result
        } catch { driver.failure(error); throw error }
    }
}
