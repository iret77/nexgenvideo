import AppKit
import NexGenEngine
import SwiftUI
import UniformTypeIdentifiers

struct LocationPanoramaView: View {
    let home: URL
    let locationID: String
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var source: URL?
    @State private var prepared: PipelinePanoramaStore.Prepared?
    @State private var currentImages: [String: NSImage] = [:]
    @State private var candidateImages: [String: NSImage] = [:]
    @State private var invalidLocations: [Location] = []
    @State private var bibleSHA256: String?
    @State private var location: Location?
    @State private var current: PipelinePanoramaStore.Receipt?
    @State private var custom = false
    @State private var viewName = "custom_view"
    @State private var yaw = "0"
    @State private var pitch = "-5"
    @State private var fov = "75"
    @State private var inspecting: String?
    @State private var importing = false
    @State private var busy = false
    @State private var failure: String?
    @State private var reviewed = false
    @State private var operation: Task<Void, Never>?
    @State private var loadedGeneration: UUID?
    @State private var loading = false

    private var images: [String: NSImage] { prepared == nil ? currentImages : candidateImages }

    private var active: Bool {
        editor.workingRoot == home && loadedGeneration != nil && editor.openWorkingCopyGeneration == loadedGeneration
            && editor.projectState?.nextPhaseName == "bible" && !busy
            && !editor.agentService.isStreaming && !editor.agentService.isComposerBlocked
    }
    private var specs: [PovSpec]? {
        guard custom else { return defaultFourWallPovs }
        guard let yaw = Double(yaw), let pitch = Double(pitch), let fov = Double(fov) else { return nil }
        let values = defaultFourWallPovs + [.init(name: viewName, yawDegrees: yaw, pitchDegrees: pitch, fovHorizontalDegrees: fov)]
        return (try? PipelinePanoramaStore.validate(specs: values)) != nil ? values : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Panorama · \(location?.name ?? "Location")").interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text("Extract camera views from one 2:1 panorama. Review all views before assigning their shared geometry to this location. Existing appearance sheets remain separate.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    if let reason = ReferenceEditingGuidance.message(editor: editor, allowedPhases: ["bible"]) {
                        Text(reason).foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    if loading || (loadedGeneration == nil && failure == nil) { ProgressView("Reading panorama references…") }
                    if let current {
                        Text(current.originalName).foregroundStyle(AppTheme.Text.secondaryColor)
                            .reviewAcceptanceProbe("bible.panorama.confirmed-source", text: current.originalName)
                    }
                    Button("Choose panorama…") { importing = true }.buttonStyle(InlineActionButtonStyle()).disabled(!active)
                        .reviewAcceptanceProbe("bible.panorama.choose", state: active)
                    if let source {
                        Text(source.lastPathComponent).reviewAcceptanceProbe("bible.panorama.source", text: source.lastPathComponent)
                        Toggle("Add a custom camera view", isOn: $custom).disabled(!active)
                            .reviewAcceptanceProbe("bible.panorama.custom", state: custom)
                        if custom {
                            TextField("View name", text: $viewName).disabled(!active).reviewAcceptanceProbe("bible.panorama.name", text: viewName)
                            HStack(spacing: AppTheme.Spacing.md) {
                                TextField("Yaw (°)", text: $yaw).reviewAcceptanceProbe("bible.panorama.yaw", text: yaw)
                                TextField("Pitch (°)", text: $pitch).reviewAcceptanceProbe("bible.panorama.pitch", text: pitch)
                                TextField("Horizontal FOV (°)", text: $fov).reviewAcceptanceProbe("bible.panorama.fov", text: fov)
                            }.disabled(!active)
                            Text("Yaw −180…180°, pitch −90…90°, horizontal field of view greater than 0° and less than 180°.")
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                        Button("Extract views") { extract() }.buttonStyle(InlineActionButtonStyle()).disabled(!active || specs == nil)
                            .reviewAcceptanceProbe("bible.panorama.extract", state: active && specs != nil)
                    }
                    ForEach(prepared?.views ?? current?.views ?? [], id: \.geometry.name) { view in
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            Text("\(view.geometry.name) · yaw \(view.geometry.yaw.formatted())° · pitch \(view.geometry.pitch.formatted())° · FOV \(view.geometry.fov.formatted())°")
                            if let image = images[view.geometry.name] {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity).frame(maxHeight: AppTheme.Layout.previewMinHeight)
                                    .accessibilityLabel("Panorama view \(view.geometry.name)")
                                    .reviewAcceptanceProbe("bible.panorama.image.\(view.geometry.name)", text: view.image.sha256)
                                Button("Inspect view") { inspecting = view.geometry.name }.buttonStyle(InlineActionButtonStyle())
                                    .reviewAcceptanceProbe("bible.panorama.inspect.\(view.geometry.name)")
                            }
                            if prepared == nil {
                                Button("Create appearance sheet…") { requestAppearance(view) }
                                    .buttonStyle(InlineActionButtonStyle()).disabled(!active)
                                    .reviewAcceptanceProbe("bible.panorama.restyle.\(view.geometry.name)", state: active)
                            }
                        }
                    }
                    if prepared == nil, let current {
                        Button("Remove panorama assignment") { remove(current) }.buttonStyle(InlineActionButtonStyle()).disabled(!active)
                            .reviewAcceptanceProbe("bible.panorama.remove", state: active)
                    }
                    if !invalidLocations.isEmpty, let bibleSHA256 {
                        Text("Remove the invalid panorama assignments for these locations together:")
                        Text(invalidLocations.map { $0.name + " (" + $0.id + ")" }.joined(separator: "\n"))
                            .textSelection(.enabled)
                            .reviewAcceptanceProbe("bible.panorama.invalid-locations", text: invalidLocations.map(\.id).joined(separator: ","))
                        Button(invalidLocations.count == 1 ? "Remove invalid panorama assignment" : "Remove all invalid panorama assignments") {
                            removeInvalid(invalidLocations, bibleSHA256: bibleSHA256)
                        }
                            .buttonStyle(InlineActionButtonStyle()).disabled(!active)
                            .reviewAcceptanceProbe("bible.panorama.remove-invalid", state: active)
                        Text("Restore the original files before undoing removal of an invalid assignment.")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    if let prepared {
                        Text("Review extracted views").reviewAcceptanceProbe("bible.panorama.candidate", text: prepared.id)
                        Toggle("I inspected these views and confirm their shared layout for this location", isOn: $reviewed).disabled(!active)
                            .reviewAcceptanceProbe("bible.panorama.reviewed", state: reviewed)
                        Button("Use panorama views") { confirm() }.buttonStyle(CapsuleButtonStyle(variant: .prominent)).disabled(!active || !reviewed)
                            .reviewAcceptanceProbe("bible.panorama.confirm", state: active && reviewed)
                    }
                    if busy { ProgressView("Preparing panorama views…") }
                    if let failure {
                        Text(failure).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled).reviewAcceptanceProbe("bible.panorama.error", text: failure)
                        Button("Reload references") { Task { await load() } }.buttonStyle(InlineActionButtonStyle()).disabled(busy || loading)
                    }
                }
            }
            HStack {
                if busy { Button("Cancel") { operation?.cancel() }.buttonStyle(InlineActionButtonStyle()) }
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("Done") { dismiss() }.buttonStyle(InlineActionButtonStyle()).disabled(busy)
                    .reviewAcceptanceProbe("bible.panorama.done", state: !busy)
            }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        .interactiveDismissDisabled(busy)
        .reviewAcceptanceProbe("bible.panorama.sheet")
        .sheet(isPresented: Binding(get: { inspecting != nil }, set: { if !$0 { inspecting = nil } })) {
            if let name = inspecting, let image = images[name]?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ProductionImageInspectionView(image: image, title: "Panorama view · " + name)
            }
        }
        .task { await load() }
        .onChange(of: custom) { _, _ in invalidate() }
        .onChange(of: viewName) { _, _ in invalidate() }
        .onChange(of: yaw) { _, _ in invalidate() }
        .onChange(of: pitch) { _, _ in invalidate() }
        .onChange(of: fov) { _, _ in invalidate() }
        .onDisappear { operation?.cancel() }
        .onChange(of: editor.openWorkingCopyGeneration) { _, _ in operation?.cancel(); dismiss() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            guard active else { return }
            do { source = try result.get().first; invalidate() }
            catch { failure = error.localizedDescription }
        }
    }

    private func invalidate() { prepared = nil; candidateImages = [:]; reviewed = false; failure = nil }

    private func load() async {
        loading = true
        failure = nil
        defer { loading = false }
        guard let root = DataRootResolver.dataRoot(of: home) else {
            failure = "This project session is unavailable. Close this view and reopen the project."
            return
        }
        let locationID = locationID
        let generation = editor.openWorkingCopyGeneration
        do {
            let loadTask = Task.detached(priority: .userInitiated) { () throws -> (Location, String, PipelinePanoramaStore.Receipt?, [(String, Data)], String?, [Location]) in
                try Task.checkCancellation()
                guard let bible = try loadBible(dataRoot: root),
                      let location = bible.locations.first(where: { $0.id == locationID }) else {
                    throw ToolError("This reference location is no longer available.")
                }
                let hash = try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root))
                let invalid = try PipelinePanoramaStore.invalidSelections(in: bible, dataRoot: root)
                guard try loadBible(dataRoot: root) == bible,
                      try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root)) == hash else {
                    throw ToolError("References changed. Reopen Panorama to inspect the current assignments.")
                }
                do {
                    let current = try PipelinePanoramaStore.current(location: location, dataRoot: root)
                    let images = try (current?.views ?? []).map { view in
                        (view.geometry.name, try Data(contentsOf: ProjectLocalFile.requireHash(view.image.sha256, at: view.image.path, dataRoot: root)))
                    }
                    return (location, hash, current, images, nil as String?, invalid)
                } catch {
                    if error is CancellationError { throw error }
                    guard PipelinePanoramaStore.hasNativeSelection(location) else { throw error }
                    return (location, hash, nil, [(String, Data)](), error.localizedDescription, invalid)
                }
            }
            let loaded = try await withTaskCancellationHandler { try await loadTask.value } onCancel: { loadTask.cancel() }
            guard !Task.isCancelled, editor.workingRoot == home, editor.openWorkingCopyGeneration == generation else { return }
            loadedGeneration = generation
            location = loaded.0; bibleSHA256 = loaded.1; current = loaded.2
            currentImages = Dictionary(uniqueKeysWithValues: loaded.3.compactMap { name, data in NSImage(data: data).map { (name, $0) } })
            invalidLocations = loaded.5
            if prepared == nil { failure = loaded.4 }
        } catch {
            guard !Task.isCancelled, editor.workingRoot == home, editor.openWorkingCopyGeneration == generation else { return }
            failure = error.localizedDescription
        }
    }

    private func extract() {
        guard active, let source, let specs else { return }
        busy = true; failure = nil; reviewed = false
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                let candidate = try await PipelinePanoramaStore.prepare(source: source, locationID: locationID, specs: specs, editor: editor)
                guard !Task.isCancelled, editor.workingRoot == home else { return }
                var values: [String: NSImage] = [:]
                for view in candidate.views {
                    guard let data = candidate.files.first(where: { $0.path == view.image.path })?.bytes,
                          let image = NSImage(data: data) else { throw ToolError("An extracted view cannot be displayed. Extract the views again.") }
                    values[view.geometry.name] = image
                }
                prepared = candidate; candidateImages = values
            } catch is CancellationError { failure = "Panorama extraction was cancelled. References were not changed." }
            catch { failure = error.localizedDescription }
        }
    }

    private func confirm() {
        guard active, reviewed, let prepared else { return }
        busy = true; failure = nil
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await PipelinePanoramaStore.confirm(prepared, editor: editor); dismiss() }
            catch is CancellationError { failure = "Panorama assignment cancelled. References were not changed." }
            catch { failure = error.localizedDescription }
        }
    }

    private func remove(_ current: PipelinePanoramaStore.Receipt) {
        guard active else { return }
        busy = true; failure = nil
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await PipelinePanoramaStore.clear(locationID: locationID, expected: current, editor: editor); dismiss() }
            catch is CancellationError { failure = "Panorama removal cancelled. References were not changed." }
            catch { failure = error.localizedDescription }
        }
    }

    private func removeInvalid(_ locations: [Location], bibleSHA256: String) {
        guard active else { return }
        busy = true; failure = nil
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await PipelinePanoramaStore.clearInvalid(locations: locations, bibleSHA256: bibleSHA256, editor: editor); dismiss() }
            catch is CancellationError { failure = "Panorama removal cancelled. References were not changed." }
            catch { failure = error.localizedDescription }
        }
    }

    private func requestAppearance(_ view: PipelinePanoramaStore.View) {
        guard active, let location else { return }
        let turn = AgentControlTurn(command: "Create an appearance sheet for Bible location \(location.id), view \(view.geometry.name), from the confirmed panorama POV \(view.image.path) (SHA256 \(view.image.sha256)). Preserve its exact composition and geometry. Use the current approved Bible look with RestylePrompt preservation semantics. Compile the image request, prepare phase-cost approval, generate from this real view, and publish the result through write_bible with exact prompt/model provenance. Preserve scene3d and the native panorama receipt. Do not substitute an unconditioned image or label the raw panorama view as appearance.",
            selections: [.init(label: "Location", values: [location.name]), .init(label: "Camera view", values: [view.geometry.name])])
        if editor.agentService.send(controlTurn: turn) { editor.agentPanelVisible = true; dismiss() }
        else { failure = "Finish the current agent action before creating an appearance sheet." }
    }
}
