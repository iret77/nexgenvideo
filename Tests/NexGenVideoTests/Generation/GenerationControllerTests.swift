import Foundation
import Testing

@testable import NexGenVideo

/// The one canonical generation path (#114): PREFLIGHT → COMPILE → SUBMIT → FEEDBACK. These exercise
/// the controller's shared sequence with a stubbed editor and on-disk ledger fixtures, following the
/// app-test pattern (a bare `EditorViewModel()` plus a temp project dir).
@Suite("GenerationController")
@MainActor
struct GenerationControllerTests {

    // MARK: Fixtures

    /// A temp project dir (v2 `pipeline` layout) with a project marker and the given ledger YAML.
    private static func makeProject(ledgerYAML: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngv-controller-\(UUID().uuidString)")
        let studio = root.appendingPathComponent("pipeline")
        try FileManager.default.createDirectory(at: studio, withIntermediateDirectories: true)
        try "project: t\nmode: beat\n".write(
            to: studio.appendingPathComponent("project.yaml"), atomically: true, encoding: .utf8)
        try ledgerYAML.write(
            to: studio.appendingPathComponent("ledger.yaml"), atomically: true, encoding: .utf8)
        return root
    }

    private static let cleanLockedLedger = """
        schema: ledger/v1
        objects:
          look:
            palette:
              tag: warm amber and teal
              directive: warm amber and teal grade
              locked: true
        """

    /// A locked directive containing a meta-instruction ("please …"): the builder appends ledger
    /// directives verbatim (no slop-strip), so this survives into the final prompt and the engine
    /// PromptLinter flags it as a META_INSTRUCTION_SURVIVED *error* — the compile must block.
    private static let metaInstructionLedger = """
        schema: ledger/v1
        objects:
          look:
            note:
              tag: please keep the red jacket in every shot
              directive: please keep the red jacket in every shot
              locked: true
        """

    private func stubEditor(projectURL: URL?) -> EditorViewModel {
        let editor = EditorViewModel()
        editor.projectURL = projectURL
        return editor
    }

    private func videoRequest(intent: String, editor: EditorViewModel) -> GenerationRequest {
        GenerationRequest(
            modality: .video, modelId: "fal-ai/veo3", intent: intent,
            aspectRatio: "16:9", durationSeconds: 5,
            placement: .mediaLibrary(folderId: nil), origin: .panel,
            submission: .video(make: { compiled in
                let genInput = GenerationInput(
                    prompt: compiled, model: "fal-ai/veo3", duration: 5, aspectRatio: "16:9")
                return VideoGenerationSubmission(
                    genInput: genInput, placeholderDuration: 5, references: [],
                    trimmedSourceOverride: nil, name: nil, folderId: nil,
                    buildParams: { _ in .video(VideoGenerationParams(
                        prompt: compiled, duration: 5, aspectRatio: "16:9", resolution: nil,
                        sourceVideoURL: nil, startFrameURL: nil, endFrameURL: nil,
                        referenceImageURLs: [], generateAudio: true)) },
                    snapshotRefs: nil, preprocessRef: nil)
            }))
    }

    // MARK: (a) PREFLIGHT

    @Test func preflightMessageBlocksBeforeCompileOrSubmit() async {
        let editor = stubEditor(projectURL: nil)
        let before = editor.mediaAssets.count
        let result = await GenerationController.submit(
            videoRequest(intent: "a red car on a wet street", editor: editor),
            editor: editor,
            preflight: { "duration invalid" })
        guard case .failure(.optionsInvalid(let message)) = result else {
            Issue.record("expected .optionsInvalid, got \(result)")
            return
        }
        #expect(message == "duration invalid")
        // Nothing was submitted — no placeholder created.
        #expect(editor.mediaAssets.count == before)
    }

    // MARK: (b) COMPILE

