import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Agent dialog submission")
@MainActor
struct AgentDialogSubmissionTests {
    @Test(arguments: [0, 1, 2, 3])
    func failedIntakeCompletionRetainsDecisionInputsUntilAbandoned(input: Int) throws {
        let service = AgentService()
        let dialog = AgentDialog(
            id: "identity-intake", title: "Character 1", symbol: "person",
            intro: nil, costHint: nil, confirmLabel: "Attach", textField: nil,
            sections: [], fileIntake: AgentDialog.FileIntake(
                accept: ["image"], prompt: nil, allowsMultiple: true,
                attachAs: "character", namePrompt: "Character name",
                required: false, completionLabel: "Done"
            ), purpose: .workflowIntake
        )
        try service.presentDialog(dialog)
        let draft = AgentDialogDraft(
            toggles: ["reference": false], direction: "Lead singer",
            customValues: ["style": "Hand drawn"],
            fileURLs: [URL(fileURLWithPath: "/tmp/lead-singer.png")]
        )
        let candidate: AgentDialogDraft = switch input {
        case 0: AgentDialogDraft(direction: "Unfinished location")
        case 1: AgentDialogDraft(fileURLs: draft.fileURLs)
        case 2: draft
        default: AgentDialogDraft(toggles: draft.toggles, customValues: draft.customValues)
        }
        service.dialogDraft = candidate
        service.dialogChoiceSelections = ["style": ["custom"]]
        #expect(service.dialogSubmissionError == nil && service.submittingDialogID == nil)
        service.completeDialog(dialog)
        #expect(service.pendingDialog?.id == dialog.id)
        #expect(service.dialogSubmissionError == (input == 3
            ? "The project is unavailable. Reopen it and try again."
            : "Attach or clear the current item before continuing."))
        #expect(service.dialogDraft == candidate)
        #expect(service.dialogChoiceSelections == ["style": ["custom"]])
        #expect(service.submittingDialogID == nil && service.messages.isEmpty)
        service.abandonDialog()
        #expect(service.dialogDraft == AgentDialogDraft())
        #expect(service.dialogChoiceSelections.isEmpty)
    }

    @Test func malformedDecisionFieldsNeverBecomeAConfirmablePartialDialog() {
        let invalid: [[String: Any]] = [
            ["title": "Choose", "textField": [:], "sections": "unsupported"],
            ["title": "Choose", "textField": "unsupported", "sections": []],
            ["title": "Choose", "textField": [:], "workflowDecision": "future_decision"],
            ["title": "Choose", "textField": [:], "projection": ["timelineRanges": "unsupported"]],
            ["title": "Choose", "textField": [:], "unknownControl": true],
            ["title": "Choose", "fileIntake": ["accept": [3]]],
            ["title": "Choose", "textField": ["multiline": 1]],
            ["title": "Choose", "sections": [
                ["id": "same", "type": "toggle"], ["id": "same", "type": "toggle"],
            ]],
            ["title": "Choose", "sections": [["type": "choices", "options": [
                ["id": "same", "label": "One"], ["id": "same", "label": "Two"],
            ]]]],
            ["title": "Choose", "sections": [["type": "choices", "options": [
                ["label": "One", "rangeRef": "missing"], ["label": "Two"],
            ]]]],
        ]
        for args in invalid {
            #expect(throws: ToolError.self) { try AgentDialog.parse(args) }
        }
    }

    @Test func timelineRangesRequireExactNonnegativeRepresentableFrames() throws {
        for start in [true, 0.5, -1, Double.infinity, Double.nan, 1e100] as [Any] {
            #expect(throws: ToolError.self) {
                try AgentDialog.parse(["title": "Range", "textField": [:],
                    "projection": ["timelineRanges": [["startFrame": start, "endFrame": 20]]]])
            }
        }
        let dialog = try AgentDialog.parse(["title": "Range", "textField": [:],
            "projection": ["timelineRanges": [["startFrame": 10, "endFrame": 20]]]])
        #expect(dialog.projection.timelineRanges.first?.startFrame == 10)
        #expect(dialog.projection.timelineRanges.first?.endFrame == 20)
    }

    @Test func storyboardModeUsesHostOwnedUnambiguousLabels() throws {
        let dialog = try AgentDialog.parse([
            "title": "Storyboard setup",
            "workflowDecision": "storyboard_mode",
            "sections": [[
                "id": "storyboard_mode",
                "label": "Who writes the step sequences?",
                "type": "choices",
                "allowsCustom": true,
                "options": [
                    ["id": "agent_created", "label": "I write them"],
                    ["id": "user_supplied", "label": "I supply it"],
                ],
            ]],
        ])

        try PipelineAgentHarness.validateStoryboardModeDialog(dialog)
        let section = try #require(dialog.sections.first)
        #expect(section.label == "How should the step sequences be created?")
        guard case .choices(let options, _) = section.kind else {
            Issue.record("Expected Storyboard mode choices")
            return
        }
        #expect(options.map(\.shortLabel) == [
            "Create sequences for me",
            "I'll provide sequences",
        ])
        #expect(try PipelineAgentHarness.resolveStoryboardCreationPath(
            dialog,
            result: AgentDialogResult(
                selectedLabels: [:],
                toggles: [:],
                direction: ""
            ),
            selectedOptionIDs: ["storyboard_mode": ["agent_created"]]
        ) == .agentCreated)
    }

    @Test func agentCreatedStoryboardRejectsFurtherQuestions() throws {
        let dialog = try AgentDialog.parse([
            "title": "Choose the sheet scope",
            "sections": [[
                "id": "scope",
                "label": "How many sheets?",
                "type": "choices",
                "options": [
                    ["id": "lean", "label": "Lean"],
                    ["id": "full", "label": "Full"],
                ],
            ]],
        ])

        #expect(throws: ToolError.self) {
            try PipelineAgentHarness.guardStoryboardDecision(
                dialog,
                hasStoryboard: false,
                creationPath: .agentCreated,
                inputReceived: false
            )
        }
        #expect(throws: ToolError.self) {
            try PipelineAgentHarness.guardStoryboardDecision(
                dialog,
                hasStoryboard: true,
                creationPath: nil,
                inputReceived: false
            )
        }
    }

    @Test func userSuppliedStoryboardAcceptsOneBoundedTextIntake() throws {
        let intake = try AgentDialog.parse([
            "title": "Provide storyboard sequences",
            "workflowDecision": "storyboard_input",
            "textField": [
                "placeholder": "Paste the step sequences",
                "multiline": true,
            ],
        ])
        try PipelineAgentHarness.guardStoryboardDecision(
            intake,
            hasStoryboard: false,
            creationPath: .userSupplied,
            inputReceived: false
        )

        #expect(throws: ToolError.self) {
            try PipelineAgentHarness.guardStoryboardDecision(
                intake,
                hasStoryboard: false,
                creationPath: .userSupplied,
                inputReceived: true
            )
        }
    }

    @Test func treatmentStartsWithAgentCreationAsARealChoice() throws {
        let dialog = try AgentDialog.parse([
            "title": "Choose how to develop the treatment",
            "workflowDecision": "treatment_path",
            "sections": [[
                "id": "treatment_path",
                "label": "Who develops the treatment?",
                "type": "choices",
                "allowsCustom": true,
                "options": [
                    ["id": "agent_proposal", "label": "Create 2–3 proposals for me"],
                    ["id": "user_supplied", "label": "I will supply a treatment"],
                ],
            ]],
        ])

        try PipelineAgentHarness.validateTreatmentPathDialog(dialog)
        #expect(try PipelineAgentHarness.resolveTreatmentCreationPath(
            dialog,
            result: AgentDialogResult(
                selectedLabels: [:],
                toggles: [:],
                direction: ""
            ),
            selectedOptionIDs: ["treatment_path": ["agent_proposal"]]
        ) == .agentProposal)
    }

    @Test func treatmentCannotStartWithAForcedUploadDialog() throws {
        let forcedUpload = try AgentDialog.parse([
            "title": "Hand me your treatment",
            "workflowDecision": "treatment_path",
            "textField": [
                "placeholder": "Paste your treatment here",
                "multiline": true,
            ],
            "sections": [[
                "id": "treatment_path",
                "label": "How are you giving it to me?",
                "type": "choices",
                "allowsCustom": true,
                "options": [
                    ["id": "pasted", "label": "Pasted below"],
                    ["id": "file", "label": "I'll drop a file"],
                ],
            ]],
        ])

        #expect(throws: ToolError.self) {
            try PipelineAgentHarness.validateTreatmentPathDialog(forcedUpload)
        }
    }

    @Test func rejectedDialogLeavesNoPendingDecisionAndAllowsARepairedRequest() async throws {
        let harness = ToolHarness()
        harness.editor.agentService.newChat()
        let sessionID = try #require(harness.editor.agentService.currentSessionId)
        let rejected = await harness.executor.execute(name: "show_dialog",
            args: ["title": "Choose", "textField": [:], "sections": "unsupported"],
            origin: .inAppChat(sessionID: sessionID))
        #expect(rejected.isError)
        #expect(harness.editor.agentService.pendingDialog == nil)

        let repaired = await harness.executor.execute(name: "show_dialog",
            args: ["title": "Describe the correction", "textField": ["placeholder": "Correction", "multiline": true]],
            origin: .inAppChat(sessionID: sessionID))
        #expect(!repaired.isError)
        #expect(repaired.turnDisposition == .suspendTurn)
        #expect(harness.editor.agentService.pendingDialog?.title == "Describe the correction")
    }

    @Test func agentDialogSuspendsItsOwningTurn() async throws {
        let harness = ToolHarness()
        harness.editor.agentService.newChat()
        let sessionID = try #require(harness.editor.agentService.currentSessionId)

        let result = await harness.executor.execute(
            name: "show_dialog",
            args: [
                "title": "Choose",
                "sections": [[
                    "id": "choice",
                    "label": "Choice",
                    "type": "choices",
                    "options": [
                        ["id": "continue", "label": "Continue"],
                        ["id": "revise", "label": "Revise"],
                    ],
                ]],
            ],
            origin: .inAppChat(sessionID: sessionID)
        )

        #expect(!result.isError)
        #expect(result.turnDisposition == .suspendTurn)
        #expect(harness.editor.agentService.pendingDialog?.title == "Choose")
    }

    @Test func imageChoicesRequireMediaRefsForEveryOption() throws {
        #expect(throws: ToolError.self) {
            try AgentDialog.parse([
                "title": "Choose the anchor",
                "sections": [[
                    "id": "anchor",
                    "label": "Which image becomes the anchor?",
                    "type": "choices",
                    "options": [
                        ["id": "dusk", "label": "Dusk street", "mediaRef": "image-a"],
                        ["id": "studio", "label": "Studio portrait"],
                    ],
                ]],
            ])
        }
    }

    @Test func imageChoicesResolveToUsableLibraryImages() async throws {
        let harness = ToolHarness()
        harness.editor.agentService.newChat()
        let sessionID = try #require(harness.editor.agentService.currentSessionId)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        let firstURL = directory.appendingPathComponent("dusk-street.png")
        let secondURL = directory.appendingPathComponent("studio-portrait.png")
        try Data([0]).write(to: firstURL)
        try Data([0]).write(to: secondURL)
        harness.editor.mediaAssets = [
            MediaAsset(id: firstID, url: firstURL, type: .image, name: "Dusk street"),
            MediaAsset(id: secondID, url: secondURL, type: .image, name: "Studio portrait"),
        ]

        let result = await harness.executor.execute(
            name: "show_dialog",
            args: [
                "title": "Choose the anchor",
                "sections": [[
                    "id": "anchor",
                    "label": "Which image becomes the anchor?",
                    "type": "choices",
                    "options": [
                        ["id": "dusk", "label": "Dusk street", "mediaRef": String(firstID.prefix(8))],
                        ["id": "studio", "label": "Studio portrait", "mediaRef": String(secondID.prefix(8))],
                    ],
                ]],
            ],
            origin: .inAppChat(sessionID: sessionID)
        )

        #expect(!result.isError)
        let pending = try #require(harness.editor.agentService.pendingDialog)
        guard case .choices(let options, _) = pending.sections[0].kind else {
            Issue.record("Expected image choices")
            return
        }
        #expect(options.compactMap(\.mediaRef) == [firstID, secondID])
    }

    @Test func imageChoicesRejectNonImageMedia() async throws {
        let harness = ToolHarness()
        harness.editor.agentService.newChat()
        let sessionID = try #require(harness.editor.agentService.currentSessionId)
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        harness.editor.mediaAssets = [
            MediaAsset(id: firstID, url: URL(fileURLWithPath: "/tmp/one.mov"), type: .video, name: "One"),
            MediaAsset(id: secondID, url: URL(fileURLWithPath: "/tmp/two.mov"), type: .video, name: "Two"),
        ]

        let result = await harness.executor.execute(
            name: "show_dialog",
            args: [
                "title": "Choose the anchor",
                "sections": [[
                    "id": "anchor",
                    "label": "Which image becomes the anchor?",
                    "type": "choices",
                    "options": [
                        ["id": "one", "label": "One", "mediaRef": firstID],
                        ["id": "two", "label": "Two", "mediaRef": secondID],
                    ],
                ]],
            ],
            origin: .inAppChat(sessionID: sessionID)
        )

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("not an image"))
    }

    @Test func internalIdentifierQuestionnairesAreRecognizedInAnySpelling() {
        func question(_ label: String, optionIDs: [String] = ["a", "b"]) -> [String: Any] {
            [
                "title": "Shot list",
                "sections": [[
                    "id": "choice",
                    "label": label,
                    "type": "choices",
                    "options": optionIDs.map { ["id": $0, "label": $0.capitalized] },
                ]],
            ]
        }
        for variant in [
            question("Which semantic_job_id should the location use?"),
            question("Enter valid Semantic Job ID values for character, location and prop"),
            question("semanticJobId for the prop"),
            question("Which INPUT_SLOT_ID fits?"),
            question("Pick the inputSlot"),
            question("Which preservation scope ids apply?"),
            question("Which role?", optionIDs: [
                CoreReferenceSemanticJobIDV1.referenceAnchor, "core.style-reference",
            ]),
            question("Which slot?", optionIDs: ["core.input.reference-image", "reference.image.anchor"]),
            question("Use core.reference_anchor for the street?"),
        ] {
            #expect(ToolExecutor.internalIdentifierQuestion(in: variant, afterFailedWrite: false) != nil)
        }
        let modeIDField = question("Mode", optionIDs: ["mode_id", "other"])
        #expect(ToolExecutor.internalIdentifierQuestion(in: modeIDField, afterFailedWrite: true) != nil)
        #expect(ToolExecutor.internalIdentifierQuestion(in: modeIDField, afterFailedWrite: false) == nil)

        for creative in [
            question("Which palette carries the chorus?", optionIDs: ["dusk", "neon"]),
            question("Which project mode fits the song: beat or section?", optionIDs: ["beat", "section"]),
            question("Which reference image anchors the hero's look?", optionIDs: ["portrait", "profile"]),
            question("Keep the core style of the opening?", optionIDs: ["keep", "change"]),
        ] {
            #expect(ToolExecutor.internalIdentifierQuestion(in: creative, afterFailedWrite: true) == nil)
        }
    }

    @Test func showDialogRefusesIdentifierQuestionnairesAndKeepsCreativeQuestions() async throws {
        let harness = ToolHarness()
        harness.editor.agentService.newChat()
        let sessionID = try #require(harness.editor.agentService.currentSessionId)
        let failedWrite = await harness.executor.execute(
            name: "write_shotlist",
            args: [:],
            origin: .inAppChat(sessionID: sessionID)
        )
        #expect(failedWrite.isError)

        let questionnaire = await harness.executor.execute(
            name: "show_dialog",
            args: [
                "title": "Shot list — execution-plan blocker",
                "sections": [[
                    "id": "values",
                    "label": "Enter valid semantic job ID values for character, location and prop",
                    "type": "choices",
                    "options": [
                        ["id": "retry", "label": "Keep trying values"],
                        ["id": "core.reference-anchor", "label": "core.reference-anchor"],
                    ],
                ]],
            ],
            origin: .inAppChat(sessionID: sessionID)
        )
        #expect(questionnaire.isError)
        #expect(ToolHarness.textOf(questionnaire).contains("not a user decision"))
        #expect(ToolHarness.textOf(questionnaire).contains("execution_input_contract"))
        #expect(harness.editor.agentService.pendingDialog == nil)

        let renamedField = await harness.executor.execute(
            name: "show_dialog",
            args: [
                "title": "Shot list",
                "sections": [[
                    "id": "inputSlotId",
                    "label": "Value",
                    "type": "choices",
                    "options": [
                        ["id": "first", "label": "First"],
                        ["id": "second", "label": "Second"],
                    ],
                ]],
            ],
            origin: .inAppChat(sessionID: sessionID)
        )
        #expect(renamedField.isError)
        #expect(harness.editor.agentService.pendingDialog == nil)

        let creative = await harness.executor.execute(
            name: "show_dialog",
            args: [
                "title": "Chorus look",
                "sections": [[
                    "id": "palette",
                    "label": "Which palette carries the chorus?",
                    "type": "choices",
                    "options": [
                        ["id": "dusk", "label": "Dusk blue"],
                        ["id": "neon", "label": "Neon red"],
                    ],
                ]],
            ],
            origin: .inAppChat(sessionID: sessionID)
        )
        #expect(!creative.isError)
        #expect(creative.turnDisposition == .suspendTurn)
        #expect(harness.editor.agentService.pendingDialog?.title == "Chorus look")
    }

    @Test func externalMCPDialogCannotCaptureAnInAppChat() async {
        let harness = ToolHarness()
        harness.editor.agentService.newChat()
        let chatID = harness.editor.agentService.currentSessionId

        let result = await harness.executor.execute(
            name: "show_dialog",
            args: [
                "title": "Choose",
                "sections": [[
                    "id": "choice",
                    "label": "Choice",
                    "type": "choices",
                    "options": [
                        ["id": "continue", "label": "Continue"],
                        ["id": "revise", "label": "Revise"],
                    ],
                ]],
            ],
            origin: .externalMCP(sessionID: UUID())
        )

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("cannot own an in-app dialog"))
        #expect(harness.editor.agentService.pendingDialog == nil)
        #expect(harness.editor.agentService.currentSessionId == chatID)
        #expect(harness.editor.agentService.messages.isEmpty)
    }

    @Test func embeddedDialogAnswerReturnsToItsExactChat() async throws {
        let harness = ToolHarness()
        let editor = harness.editor
        let service = editor.agentService
        let owner = ChatSession()
        let unrelated = ChatSession()
        service.sessions = [owner, unrelated]
        service.currentSessionId = unrelated.id
        service.messages = []
        let dialog = AgentDialog(
            id: "owned-dialog",
            title: "Choose",
            symbol: "questionmark",
            intro: nil,
            costHint: nil,
            confirmLabel: "Continue",
            textField: nil,
            sections: []
        )
        let mcpSessionID = UUID()
        try service.presentDialog(
            dialog,
            origin: .embeddedRuntime(
                chatSessionID: owner.id,
                runtimeGenerationID: mcpSessionID
            )
        )

        service.submitDialog(
            dialog,
            result: AgentDialogResult(
                selectedLabels: [:],
                toggles: [:],
                direction: ""
            )
        )

        #expect(service.currentSessionId == owner.id)
        #expect(service.pendingDialog == nil)
        #expect(service.sessions.first(where: { $0.id == unrelated.id })?.messages.isEmpty == true)

        let stale = await harness.executor.execute(
            name: "get_timeline",
            args: [:],
            origin: .embeddedRuntime(
                chatSessionID: owner.id,
                runtimeGenerationID: mcpSessionID
            )
        )
        #expect(stale.isError)

        let replacement = await harness.executor.execute(
            name: "get_timeline",
            args: [:],
            origin: .embeddedRuntime(
                chatSessionID: owner.id,
                runtimeGenerationID: UUID()
            )
        )
        #expect(!replacement.isError)
    }

    @Test func generationIntentDoesNotRequireAComposerDialog() throws {
        let service = AgentService()
        let dialog = AgentDialog(
            id: "generation",
            title: "Shape the music",
            symbol: "music.note",
            intro: nil,
            costHint: nil,
            confirmLabel: "Generate",
            textField: nil,
            sections: [],
            purpose: .generationIntent
        )
        var received: [String] = []
        service.onGenerationDialogIntent = { received.append($0) }
        let result = AgentDialogResult(
            selectedLabels: [:],
            toggles: [:],
            direction: "Warm analogue synth"
        )

        service.submitDialog(dialog, result: result)

        #expect(received == ["Warm analogue synth"])
        #expect(service.submittingDialogID == nil)
        #expect(service.pendingDialog == nil)

        service.onGenerationDialogIntent = nil
        service.submitDialog(dialog, result: result)
        #expect(received == ["Warm analogue synth"])

        let workflowDialog = AgentDialog(
            id: "workflow",
            title: "Track",
            symbol: "waveform",
            intro: nil,
            costHint: nil,
            confirmLabel: "Attach track",
            textField: nil,
            sections: [],
            fileIntake: AgentDialog.FileIntake(
                accept: ["image"],
                prompt: nil,
                allowsMultiple: true,
                attachAs: "character",
                namePrompt: "Character name",
                required: false,
                completionLabel: "Done"
            ),
            purpose: .workflowIntake
        )
        try service.presentDialog(workflowDialog)
        service.submitDialog(
            workflowDialog,
            result: AgentDialogResult(selectedLabels: [:], toggles: [:], direction: "")
        )
        #expect(service.dialogSubmissionError == "Choose at least one reference image.")
        service.onGenerationDialogIntent = { received.append($0) }
        service.submitDialog(dialog, result: result)

        #expect(received.count == 2)
        #expect(service.pendingDialog?.id == workflowDialog.id)
        #expect(service.submittingDialogID == nil)
        #expect(service.dialogSubmissionError == "Choose at least one reference image.")
    }

    @Test func loadingAnotherProjectAbandonsThePreviousDialog() throws {
        let service = AgentService()
        try service.presentDialog(AgentDialog(
            id: "old-project-dialog",
            title: "Track",
            symbol: "waveform",
            intro: nil,
            costHint: nil,
            confirmLabel: "Attach",
            textField: nil,
            sections: []
        ))

        service.loadSessions(from: nil)

        #expect(service.pendingDialog == nil)
        #expect(!service.isComposerBlocked)
    }

    @Test func newChatAbandonsOnlySessionOwnedDialogs() throws {
        let service = AgentService()
        try service.presentDialog(AgentDialog(
            id: "clarification",
            title: "Choose",
            symbol: "questionmark",
            intro: nil,
            costHint: nil,
            confirmLabel: "Continue",
            textField: nil,
            sections: []
        ))

        service.newChat()
        #expect(service.pendingDialog == nil)

        let workflow = AgentDialog(
            id: "workflow",
            title: "Track",
            symbol: "waveform",
            intro: nil,
            costHint: nil,
            confirmLabel: "Attach",
            textField: nil,
            sections: [],
            purpose: .workflowIntake
        )
        try service.presentDialog(workflow)

        service.newChat()
        #expect(service.pendingDialog?.id == workflow.id)
    }
}
