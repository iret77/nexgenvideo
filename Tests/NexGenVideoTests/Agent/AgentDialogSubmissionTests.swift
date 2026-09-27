import Foundation
import Testing
@testable import NexGenVideo

@Suite("Agent dialog submission")
@MainActor
struct AgentDialogSubmissionTests {
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
                mcpSessionID: mcpSessionID
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
                mcpSessionID: mcpSessionID
            )
        )
        #expect(stale.isError)

        let replacement = await harness.executor.execute(
            name: "get_timeline",
            args: [:],
            origin: .embeddedRuntime(
                chatSessionID: owner.id,
                mcpSessionID: UUID()
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
