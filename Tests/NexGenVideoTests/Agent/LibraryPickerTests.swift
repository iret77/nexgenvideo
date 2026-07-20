import Foundation
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
        #expect(it.accepts(url("frame.png")))
        #expect(it.accepts(url("frame.jpg")))
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
}

@MainActor
@Suite("Composer blocked state")
struct ComposerBlockedTests {

    @Test("a pending dialog blocks the composer, so the Reference control and Send hide")
    func pendingDialogBlocksComposer() {
        let editor = EditorViewModel()
        let service = editor.agentService
        #expect(service.isComposerBlocked == false)

        service.pendingDialog = AgentDialog(
            id: "t", title: "Track", symbol: "waveform", intro: nil, costHint: nil,
            confirmLabel: "Attach", textField: nil, sections: [])
        #expect(service.isComposerBlocked)

        service.pendingDialog = nil
        #expect(service.isComposerBlocked == false)
    }
}
