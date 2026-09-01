import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

/// The library picker (composer Reference button + file-intake card) offers exactly the assets a step
/// accepts, via one shared match. These cover that match — the logic that decides which assets appear
/// — and the composer-blocked gate that hides the picker while a card owns the dock.
@Suite("Library asset picker")
struct LibraryPickerTests {

    private func intake(_ accept: [String]) -> AgentDialog.FileIntake {
        AgentDialog.FileIntake(accept: accept, prompt: nil, allowsMultiple: false,
                               attachAs: nil, namePrompt: nil, required: false)
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/lib/\(name)") }

    @Test("an audio intake accepts audio files and rejects video and images")
    func audioAcceptMatchesAudioOnly() {
        let it = intake(["audio"])
        #expect(it.accepts(url("song.mp3")))
        #expect(it.accepts(url("track.wav")))
        #expect(it.accepts(url("clip.mp4")) == false)
        #expect(it.accepts(url("still.png")) == false)
    }

    @Test("an image intake accepts images and rejects audio")
    func imageAccept() {
        let it = intake(["image"])
        for ext in ProjectMediaExtensions.images {
            #expect(it.accepts(url("frame.\(ext)")))
        }
        for ext in ["avif", "bmp", "gif", "heif"] {
            #expect(!it.accepts(url("frame.\(ext)")))
        }
        #expect(it.accepts(url("song.mp3")) == false)
    }

    @Test("a text intake accepts every document format the app recognizes, not just .txt")
    func textAcceptsAllDocumentFormats() {
        let it = intake(["text"])
        // ClipType-backed, so .md/.markdown/.rtf/.fountain match regardless of system UTI registration.
        for ext in ClipType.documentExtensions {
            if !it.accepts(url("lyrics.\(ext)")) {
                Issue.record("text intake should accept .\(ext)")
            }
        }
        #expect(it.accepts(url("cover.png")) == false)
        #expect(it.accepts(url("song.mp3")) == false)
    }

    @Test("an empty accept list takes any file — the well places no restriction")
    func emptyAcceptTakesAnything() {
        let it = intake([])
        #expect(it.accepts(url("anything.xyz")))
        #expect(it.accepts(url("song.mp3")))
    }

    @Test("a bare extension token matches only that extension")
    func bareExtensionToken() {
        let it = intake(["mp3"])
        #expect(it.accepts(url("a.mp3")))
        #expect(it.accepts(url("a.wav")) == false)
    }

    @Test("the picker type tabs include a Text tab that filters document assets")
    func textTabCoversDocuments() {
        #expect(MentionTab.allCases.contains(.document))
        #expect(MentionTab.document.clipType == .document)
        #expect(MentionTab.document.label == "Text")
    }

    @Test("a document assigned as Lyrics is not offered as Existing story")
    @MainActor
    func assignedRoleDoesNotLeakIntoAnotherCard() {
        let lyrics = MediaAsset(
            id: "lyrics",
            url: url("lyrics.txt"),
            type: .document,
            name: "lyrics"
        )
        let story = AgentDialog.FileIntake(
            accept: ["text"],
            prompt: nil,
            allowsMultiple: false,
            attachAs: "script",
            namePrompt: nil,
            required: false
        )

        #expect(AgentDialogCard.isLibraryCandidate(
            lyrics,
            intake: story,
            assignedRoles: [:]
        ))
        #expect(!AgentDialogCard.isLibraryCandidate(
            lyrics,
            intake: story,
            assignedRoles: ["lyrics": "lyrics"]
        ))
        let lyricsIntake = AgentDialog.FileIntake(
            accept: ["text"],
            prompt: nil,
            allowsMultiple: false,
            attachAs: "lyrics",
            namePrompt: nil,
            required: false
        )
        #expect(AgentDialogCard.isLibraryCandidate(
            lyrics,
            intake: lyricsIntake,
            assignedRoles: ["lyrics": "lyrics"]
        ))
        #expect(AgentDialogCard.isLibraryCandidate(
            lyrics,
            intake: intake(["text"]),
            assignedRoles: ["lyrics": "lyrics"]
        ))
    }

    @Test("a selected library file shows its original filename, not its storage hash")
    @MainActor
    func selectedLibraryFileUsesOriginalFilename() {
        let hash = String(repeating: "4", count: 64)
        let storageURL = url("\(hash).mp3")
        let asset = MediaAsset(
            id: "track",
            url: storageURL,
            type: .audio,
            name: "Claude Mouse",
            originalFilename: "Claude Mouse Master.mp3"
        )

        #expect(AgentDialogCard.displayFilename(
            for: storageURL,
            libraryAssets: [asset]
        ) == "Claude Mouse Master.mp3")
    }

    @Test("workflow submission rejects an incompatible assigned library role")
    @MainActor
    func assignedRoleCannotBypassThePickerFilter() throws {
        let editor = EditorViewModel()
        let lyrics = MediaAsset(
            id: "lyrics",
            url: url("lyrics.txt"),
            type: .document,
            name: "lyrics"
        )
        editor.mediaAssets = [lyrics]
        editor.mediaManifest.intakeRoleByAssetID[lyrics.id] = "lyrics"
        let dialog = AgentDialog(
            id: "hardstep.brief.script",
            title: "Existing story",
            symbol: "doc.text",
            intro: nil,
            costHint: nil,
            confirmLabel: "Continue",
            textField: nil,
            sections: [],
            fileIntake: AgentDialog.FileIntake(
                accept: ["text"],
                prompt: nil,
                allowsMultiple: false,
                attachAs: "script",
                namePrompt: nil,
                required: false
            ),
            purpose: .workflowIntake
        )
        try editor.agentService.presentDialog(dialog)

        editor.agentService.submitDialog(
            dialog,
            result: AgentDialogResult(
                selectedLabels: [:],
                toggles: [:],
                direction: "",
                fileURLs: [lyrics.url]
            )
        )

        #expect(editor.agentService.pendingDialog?.id == dialog.id)
        #expect(editor.agentService.dialogSubmissionError?.contains(
            "already assigned as lyrics"
        ) == true)
    }

    @Test("dialog library results are searchable and height bounded")
    func dialogLibraryIsBounded() throws {
        let source = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/AgentDialogCard.swift"
        )
        let start = try #require(source.range(
            of: "private func libraryPicker"
        ))
        let end = try #require(source.range(
            of: "@MainActor",
            range: start.upperBound..<source.endIndex
        ))
        let picker = source[start.lowerBound..<end.lowerBound]

        #expect(picker.contains("showsSearch: true"))
        #expect(picker.contains("scrollHeight: AppTheme.ComponentSize.agentAssetPickerHeight"))
    }
}

@MainActor
@Suite("Composer blocked state")
struct ComposerBlockedTests {

    @Test("a pending dialog blocks the composer, so the Reference control and Send hide")
    func pendingDialogBlocksComposer() throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        #expect(service.isComposerBlocked == false)

        try service.presentDialog(AgentDialog(
            id: "t", title: "Track", symbol: "waveform", intro: nil, costHint: nil,
            confirmLabel: "Attach", textField: nil, sections: []))
        #expect(service.isComposerBlocked)
        let messageCount = service.messages.count
        service.send(text: "Bypass the card", mentions: [], hidden: true)
        #expect(service.messages.count == messageCount)
        #expect(service.streamError == nil)

        service.abandonDialog()
        #expect(service.isComposerBlocked == false)
    }
}
