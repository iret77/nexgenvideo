import Testing
@testable import NexGenVideo

@Suite("AgentService.composedFunctionMessage")
struct AgentComposedFunctionMessageTests {

    @Test func fullInstructionWithNoteAppendsNoteAsTrailingLine() {
        let prompt = "Add captions to my timeline. Transcribe spoken audio."
        let out = AgentService.composedFunctionMessage(prompt: prompt, note: "Keep them short.")
        #expect(out == prompt + "\n\nKeep them short.")
    }

    @Test func fullInstructionWithEmptyNoteIsPromptAlone() {
        let prompt = "Organize my media into structured folders."
        #expect(AgentService.composedFunctionMessage(prompt: prompt, note: "   ") == prompt)
    }

    @Test func completionStyleStarterAbsorbsNoteInline() {
        // Trailing-space prompt completes into a single sentence, no paragraph break.
        let out = AgentService.composedFunctionMessage(
            prompt: "Generate an AI video of ",
            note: "a red car in the desert"
        )
        #expect(out == "Generate an AI video of a red car in the desert")
    }

    @Test func completionStyleStarterWithEmptyNoteTrimsTrailingSpace() {
        let out = AgentService.composedFunctionMessage(prompt: "Generate an AI video of ", note: "")
        #expect(out == "Generate an AI video of")
    }

    @Test func noteWhitespaceIsTrimmedBeforeComposing() {
        let out = AgentService.composedFunctionMessage(prompt: "Score my timeline.", note: "  moody, slow  ")
        #expect(out == "Score my timeline.\n\nmoody, slow")
    }
}
