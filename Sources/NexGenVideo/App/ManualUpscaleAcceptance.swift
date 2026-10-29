import AppKit
import SwiftUI
import NexGenEngine

@MainActor
enum ManualUpscaleAcceptance {
    static func run(editor: EditorViewModel, source: MediaAsset, services: GenerationPanelServices,
                    driver: ProductionVisualSourcesDriver) async throws {
        guard WorkspaceUIAcceptance.isRequested,
              let document = NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject })
                .first(where: { $0.editorViewModel === editor }),
              let parent = document.windowControllers.compactMap(\.window).first,
              let selection = services.upscaleSelections(for: source).first(where: { $0.model.id == "fal-ai/clarity-upscaler" }) else {
            throw GateBlocked("The actual image upscaler and its document window are unavailable.")
        }
        var clip = Clip(mediaRef: source.id, startFrame: 0, durationFrames: editor.timeline.fps)
        clip.mediaType = .image
        editor.timeline.tracks = [Track(type: .video, clips: [clip])]
        editor.selectedClipIds = [clip.id]
        let original = editor.timeline
        let editWindow = NSWindow(contentRect: NSRect(origin: .zero, size: AppTheme.Window.projectMin),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        editWindow.isReleasedWhenClosed = false
        editWindow.contentView = NSHostingView(rootView: AIEditTab(asset: source, clipId: clip.id, services: services).environment(editor))
        defer { editWindow.close() }
        editWindow.makeKeyAndOrderFront(nil)
        try await driver.wait("native upscale replacement scope") { driver.text("ai-edit.scope.Replace clip source", in: editWindow) == "off" }
        try await driver.click("ai-edit.scope.Replace clip source", in: editWindow)
        try await driver.wait("explicit source replacement enabled") { driver.text("ai-edit.scope.Replace clip source", in: editWindow) == "on" }
        let initialSpend = editor.generationLog.spendEvents.count
        MusicvideoGenerationHTTP.clear()
        func review() async throws -> NSWindow {
            editWindow.makeKeyAndOrderFront(nil)
            try await driver.menu("ai-edit.upscale", title: selection.label(durationSeconds: source.duration), in: editWindow)
            try await driver.wait("actual upscale package approval sheet") {
                parent.attachedSheet.map { driver.state("generation.review.approve", in: $0) == true } == true
            }
            guard let sheet = parent.attachedSheet, sheet.isKeyWindow else { throw GateBlocked("The real upscale review sheet did not receive focus.") }
            return sheet
        }
        let discarded = try await review()
        try driver.capture("upscale-review-before-discard", target: discarded)
        try await driver.click("generation.review.discard", in: discarded)
        try await driver.wait("upscale discard closes its sheet") { parent.attachedSheet == nil }
        guard editor.timeline == original, MusicvideoGenerationHTTP.requests.isEmpty,
              editor.generationLog.spendEvents.count == initialSpend else { throw GateBlocked("Discarding upscale changed media, spend or dispatch.") }
        let sheet = try await review()
        try await driver.click("generation.review.package.details", in: sheet)
        try await driver.click("generation.review.package.copy-package", in: sheet)
        guard let text = NSPasteboard.general.string(forType: .string) else { throw GateBlocked("The real upscale package was not copied.") }
        let package = try JSONDecoder().decode(GenerationPackageV1.self, from: Data(text.utf8))
        guard package.payload.operation == "upscale", package.payload.prompt.isEmpty,
              package.payload.destination.kind == "replace_clip", package.payload.destination.clipID == clip.id,
              package.payload.destination.linkedSourcesSHA256 != nil,
              package.payload.references.map(\.assetID) == [source.id], MusicvideoGenerationHTTP.requests.isEmpty else {
            throw GateBlocked("The visible upscale request does not bind the exact source and replacement scope.")
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<64 { for y in 0..<64 { bitmap.setColor(.blue, atX: x, y: y) } }
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw GateBlocked("The actual output image could not be encoded.") }
        try MusicvideoGenerationHTTP.installUpscale(endpoint: package.payload.target.endpoint, output: bytes)
        try await driver.click("generation.review.approve", in: sheet)
        try await driver.wait("approved upscale replaces only its target", seconds: 60) {
            editor.clipFor(id: clip.id)?.mediaRef != source.id && editor.mediaAssets.contains {
                $0.generationInput?.generationPackageID == package.id && $0.generationStatus == .none
            }
        }
        guard let result = editor.mediaAssets.first(where: { $0.generationInput?.generationPackageID == package.id }),
              editor.clipFor(id: clip.id)?.mediaRef == result.id,
              MusicvideoGenerationHTTP.uploadedReference == (try Data(contentsOf: source.url)),
              try FileDigest.sha256(of: result.url) == FileDigest.sha256(of: bytes),
              MusicvideoGenerationHTTP.unexpectedRequests.isEmpty,
              MusicvideoGenerationHTTP.requests.filter({ $0.method == "POST" && $0.url.hasPrefix("https://queue.fal.run/") }).count == 1 else {
            throw GateBlocked("Upscale did not consume the exact approved input or replace with the actual downloaded output.")
        }
        let after = editor.timeline
        parent.makeKeyAndOrderFront(nil)
        try driver.pressKey(6, characters: "z", modifiers: .command, in: parent)
        try await driver.wait("native upscale Undo restores original clip") { editor.timeline == original }
        try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: parent)
        try await driver.wait("native upscale Redo restores generated clip") { editor.timeline == after }
        guard editor.mediaAssets.contains(where: { $0.id == source.id && $0.url == source.url }) else {
            throw GateBlocked("Upscale discarded the original library source.")
        }
        try driver.capture("upscale-replaced-and-redone", target: parent)
        try driver.record("native upscale package and source replacement", fields: ["sourceID": source.id,
            "outputID": result.id, "packageID": package.id, "discardDidNotDispatch": true,
            "uploadedSHA256": try FileDigest.sha256(of: source.url), "outputSHA256": try FileDigest.sha256(of: result.url),
            "nativeUndoRedo": true, "originalRetained": true])
    }
}
