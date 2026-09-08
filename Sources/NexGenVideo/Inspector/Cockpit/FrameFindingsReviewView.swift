import SwiftUI
import NexGenEngine

struct FrameFindingsReviewView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var items: [Item] = []
    @State private var home: URL?
    @State private var failure: String?

    private struct Item: Identifiable, Sendable {
        let audit: FrameAudit
        let snapshot: String
        var id: String { audit.shotId + "/" + audit.role }
    }

    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if let failure { Text(failure).foregroundStyle(AppTheme.Text.secondaryColor) }
            if home == editor.workingRoot {
                ForEach(items) { item in
                    FrameFindingsCard(audit: item.audit, snapshot: item.snapshot, project: home)
                }
            }
        }
        }
        .frame(maxHeight: items.isEmpty && failure == nil ? AppTheme.Spacing.none : AppTheme.ComponentSize.productionStyleReviewMaxHeight)
        .interfaceFont(size: AppTheme.Typography.ui)
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision)") {
            let current = editor.workingRoot
            do {
                let loaded = try await Task.detached(priority: .utility) { () -> [Item] in
                    guard let current, let root = DataRootResolver.dataRoot(of: current),
                          FileManager.default.fileExists(atPath: root.appendingPathComponent(PipelineLayout.framesManifestFile).path) else { return [] }
                    let manifest = try loadFramesManifest(dataRoot: root)
                    return try manifest.shots.flatMap { shot in
                        try shot.frames.compactMap { frame in
                            guard let audit = try loadFrameAudit(dataRoot: root, shotId: shot.shotId, role: frame.role),
                                  !FrameAuditAcceptanceStoreV1.unresolvedChecks(audit).isEmpty else { return nil }
                            if (try? FrameAuditAcceptanceStoreV1.requireResolved(audit: audit, dataRoot: root)) != nil { return nil }
                            return Item(audit: audit, snapshot: try FrameAuditAcceptanceStoreV1.snapshot(audit: audit, dataRoot: root))
                        }
                    }
                }.value
                guard !Task.isCancelled, current == editor.workingRoot else { return }
                home = current; items = loaded; failure = nil
            } catch {
                guard !Task.isCancelled, current == editor.workingRoot else { return }
                items = []; failure = "Frame findings need a current image and Production Design before they can be accepted."
            }
        }
    }
}

private struct FrameFindingsCard: View {
    @Environment(EditorViewModel.self) private var editor
    let audit: FrameAudit
    let snapshot: String
    let project: URL?
    @State private var reason = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var readiness = NativeGateApprovalReadiness.blocked("Checking review readiness.")

    private var refreshID: String {
        let phase = project.flatMap { DataRootResolver.dataRoot(of: $0) }.flatMap {
            editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: $0)
        } ?? "idle"
        return "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision):\(phase):\(snapshot)"
    }

    var body: some View {
        DisclosureGroup("Review deviations: \(audit.shotId) · \(audit.role)") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                SheetThumbnailView(label: "Reviewed frame", path: audit.renderPath, projectDir: editor.workingRoot,
                    tileHeight: AppTheme.ComponentSize.productionStyleReviewMaxHeight)
                ForEach(FrameAuditAcceptanceStoreV1.unresolvedChecks(audit), id: \.self) { key in
                    if let check = audit.checks[key] {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Text(check.expected).fontWeight(AppTheme.FontWeight.semibold)
                            Text("Observed: " + check.observed)
                            if !check.note.isEmpty { Text(check.note).foregroundStyle(AppTheme.Text.secondaryColor) }
                        }
                    }
                }
                TextField("Reason for accepting these deviations", text: $reason)
                Button("Accept these deviations") {
                    busy = true
                    Task {
                        do {
                            try await NativeGateWriter.acceptFrameFindings(editor: editor, expectedProject: project, audit: audit, snapshot: snapshot, reason: reason)
                        } catch { failure = error.localizedDescription }
                        busy = false
                    }
                }
                .buttonStyle(InlineActionButtonStyle(variant: .approval))
                .disabled(busy || !readiness.isReady || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let blocker = readiness.blocker { Text(blocker).foregroundStyle(AppTheme.Text.secondaryColor) }
                if let failure { Text(failure).foregroundStyle(AppTheme.Text.secondaryColor) }
            }
            .padding(.top, AppTheme.Spacing.sm)
        }
        .padding(AppTheme.Spacing.md)
        .task(id: refreshID) {
            readiness = .blocked("Checking review readiness.")
            let currentID = refreshID
            let value = await NativeGateWriter.frameFindingsReadiness(editor: editor, project: project, audit: audit, snapshot: snapshot)
            guard !Task.isCancelled, currentID == refreshID else { return }
            readiness = value
        }
    }
}
