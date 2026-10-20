import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Previous workflow material host guards")
@MainActor
struct PreviousWorkflowMaterialTests {
    @Test func committedStoryAndBibleImagesAreReadOnlyProposals() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let root = fixture.home.appendingPathComponent("pipeline")
        let before = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile))
        let stories = try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .script))
        let story = try #require(stories.items.first)
        #expect(stories.items.count == 1 && stories.unavailableCount == 0)
        #expect(story.selection.historyFingerprint == fixture.history.fingerprint)
        #expect(story.selection.expectedFiles.first?.sha256 == FileDigest.sha256(of: fixture.story))
        #expect(story.displayName == "Courtyard walk")
        #expect(story.preview == .text("# Original treatment\nThe singer crosses the empty courtyard.\n"))
        #expect(story.id.count == 64 && !story.id.contains("pipeline/"))
        let characters = try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .character))
        let character = try #require(characters.items.first)
        #expect(characters.items.count == 1 && characters.unavailableCount == 0)
        #expect(character.id.count == 64 && !character.id.contains("pipeline/"))
        #expect(character.identityName == "Lead Singer")
        #expect(character.selection.expectedFiles.first?.relativePath == "pipeline/bible/hero.png")
        #expect(character.preview == .image(fixture.image))
        #expect(try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile)) == before)
        #expect(try ConfirmedIdentityAssetStoreV1.load(dataRoot: root).entries.isEmpty)
    }

    @Test func missingChangedAndUnsupportedSourcesAreUnavailableWithoutHidingOtherRoles() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let image = fixture.home.appendingPathComponent("pipeline/bible/hero.png")
        try Data("changed original".utf8).write(to: image)
        #expect(try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .character)).unavailableCount == 1)
        #expect(try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .location)).items.count == 1)
        try FileManager.default.removeItem(at: image)
        #expect(try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .character)).items.isEmpty)
        #expect(try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .character)).unavailableCount == 1)
        let unsupported = try makeFixture(storyExtension: "yaml")
        defer { try? FileManager.default.removeItem(at: unsupported.home) }
        let catalog = try PipelinePreviousWorkflowMaterial.load(scope: scope(unsupported, .script))
        #expect(catalog.items.isEmpty && catalog.unavailableCount == 1)
    }

    @Test func archivedMetadataTamperingIsAnErrorRatherThanEmptyHistory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let archived = fixture.home.appendingPathComponent("pipeline/migration-history/\(fixture.history.fingerprint)/pipeline/treatment/current.md")
        try Data("changed archived story".utf8).write(to: archived)
        #expect(throws: (any Error).self) { try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .script)) }
    }

    @Test func selectionsCannotCrossDialogGenerationRoleProjectOrExpectedBytes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let original = scope(fixture, .script)
        let selection = try #require(PipelinePreviousWorkflowMaterial.load(scope: original).items.first).selection
        let other = PreviousWorkflowMaterialScope(projectID: original.projectID, workingRoot: original.workingRoot,
            workingCopyKey: original.workingCopyKey, workingCopyGeneration: UUID(), dialogID: "next-dialog", role: .script)
        #expect(throws: (any Error).self) { try PipelinePreviousWorkflowMaterial.resolve(selection, scope: other) }
        #expect(throws: (any Error).self) { try PipelinePreviousWorkflowMaterial.resolve(selection, scope: scope(fixture, .character)) }
        let wrongProject = PreviousWorkflowMaterialScope(projectID: UUID().uuidString, workingRoot: original.workingRoot,
            workingCopyKey: original.workingCopyKey, workingCopyGeneration: original.workingCopyGeneration, dialogID: original.dialogID, role: .script)
        #expect(throws: (any Error).self) { try PipelinePreviousWorkflowMaterial.load(scope: wrongProject) }
        let forged = PreviousWorkflowMaterialSelection(materialID: selection.materialID, historyFingerprint: selection.historyFingerprint,
            role: .script, scope: original, expectedFiles: [.init(relativePath: "pipeline/import/script.md", sha256: String(repeating: "0", count: 64))], displayName: "Story")
        #expect(throws: (any Error).self) { try PipelinePreviousWorkflowMaterial.resolve(forged, scope: original) }
    }

    @Test func currentDefaultNameSubjectIsExcludedButOrphanAndOtherRoleAreNot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let root = fixture.home.appendingPathComponent("pipeline")
        let current = root.appendingPathComponent("import/characters/lead-singer/current.png")
        try FileManager.default.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.image.write(to: current)
        try ConfirmedIdentityAssetStoreV1.recordIntake(role: .character, identityName: "Lead Singer", identitySlug: "lead-singer",
            paths: ["import/characters/lead-singer/current.png"], dataRoot: root)
        #expect(try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .character)).items.isEmpty)
        #expect(try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .location)).items.count == 1)
        try FileManager.default.removeItem(at: current)
        let again = try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .character))
        #expect(again.items.count == 1 && again.unavailableCount == 0)
    }

    @Test func explicitNewNameDoesNotDeduplicateOnlyByImageBytes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let root = fixture.home.appendingPathComponent("pipeline")
        let renamed = root.appendingPathComponent("import/characters/different-character/current.png")
        try FileManager.default.createDirectory(at: renamed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.image.write(to: renamed)
        try ConfirmedIdentityAssetStoreV1.recordIntake(role: .character, identityName: "Different character", identitySlug: "different-character",
            paths: ["import/characters/different-character/current.png"], dataRoot: root)
        #expect(try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .character)).items.count == 1)
    }

    @Test func postCopyHashGuardRejectsChangedOriginalAndCleanupKeepsInPlaceFiles() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let directory = fixture.home.appendingPathComponent("pipeline/import/characters/lead-singer")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inPlace = directory.appendingPathComponent("kept.png")
        try fixture.image.write(to: inPlace)
        let original = fixture.home.appendingPathComponent("pipeline/bible/hero.png")
        let selected = PreviousWorkflowMaterialSelection(materialID: "copy-fixture", historyFingerprint: fixture.history.fingerprint,
            role: .character, scope: scope(fixture, .character), expectedFiles: [
                .init(relativePath: "pipeline/import/characters/lead-singer/kept.png", sha256: FileDigest.sha256(of: fixture.image)),
                .init(relativePath: "pipeline/bible/hero.png", sha256: FileDigest.sha256(of: fixture.image))
            ], displayName: "Lead Singer")
        let receipt = try AgentService.copyFilesWithReceipt([inPlace, original], into: directory)
        #expect(receipt.names == ["kept.png", "hero.png"])
        #expect(receipt.createdURLs == [directory.appendingPathComponent("hero.png")])
        try AgentService.verifyPreviousWorkflowCopy(selected, receipt: receipt, directory: directory)
        try Data("changed after copy".utf8).write(to: original)
        #expect(throws: (any Error).self) { try AgentService.verifyPreviousWorkflowCopy(selected, receipt: receipt, directory: directory) }
        try receipt.removeCreatedFiles()
        #expect(try Data(contentsOf: inPlace) == fixture.image)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("hero.png").path))
    }

    @Test func targetHashDriftIsRejectedEvenWhenOriginalStillMatches() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let selection = try #require(PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .character)).items.first).selection
        let urls = try PipelinePreviousWorkflowMaterial.verifiedURLs(selection)
        let directory = fixture.home.appendingPathComponent("pipeline/import/characters/lead-singer")
        let receipt = try AgentService.copyFilesWithReceipt(urls, into: directory)
        try Data("wrong copied bytes".utf8).write(to: directory.appendingPathComponent(receipt.names[0]))
        #expect(throws: (any Error).self) { try AgentService.verifyPreviousWorkflowCopy(selection, receipt: receipt, directory: directory) }
        try receipt.removeCreatedFiles()
        #expect(try Data(contentsOf: urls[0]) == fixture.image)
    }

    @Test func hostRejectsMixedScriptSourcesBeforeWorkflowMutation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let service = AgentService(refreshBackendStatusOnInit: false)
        let editor = EditorViewModel(agentService: service)
        defer { service.cancel(); editor.releaseWorkingCopy() }
        editor.projectURL = fixture.home
        let dialog = intake("script")
        try service.presentDialog(dialog)
        let context = try #require(service.previousWorkflowMaterialScope(for: dialog))
        let catalog: PreviousWorkflowMaterialCatalog
        do {
            catalog = try await service.previousWorkflowMaterials(scope: context)
        } catch {
            throw ArchiveFixtureFailure(stage: "host.catalog", cause: String(describing: error),
                evidence: archiveDiagnostic(fixture, staging: context.workingRoot))
        }
        let selection = try #require(catalog.items.first).selection
        let root = try #require(editor.workingRoot).appendingPathComponent("pipeline")
        let before = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile))
        service.submitDialog(dialog, result: .init(selectedLabels: [:], toggles: [:], direction: "Pasted alternative", previousWorkflowSelection: selection))
        #expect(service.dialogSubmissionError == "Choose one story source: a file, previous workflow material, or pasted text.")
        #expect(service.pendingDialog?.id == dialog.id && service.submittingDialogID == nil)
        #expect(try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile)) == before)
        #expect(service.messages.isEmpty)
        service.abandonDialog()
        await #expect(throws: (any Error).self) { try await service.previousWorkflowMaterials(scope: context) }
    }

    @Test func completionCannotSkipHistoryOnlyDraftAndLegacyHasNoScope() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let service = AgentService(refreshBackendStatusOnInit: false)
        let dialog = intake("character")
        try service.presentDialog(dialog)
        service.dialogDraft = .init(previousWorkflowSelection: try #require(PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .character)).items.first).selection)
        service.completeDialog(dialog)
        #expect(service.dialogSubmissionError == "Attach or clear the current item before continuing.")
        #expect(service.pendingDialog?.id == dialog.id)
        let legacy = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString + ".ngv")
        defer { try? FileManager.default.removeItem(at: legacy) }
        _ = try ProjectScaffold.initProject(home: legacy, name: "Legacy", mode: .generic)
        _ = try ProjectIdentity.key(for: legacy)
        try JSONEncoder().encode(Timeline()).write(to: legacy.appendingPathComponent(Project.timelineFilename))
        let editor = EditorViewModel(agentService: service)
        defer { editor.releaseWorkingCopy() }
        editor.projectURL = legacy
        #expect(!editor.usesProductionPlanningV2)
        #expect(service.previousWorkflowMaterialScope(for: dialog) == nil)
        #expect(try JSONDecoder().decode(AgentDialogDraft.self, from: Data("{\"toggles\":{},\"direction\":\"\",\"customValues\":{},\"fileURLs\":[]}".utf8)).previousWorkflowSelection == nil)
    }

    @Test func workingCopyChangeInvalidatesIdentityIntakeContext() throws {
        let first = try makeFixture()
        let second = try makeFixture()
        defer { try? FileManager.default.removeItem(at: first.home); try? FileManager.default.removeItem(at: second.home) }
        let service = AgentService(refreshBackendStatusOnInit: false)
        let editor = EditorViewModel(agentService: service)
        defer { service.cancel(); editor.releaseWorkingCopy() }
        editor.projectURL = first.home
        let dialog = intake("character")
        try service.presentDialog(dialog)
        let session = service.currentSessionId
        let context = AgentService.IdentityIntakeContext(editor: editor, service: service)
        #expect(context.matches(service))
        editor.projectURL = second.home
        #expect(service.pendingDialog?.id == dialog.id && service.currentSessionId == session)
        #expect(!context.matches(service))
    }

    @Test func adoptedBibleAliasAndOriginalConfirmationOfferOneSubject() throws {
        let fixture = try makeFixture(bindCharacter: true)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let catalog = try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .character))
        let item = try #require(catalog.items.first)
        #expect(catalog.items.count == 1 && catalog.unavailableCount == 0)
        #expect(item.selection.expectedFiles.count == 1)
        #expect(item.selection.expectedFiles.map(\.relativePath) == ["pipeline/import/characters/lead-singer/original.png"])
        #expect(item.selection.expectedFiles.allSatisfy { $0.sha256 == FileDigest.sha256(of: fixture.image) })
        #expect(try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .character)).items.first?.id == item.id)
    }

    @Test func sameNameAndImageCannotMergeAnIndependentBibleSubject() throws {
        let fixture = try makeFixture(bindCharacter: true, independentCharacter: true)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let catalog = try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .character))
        #expect(catalog.items.count == 2 && catalog.unavailableCount == 0)
        #expect(Set(catalog.items.map(\.id)).count == 2)
        #expect(catalog.items.allSatisfy { $0.displayName == "Lead Singer" })
        #expect(catalog.items.contains { $0.selection.expectedFiles.map(\.relativePath) == ["pipeline/bible/independent.png"] })
    }

    @Test func aliasFusionKeepsADeclaredViewWithoutSharedConfirmationEvenForMatchingBytes() throws {
        let fixture = try makeFixture(bindCharacter: true, additionalView: true)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let catalog = try PipelinePreviousWorkflowMaterial.load(scope: scope(fixture, .character))
        let item = try #require(catalog.items.first)
        #expect(catalog.items.count == 1 && catalog.unavailableCount == 0)
        #expect(Set(item.selection.expectedFiles.map(\.relativePath)) == [
            "pipeline/import/characters/lead-singer/original.png", "pipeline/bible/additional-view.png"
        ])
        #expect(item.selection.expectedFiles.allSatisfy { $0.sha256 == FileDigest.sha256(of: fixture.image) })
    }

    @Test func matchingIdentityAndImageStillRequireTheActualAdoptionOrDirectOriginal() throws {
        let unbound = try makeFixture(bindCharacter: true, adoptCharacter: false)
        defer { try? FileManager.default.removeItem(at: unbound.home) }
        #expect(try PipelinePreviousWorkflowMaterial.load(scope: scope(unbound, .character)).items.count == 2)
        let direct = try makeFixture(bindCharacter: true, adoptCharacter: false, directReference: true)
        defer { try? FileManager.default.removeItem(at: direct.home) }
        let catalog = try PipelinePreviousWorkflowMaterial.load(scope: scope(direct, .character))
        #expect(catalog.items.count == 1 && catalog.unavailableCount == 0)
        #expect(catalog.items.first?.selection.expectedFiles.map(\.relativePath) == ["pipeline/import/characters/lead-singer/original.png"])
    }

    private struct Fixture {
        let home: URL
        let history: ProductionWorkflowRecoveryMigration.Intent
        let story: Data
        let image: Data
    }

    private func makeFixture(storyExtension: String = "md", bindCharacter: Bool = false,
                             adoptCharacter: Bool = true, independentCharacter: Bool = false,
                             directReference: Bool = false, additionalView: Bool = false) throws -> Fixture {
        Fixtures.installProcessExitDiagnostic()
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString + ".ngv")
        let root = try ProjectScaffold.initProject(home: home, name: "Fixture", mode: .generic)
        _ = try ProjectIdentity.key(for: home)
        try JSONEncoder().encode(Timeline()).write(to: home.appendingPathComponent(Project.timelineFilename))
        let treatment = Treatment(meta: try TreatmentMeta(project: "Fixture", version: 1, generated: "fixture", origin: .userSupplied,
            generator: "fixture", summaryOneline: "An empty courtyard", title: "Courtyard walk"),
            bodyMarkdown: "# Original treatment\nThe singer crosses the empty courtyard.\n")
        let story = Data(try treatment.serialized().utf8)
        let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6ITsAAAAASUVORK5CYII="))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("treatment"), withIntermediateDirectories: true)
        try story.write(to: root.appendingPathComponent("treatment/current.\(storyExtension)"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bible"), withIntermediateDirectories: true)
        try image.write(to: root.appendingPathComponent("bible/hero.png"))
        try image.write(to: root.appendingPathComponent("bible/location.png"))
        let original = "import/characters/lead-singer/original.png"
        if bindCharacter {
            let url = root.appendingPathComponent(original)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try image.write(to: url)
            try ConfirmedIdentityAssetStoreV1.recordIntake(role: .character, identityName: "Lead Singer",
                identitySlug: "lead-singer", paths: [original], dataRoot: root)
            if adoptCharacter {
                #expect(try ConfirmedIdentityAssetStoreV1.adopt(from: original, to: "bible/hero.png", dataRoot: root))
            }
        }
        var references = [directReference ? original : "bible/hero.png"]
        if additionalView {
            try image.write(to: root.appendingPathComponent("bible/additional-view.png"))
            references.append("bible/additional-view.png")
        }
        var characters = [try Character(id: bindCharacter ? "lead_singer" : "legacy_hero", name: "Lead Singer",
            visualPrompt: "A singer", referenceImages: references)]
        if independentCharacter {
            try image.write(to: root.appendingPathComponent("bible/independent.png"))
            characters.append(try Character(id: "independent_lead", name: "Lead Singer", visualPrompt: "Another singer",
                referenceImages: ["bible/independent.png"]))
        }
        let bible = try Bible(project: "Fixture", generated: "fixture", generator: "fixture",
            characters: characters,
            locations: [Location(id: "legacy_location", name: "Lead Singer", visualPrompt: "An empty courtyard", referenceImages: ["bible/location.png"])])
        try YAMLArtifactStore(dataRoot: root).save(bible, to: PipelineLayout.bibleFile)
        let history = try fixtureOperation("migration.preview") {
            try ProductionWorkflowRecoveryMigration.preview(projectURL: home, source: .core, target: .core)
        }
        try fixtureOperation("migration.archive") {
            try ProductionWorkflowRecoveryMigration.archiveAndReset(history, staging: home)
        }
        try fixtureOperation("migration.binding") {
            try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        }
        try fixtureOperation("migration.finish", fixture: .init(home: home, history: history, story: story, image: image)) {
            try ProductionWorkflowRecoveryMigration.finish(history, staging: home)
        }
        return .init(home: home, history: history, story: story, image: image)
    }

    private struct ArchiveFixtureFailure: Error {
        let stage: String
        let cause: String
        var evidence: String = ""
    }

    private func fixtureOperation<T>(_ stage: String, fixture: Fixture? = nil, _ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch {
            throw ArchiveFixtureFailure(stage: stage, cause: String(describing: error),
                evidence: fixture.map { archiveDiagnostic($0, staging: $0.home) } ?? "")
        }
    }

    private func archiveDiagnostic(_ fixture: Fixture, staging: URL) -> String {
        do {
            let root = staging.appendingPathComponent("pipeline")
            let directory = root.appendingPathComponent("migration-history")
            let archive = directory.appendingPathComponent(fixture.history.fingerprint)
            let history = try JSONDecoder().decode(ProductionWorkflowRecoveryMigration.History.self,
                from: Data(contentsOf: archive.appendingPathComponent("manifest.v1.json")))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard var identity = try JSONSerialization.jsonObject(with: encoder.encode(history.intent)) as? [String: Any] else {
                return "archive-diagnostic-error:intent-not-object"
            }
            identity.removeValue(forKey: "fingerprint")
            let fingerprint = FileDigest.sha256(of: try JSONSerialization.data(withJSONObject: identity,
                options: [.sortedKeys, .withoutEscapingSlashes]))
            let settings = try JSONSerialization.jsonObject(with: Data(contentsOf:
                archive.appendingPathComponent(ProjectPluginSettings.filename))) as? [String: Any]
            var failures: [String] = []
            for path in history.intent.archivePaths {
                guard let file = history.intent.files.first(where: { $0.path == path }) else {
                    failures.append("missing-inventory:" + path)
                    continue
                }
                do {
                    _ = try ProjectLocalFile.requireHash(file.sha256,
                        at: "migration-history/" + history.intent.fingerprint + "/" + path, dataRoot: root)
                } catch { failures.append(path + ":" + String(describing: error)) }
            }
            let projectID = ProjectIdentity.existingUUID(for: staging)
            let evidence: [String: Any] = [
                "directoryURLCanonical": directory.resolvingSymlinksInPath() == directory.standardizedFileURL,
                "directoryPathCanonical": directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path,
                "schema": history.schema, "completed": history.completed,
                "intentMatchesFixture": history.intent == fixture.history,
                "fingerprintMatches": fingerprint == history.intent.fingerprint,
                "namespaceIsUUID": UUID(uuidString: history.intent.namespaceID) != nil,
                "inventoryPathsUnique": Set(history.intent.files.map(\.path)).count == history.intent.files.count,
                "archivePathsUnique": Set(history.intent.archivePaths).count == history.intent.archivePaths.count,
                "settingsArchived": history.intent.archivePaths.contains(ProjectPluginSettings.filename),
                "projectIdentityMatches": projectID != nil && settings?["id"] as? String == projectID,
                "archiveHashFailures": failures
            ]
            return String(decoding: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), as: UTF8.self)
        } catch { return "archive-diagnostic-error:" + String(describing: error) }
    }

    private func scope(_ fixture: Fixture, _ role: PreviousWorkflowMaterialRole) -> PreviousWorkflowMaterialScope {
        .init(projectID: ProjectIdentity.existingUUID(for: fixture.home) ?? "missing", workingRoot: fixture.home,
            workingCopyKey: "fixture-key", workingCopyGeneration: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, dialogID: "intake-\(role.rawValue)", role: role)
    }

    private func intake(_ role: String) -> AgentDialog {
        AgentDialog(id: "history-\(role)", title: "Existing material", symbol: "doc", intro: nil, costHint: nil,
            confirmLabel: "Attach", textField: nil, sections: [],
            fileIntake: .init(accept: role == "script" ? ["text"] : ["image"], prompt: nil, allowsMultiple: role != "script",
                attachAs: role, namePrompt: role == "script" ? nil : "Name", required: false, completionLabel: "Done"), purpose: .workflowIntake)
    }
}
