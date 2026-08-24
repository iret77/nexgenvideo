import Testing
@testable import NexGenVideo

@Suite("Agent dialog submission")
@MainActor
struct AgentDialogSubmissionTests {
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
