import AppKit
import NexGenEngine
import SwiftUI

struct ProjectReferenceImage: Equatable, Sendable {
    let projectHome: URL
    let path: String
    let name: String
    let entity: BibleEntityRef

    var id: String { "reference:\(projectHome.path):\(entity.compositeID):\(path)" }
}

enum ProjectReferenceImageLoader {
    static func bytes(projectHome: URL, path: String) throws -> Data {
        guard let root = DataRootResolver.dataRoot(of: projectHome) else {
            throw ProjectLocalFileError.invalidPath(path)
        }
        return try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: root), options: .mappedIfSafe)
    }
}

struct ProjectReferenceImageView: View {
    let projectHome: URL?
    let path: String
    var compact = false
    @Environment(EditorViewModel.self) private var editor
    @State private var image: NSImage?
    @State private var failed = false
    @State private var retry = 0
    @State private var loadedIdentity: Identity?

    private struct Identity: Equatable {
        let home: URL?
        let path: String
        let revision: Int
        let retry: Int
    }

    private var identity: Identity {
        Identity(home: projectHome, path: path, revision: editor.engineStateRevision, retry: retry)
    }

    var body: some View {
        Group {
            if loadedIdentity == identity, let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if loadedIdentity == identity, failed {
                VStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Image unavailable")
                        .multilineTextAlignment(.center)
                    if !compact {
                        Text("The reference image could not be read. Retry after restoring it, or revise the reference in Bible.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Retry") { retry += 1 }
                            .buttonStyle(.capsule(.secondary, size: .regular))
                    }
                }
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(AppTheme.Spacing.sm)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.previewCanvasColor)
        .task(id: identity) { await load(identity) }
    }

    private func load(_ request: Identity) async {
        image = nil
        failed = false
        let data = await Task.detached(priority: .utility) { () -> Data? in
            guard let home = request.home else { return nil }
            return try? ProjectReferenceImageLoader.bytes(projectHome: home, path: request.path)
        }.value
        guard !Task.isCancelled, request == identity else { return }
        image = data.flatMap { NSImage(data: $0) }
        failed = image == nil
        loadedIdentity = request
    }
}
