import Foundation
import Testing
@testable import NexGenVideo

/// #244 — NGV works with whatever providers the user has. fal used to host references even for calls
/// that never touched fal, which quietly made a fal key mandatory for Runway. These pin the parts
/// that are pure; the wire mechanics are verified live against the real API, not mocked here.
@Suite("fal-free video (#244)")
@MainActor
struct FalFreeVideoTests {

    // MARK: - Hosting strategy

    @Test("a Runway model hosts its references on Runway, not on fal")
    func runwayHostsItsOwn() {
        // The whole defect in one assertion: this used to be `.fal`, so a Runway-only user hit
        // "Add a fal.ai API key" on every image-to-video and every restyle.
        #expect(GenerationService.referenceHosting(modelId: "runway/gen4.5") == .runway)
        #expect(GenerationService.referenceHosting(modelId: "runway/gen4_turbo") == .runway)
        #expect(GenerationService.referenceHosting(modelId: "runway/aleph2") == .runway)
    }

    @Test("a fal model still hosts on fal")
    func falKeepsItsOwn() {
        #expect(GenerationService.referenceHosting(modelId: "fal-ai/some-unknown-video") == .fal)
    }

    @Test("a Google model keeps taking its bytes inline")
    func googleStaysInline() {
        #expect(GenerationService.referenceHosting(modelId: "google/gemini-3-pro-image") == .inline)
    }

    @Test("Marble's reference was never hosted either — it base64s a local path")
    func marbleIsInline() {
        // It only ever reached the fal branch because the submission hands the local path in
        // pre-uploaded; that path was then persisted as though it were a hosted URL.
        #expect(GenerationService.referenceHosting(modelId: "marble/marble-1.1") == .inline)
    }

    @Test("hosting agrees with dispatch for every model id")
    func hostingAgreesWithDispatch() {
        // The two must never disagree: hosting decides WHERE the bytes land, dispatch decides WHO is
        // handed them. `GenerationProvider.servicing` cannot serve this — with no bindings it answers
        // .fal while dispatch answers nominalProvider, which would host a Runway reference on fal and
        // then pass a fal URL to Runway. Both now read the same resolution.
        for id in ["runway/gen4.5", "runway/aleph2", "google/gemini-3-pro-image",
                   "fal-ai/whatever", "marble/marble-1.1"] {
            let provider = GenerationService.dispatchTarget(modelId: id).provider
            let hosting = GenerationService.referenceHosting(modelId: id)
            switch provider {
            case .google, .marble: #expect(hosting == .inline)
            case .runway: #expect(hosting == .runway)
            default: #expect(hosting == .fal)
            }
        }
    }

    @Test("hosting follows the provider itself, so one resolution can serve both steps")
    func hostingIsAPureFunctionOfTheProvider() {
        // `generate()` resolves ONCE and hands the result to `runJob`. That is only possible because
        // hosting depends on nothing but the provider — otherwise the activation would have to be read
        // again after the upload, and a key added mid-upload could re-route the dispatch to a provider
        // that can't read what was just hosted.
        #expect(GenerationService.referenceHosting(for: .runway) == .runway)
        #expect(GenerationService.referenceHosting(for: .google) == .inline)
        #expect(GenerationService.referenceHosting(for: .marble) == .inline)
        #expect(GenerationService.referenceHosting(for: .fal) == .fal)
        #expect(GenerationService.referenceHosting(for: .elevenlabs) == .fal)
    }

    // MARK: - What may be written into the project

    @Test("only hosted URLs are durable enough to persist; local paths never are")
    func inlinePathsAreNeverPersisted() {
        // `GenerationInput` rides in the media manifest. An absolute local path there would break the
        // self-contained `.ngv` the moment the project moves machines — and claim a hosted URL that
        // never existed.
        #expect(ReferenceHosting.inline.persistsHostedURLs == false)
        #expect(ReferenceHosting.runway.persistsHostedURLs)
        #expect(ReferenceHosting.fal.persistsHostedURLs)
    }

    // MARK: - Upload filename

    @Test("a file with a known extension uploads under its real name")
    func knownExtensionKeepsName() {
        #expect(GenerationService.uploadFilename(
            for: URL(fileURLWithPath: "/tmp/shot-01.png"), fallback: .image) == "shot-01.png")
        #expect(GenerationService.uploadFilename(
            for: URL(fileURLWithPath: "/tmp/take.mov"), fallback: .video) == "take.mov")
    }

    @Test("a file whose extension Runway can't read gets one that matches what it is")
    func unknownExtensionGetsATypedName() {
        // Runway derives the content type from the EXTENSION and then pins it in the S3 upload policy,
        // so a name it can't read fails the upload outright rather than defaulting to something.
        #expect(GenerationService.uploadFilename(
            for: URL(fileURLWithPath: "/tmp/frame"), fallback: .image) == "frame.jpg")
        #expect(GenerationService.uploadFilename(
            for: URL(fileURLWithPath: "/tmp/clip.raw"), fallback: .video) == "clip.mp4")
        #expect(GenerationService.uploadFilename(
            for: URL(fileURLWithPath: "/tmp/voice.opus"), fallback: .audio) == "voice.mp3")
    }
}

/// The reference mime type a live call exposed (#244, Codex review): the bytes come from whatever the
/// user imported, and Gemini decodes `inline_data` by the DECLARED type — so the label has to be true.
@Suite("gemini reference mime type")
struct GeminiReferenceMimeTests {

    private func bytes(_ head: [UInt8], padTo count: Int = 16) -> Data {
        var b = head
        b.append(contentsOf: Array(repeating: 0x00, count: max(0, count - head.count)))
        return Data(b)
    }

    @Test("each real image format is declared as itself")
    func sniffsRealFormats() throws {
        #expect(try GoogleImageClient.mimeType(
            of: bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == "image/png")
        #expect(try GoogleImageClient.mimeType(of: bytes([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
        // RIFF....WEBP — the brand sits at offset 8, so the four filler bytes are the size field.
        #expect(try GoogleImageClient.mimeType(of: bytes(
            [0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50])) == "image/webp")
    }

    @Test("HEIC and HEIF are recognized — a Mac photo library hands these out by default")
    func sniffsAppleFormats() throws {
        let ftyp: [UInt8] = [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]
        #expect(try GoogleImageClient.mimeType(
            of: bytes(ftyp + Array("heic".utf8))) == "image/heic")
        #expect(try GoogleImageClient.mimeType(
            of: bytes(ftyp + Array("mif1".utf8))) == "image/heif")
    }

    @Test("a JPEG is never labeled PNG")
    func jpegIsNotPng() throws {
        // The defect this replaces: every reference went out as image/png regardless, so an imported
        // JPEG — the normal case — was mislabeled and the edit failed.
        let jpeg = try GoogleImageClient.mimeType(of: bytes([0xFF, 0xD8, 0xFF, 0xE0]))
        #expect(jpeg != "image/png")
    }

    @Test("an unrecognized reference fails here, naming the problem")
    func unknownFormatThrows() {
        // Better a sentence that says what's wrong than a PNG label on non-PNG bytes and an opaque
        // Google 400 at spend time.
        #expect(throws: GoogleImageClient.ClientError.self) {
            try GoogleImageClient.mimeType(of: bytes([0x42, 0x4D, 0x00, 0x00]))  // BMP
        }
        #expect(throws: GoogleImageClient.ClientError.self) {
            try GoogleImageClient.mimeType(of: Data([0x89, 0x50]))  // too short to identify
        }
    }
}
