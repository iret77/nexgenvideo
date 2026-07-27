import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Dialog choice transcript records")
struct DialogChoiceRecordTests {
    private func setupDialog() -> AgentDialog {
        AgentDialog(
            id: "setup",
            title: "Lock project setup",
            symbol: "lock",
            intro: nil,
            costHint: nil,
            confirmLabel: "Lock",
            textField: nil,
            sections: [
                AgentDialog.Section(
                    id: "rhythm",
                    label: "Cut rhythm — how tightly the edit follows the music",
                    kind: .choices(options: [
                        .init(id: "phrase", label: "Phrase — cuts on musical phrases"),
                        .init(id: "beat", label: "Beat — cuts on every beat"),
                    ], multiSelect: false)
                ),
                AgentDialog.Section(
                    id: "source",
                    label: "How shots are sourced",
                    kind: .choices(options: [
                        .init(id: "generated", label: "Generated — AI renders every shot"),
                        .init(id: "imported", label: "Imported — use existing footage"),
                    ], multiSelect: false)
                ),
            ]
        )
    }

    @Test("Long questions and option explanations compact to the owner-approved summary")
    func compactSummary() {
        let response = AgentService.dialogResponse(
            from: setupDialog(),
            result: AgentDialogResult(
                selectedLabels: [
                    "rhythm": ["Phrase — cuts on musical phrases"],
                    "source": ["Generated — AI renders every shot"],
                ],
                toggles: [:],
                direction: ""
            )
        )

        #expect(response.presentation.choiceRecord?.summary == "Cut rhythm: Phrase · Shots: Generated")
        #expect(response.presentation.typedText == nil)
        #expect(response.agentText.contains("Phrase — cuts on musical phrases"))
    }

    @Test("Typed direction remains separate user prose")
    func typedDirectionIsSeparate() {
        let response = AgentService.dialogResponse(
            from: setupDialog(),
            result: AgentDialogResult(
                selectedLabels: ["rhythm": ["Phrase"]],
                toggles: [:],
                direction: "Keep the chorus restless."
            )
        )

        #expect(response.presentation.choiceRecord?.summary == "Cut rhythm: Phrase")
        #expect(response.presentation.typedText == "Keep the chorus restless.")
        #expect(response.presentation.choiceRecord?.summary.contains("Dialog") == false)
    }

    @Test("A pure text dialog produces no synthetic choice record")
    func textOnlyHasNoChoiceRecord() {
        let dialog = AgentDialog(
            id: "note",
            title: "Add direction",
            symbol: "text.cursor",
            intro: nil,
            costHint: nil,
            confirmLabel: "Continue",
            textField: .init(placeholder: "Direction", multiline: false),
            sections: []
        )
        let response = AgentService.dialogResponse(
            from: dialog,
            result: AgentDialogResult(selectedLabels: [:], toggles: [:], direction: "Use hard cuts.")
        )

        #expect(response.presentation.choiceRecord == nil)
        #expect(response.presentation.typedText == "Use hard cuts.")
    }

    @Test("A failed file import is not shown as an attached user choice")
    func failedFileIsNotPresentedAsAttached() {
        let dialog = AgentDialog(
            id: "asset",
            title: "Choose footage",
            symbol: "film",
            intro: nil,
            costHint: nil,
            confirmLabel: "Continue",
            textField: nil,
            sections: []
        )
        let result = AgentDialogResult(
            selectedLabels: [:],
            toggles: [:],
            direction: "",
            fileURLs: [URL(fileURLWithPath: "/missing/clip.mp4")]
        )

        let response = AgentService.dialogResponse(
            from: dialog,
            result: result,
            presentedAttachmentNames: [],
            userNotice: "clip.mp4 couldn't be copied into the project."
        )

        #expect(response.presentation.choiceRecord == nil)
        #expect(response.presentation.notice?.contains("couldn't be copied") == true)
        #expect(response.agentText.contains("clip.mp4") == false)
    }

    @Test("Review accept is a compact control record, not generated user prose")
    func reviewAcceptControlRecord() {
        let turn = ReviewPanelView.acceptTurn(frameName: "frame-03", shotId: "S012")

        #expect(turn.command == "For shot S012, use the frame candidate \u{201C}frame-03\u{201D} as the selected keyframe.")
        #expect(turn.presentation.choiceRecord?.summary == "Keyframe: frame-03 · Shot: S012")
        #expect(turn.presentation.typedText == nil)
    }

    @Test("Review regenerate keeps the note as separate user text")
    func reviewRegenerateSeparatesNote() {
        let command = "Regenerate S012. Note: Keep the silhouette."
        let turn = ReviewPanelView.regenerateTurn(
            command: command,
            frameName: "frame-03",
            shotId: "S012",
            reason: "Composition",
            note: "Keep the silhouette."
        )

        #expect(turn.command == command)
        #expect(turn.presentation.choiceRecord?.summary.contains("Action: Regenerate") == true)
        #expect(turn.presentation.typedText == "Keep the silhouette.")
    }

    @Test("Apply Brief is shown as a control record")
    func applyBriefControlRecord() {
        let command = "Update brief fields and rerun the brief phase."
        let turn = StoryPanelView.applyBriefTurn(command)

        #expect(turn.command == command)
        #expect(turn.presentation.choiceRecord?.summary == "Brief: Changes applied")
        #expect(turn.presentation.typedText == nil)
    }

    @Test("Story prose hides its generated command and preserves the typed text")
    func storyProseIsSeparate() {
        let command = "Revise the treatment: Make it colder. Then present it for review."
        let turn = StoryPanelView.proseTurn(
            command: command,
            action: "Revise treatment",
            typedText: "Make it colder."
        )

        #expect(turn.command == command)
        #expect(turn.presentation.choiceRecord == nil)
        #expect(turn.presentation.typedText == "Make it colder.")
    }
}
