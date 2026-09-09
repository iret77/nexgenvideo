import SwiftUI
import NexGenEngine

struct ProductionStyleReviewView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var snapshot: Snapshot?
    @State private var failed = false
    @State private var expanded = false

    private struct RefreshID: Hashable {
        let project: URL?
        let revision: Int
    }

    private struct Snapshot: Sendable {
        let home: URL
        let style: ResolvedProductionStyleV1
        let director: String
        let signature: String?
        let approved: Bool

        static func read(home: URL) throws -> Self? {
            guard let root = DataRootResolver.dataRoot(of: home),
                  let style = try ProductionStyleStoreV1.load(dataRoot: root) else { return nil }
            let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
            let entries = catalog.library(id: "film-production-blueprints")?.entries ?? []
            let gates = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
            return Self(home: home, style: style,
                director: entries.first { $0.id.rawValue == style.selection.directorID }?.title ?? style.selection.directorID,
                signature: style.selection.signatureID.flatMap { id in entries.first { $0.id.rawValue == id }?.title },
                approved: gates.get("production_design").approved)
        }
    }

    var body: some View {
        Group {
            if let snapshot, snapshot.home == editor.workingRoot {
                DisclosureGroup(isExpanded: $expanded) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                            Text(snapshot.director)
                                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                            if let signature = snapshot.signature {
                                Text(signature)
                                    .interfaceFont(size: AppTheme.Typography.ui)
                            }
                            ForEach(snapshot.style.dimensions, id: \.dimension) { dimension in
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                    Text(label(dimension.dimension))
                                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                                    Text(dimension.value)
                                        .interfaceFont(size: AppTheme.Typography.ui)
                                    if let reason = dimension.reason {
                                        Text(reason)
                                            .interfaceFont(size: AppTheme.Typography.ui)
                                            .foregroundStyle(AppTheme.Text.secondaryColor)
                                    }
                                }
                            }
                            if editor.declaredPluginName == "musicvideo" {
                                Text("The approved original song determines the music and timing.")
                                    .interfaceFont(size: AppTheme.Typography.ui)
                            }
                            if snapshot.approved { TimelineStyleReviewView() }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, AppTheme.Spacing.sm)
                    }
                    .frame(maxHeight: AppTheme.ComponentSize.productionStyleReviewMaxHeight)
                } label: {
                    HStack {
                        Text("Production style")
                        Spacer(minLength: AppTheme.Spacing.sm)
                        Text(snapshot.approved ? "Approved" : "Proposed")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                }
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(AppTheme.Spacing.md)
                AppDivider()
            } else if failed {
                Text("The production style needs to be updated before review.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .padding(AppTheme.Spacing.md)
            }
        }
        .task(id: RefreshID(project: editor.workingRoot, revision: editor.engineStateRevision)) {
            guard let home = editor.workingRoot else { snapshot = nil; failed = false; return }
            do {
                let value = try await Task.detached(priority: .utility) { try Snapshot.read(home: home) }.value
                guard !Task.isCancelled, editor.workingRoot == home else { return }
                if snapshot == nil { expanded = value?.approved == false }
                snapshot = value
                failed = false
            } catch {
                guard !Task.isCancelled, editor.workingRoot == home else { return }
                snapshot = nil
                failed = true
            }
        }
    }

    private func label(_ dimension: ProductionStyleDimensionV1) -> String {
        switch dimension {
        case .character: "Overall feel"
        case .composition: "Composition"
        case .camera: "Camera"
        case .editing: "Editing"
        case .lighting: "Lighting"
        case .color: "Color"
        case .timing: "Timing"
        case .sound: "Sound direction"
        }
    }
}
