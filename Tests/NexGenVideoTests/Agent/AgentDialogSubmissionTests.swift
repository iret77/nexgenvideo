import Testing
@testable import NexGenVideo

@Suite("Agent dialog submission")
@MainActor
struct AgentDialogSubmissionTests {
    @Test func generationIntentDoesNotRequireAComposerDialog() {
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
        service.pendingDialog = workflowDialog
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
}