    @Test func compileBlocksOnLintError() async throws {
        let project = try Self.makeProject(ledgerYAML: Self.metaInstructionLedger)
        defer { try? FileManager.default.removeItem(at: project) }
        let editor = stubEditor(projectURL: project)
        let before = editor.mediaAssets.count

        let result = await GenerationController.submit(
            videoRequest(intent: "a red car on a wet street", editor: editor), editor: editor)
        guard case .failure(.compile(let message)) = result else {
            Issue.record("expected .compile failure, got \(result)")
            return
        }
        #expect(message.contains("lint") || message.lowercased().contains("meta"))
        #expect(editor.mediaAssets.count == before)
    }

    @Test func compilePassesWithACleanLockedDirectiveAndSubmits() async throws {
        let project = try Self.makeProject(ledgerYAML: Self.cleanLockedLedger)
        defer { try? FileManager.default.removeItem(at: project) }
        let editor = stubEditor(projectURL: project)
        let before = editor.mediaAssets.count

        let result = await GenerationController.submit(
            videoRequest(intent: "a red car on a wet street at dusk", editor: editor), editor: editor)
        guard case .success(let outcome) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(!outcome.placeholderId.isEmpty)
        // FEEDBACK: a media-library submission created a placeholder asset.
        #expect(editor.mediaAssets.count == before + 1)
    }

    @Test func compileSkippedForEmptyIntentStillSubmits() async {
        let editor = stubEditor(projectURL: nil)
        let before = editor.mediaAssets.count
        // Empty intent (e.g. audio scored from video) → nothing to compose; the request still submits.
        let request = GenerationRequest(
            modality: .video, modelId: "fal-ai/veo3", intent: "",
            placement: .mediaLibrary(folderId: nil), origin: .panel,
            submission: .video(make: { compiled in
                #expect(compiled.isEmpty)
                let genInput = GenerationInput(prompt: compiled, model: "fal-ai/veo3", duration: 5, aspectRatio: "16:9")
                return VideoGenerationSubmission(
                    genInput: genInput, placeholderDuration: 5, references: [],
                    trimmedSourceOverride: nil, name: nil, folderId: nil,
                    buildParams: { _ in .video(VideoGenerationParams(
                        prompt: compiled, duration: 5, aspectRatio: "16:9", resolution: nil,
                        sourceVideoURL: nil, startFrameURL: nil, endFrameURL: nil,
                        referenceImageURLs: [], generateAudio: true)) },
                    snapshotRefs: nil, preprocessRef: nil)
            }))
        let result = await GenerationController.submit(request, editor: editor)
        guard case .success = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(editor.mediaAssets.count == before + 1)
    }

    // MARK: Gate (agentTool origin)

    @Test func agentToolWithoutTokenIsGateBlocked() async {
        let editor = stubEditor(projectURL: nil)
        // origin .agentTool with a non-empty intent but no valid compileToken → gate rejects.
        let request = GenerationRequest(
            modality: .video, modelId: "fal-ai/veo3", intent: "a red car",
            placement: .mediaLibrary(folderId: nil), origin: .agentTool,
            precompiled: (text: "a red car", token: "deadbeefdeadbeef"),
            submission: .video(make: { compiled in
                let genInput = GenerationInput(prompt: compiled, model: "fal-ai/veo3", duration: 5, aspectRatio: "16:9")
                return VideoGenerationSubmission(
                    genInput: genInput, placeholderDuration: 5, references: [],
                    trimmedSourceOverride: nil, name: nil, folderId: nil,
                    buildParams: { _ in .video(VideoGenerationParams(
                        prompt: compiled, duration: 5, aspectRatio: "16:9", resolution: nil,
                        sourceVideoURL: nil, startFrameURL: nil, endFrameURL: nil,
                        referenceImageURLs: [], generateAudio: true)) },
                    snapshotRefs: nil, preprocessRef: nil)
            }))
        let result = await GenerationController.submit(request, editor: editor)
        guard case .failure(.gate) = result else {
            Issue.record("expected .gate failure, got \(result)")
            return
        }
    }
}
