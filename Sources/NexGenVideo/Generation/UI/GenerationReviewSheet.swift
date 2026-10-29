import AppKit
import SwiftUI

@MainActor
enum GenerationReviewSheet {
    static func confirm(generation: GenerationController.PreparedGeneration, title: String,
                        editor: EditorViewModel, services: GenerationPanelServices = .live) async throws -> Bool {
        guard let package = generation.reviewedPackage,
              let document = NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject })
                .first(where: { $0.editorViewModel === editor }),
              let parent = document.windowControllers.compactMap(\.window).first(where: \.isVisible),
              parent.attachedSheet == nil else {
            throw GenerationRequestError.gate("Open the project window and close its current sheet before reviewing generation.")
        }
        try await package.requireCurrentContext(editor: editor)
        try generation.scope?.requireCurrent(editor: editor)
        try generation.replacementTarget?.requireCurrent(editor: editor)
        let session = Session(parent: parent, package: package, title: title, editor: editor)
        let accepted = await withTaskCancellationHandler {
            await session.present()
        } onCancel: {
            Task { @MainActor in session.finish(false) }
        }
        try Task.checkCancellation()
        if accepted {
            try await package.requireCurrentContext(editor: editor)
            try generation.scope?.requireCurrent(editor: editor)
            try generation.replacementTarget?.requireCurrent(editor: editor)
            try await generation.references?.requireUnchanged()
            guard services.isCurrent(generation.target) else {
                throw GenerationRequestError.gate("The reviewed provider or model is unavailable. Prepare the request again.")
            }
        }
        return accepted
    }

    private final class Session {
        let parent: NSWindow
        let sheet: NSPanel
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        init(parent: NSWindow, package: GenerationPackageV1, title: String, editor: EditorViewModel) {
            self.parent = parent
            let width = min(AppTheme.ComponentSize.formatSheetWidth, parent.contentLayoutRect.width - AppTheme.Spacing.xl)
            let height = min(AppTheme.ComponentSize.formatSheetCardListMaxHeight,
                parent.contentLayoutRect.height - AppTheme.Spacing.xxl)
            sheet = NSPanel(contentRect: NSRect(origin: .zero, size: .init(width: width, height: height)),
                styleMask: [.titled], backing: .buffered, defer: false)
            sheet.title = title
            sheet.isReleasedWhenClosed = false
            sheet.contentView = NSHostingView(rootView: Review(package: package, title: title,
                complete: { [weak self] value in self?.finish(value) }).environment(editor))
        }

        func present() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                parent.makeKeyAndOrderFront(nil)
                parent.beginSheet(sheet) { [weak self] _ in self?.complete() }
            }
        }

        func finish(_ accepted: Bool) {
            guard result == nil else { return }
            result = accepted
            if sheet.sheetParent != nil { parent.endSheet(sheet) }
            else { complete() }
        }

        private func complete() {
            let callback = continuation
            continuation = nil
            result = result ?? false
            sheet.orderOut(nil)
            callback?.resume(returning: result == true)
        }
    }

    private struct Review: View {
        let package: GenerationPackageV1
        let title: String
        let complete: (Bool) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text(title)
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                ScrollView {
                    GenerationPackageReviewView(package: package, probePrefix: "generation.review.package")
                        .padding(AppTheme.Spacing.xs)
                }
                WrapLayout(spacing: AppTheme.Spacing.sm, trailingLastItem: true) {
                    Button("Discard") { complete(false) }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .keyboardShortcut(.cancelAction)
                        .reviewAcceptanceProbe("generation.review.discard")
                    Button("Approve and Generate") { complete(true) }
                        .buttonStyle(.capsule(.prominent, size: .regular))
                        .keyboardShortcut(.defaultAction)
                        .reviewAcceptanceProbe("generation.review.approve")
                }
            }
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.Background.surfaceColor)
        }
    }
}
