import Foundation
import Testing
@testable import NexGenVideo

@Suite("AgentMessage.hidden Codable")
struct AgentMessageHiddenCodableTests {

    /// Back-compat: a saved session predates `hidden`, so its JSON has no such key. Decoding MUST
    /// succeed (hidden=false) — otherwise the whole session fails to decode and its history is lost.
    @Test func legacyMessageWithoutHiddenKeyDecodes() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","role":"user","blocks":[{"kind":"text","text":"hi"}],"mentions":[]}"#
        let msg = try JSONDecoder().decode(AgentMessage.self, from: Data(legacy.utf8))
        #expect(msg.hidden == false)
        #expect(msg.role == .user)
    }

    @Test func hiddenRoundTrips() throws {
        let original = AgentMessage(role: .user, blocks: [.text("kickoff")], hidden: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)
        #expect(decoded.hidden)
    }
}

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
