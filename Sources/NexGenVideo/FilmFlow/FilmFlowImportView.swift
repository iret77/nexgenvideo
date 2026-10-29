import AppKit
import AuthenticationServices
import NexGenEngine
import SwiftUI

struct FilmFlowImportView: View {
    let editor: EditorViewModel
    let close: () -> Void
    var configuration: FilmFlowImportConfiguration = .live
    var onBusyChanged: (Bool) -> Void = { _ in }
    @Environment(\.webAuthenticationSession) private var authenticate
    @State private var home: URL?
    @State private var key: String?
    @State private var generation: UUID?
    @State private var operation: Task<Void, Never>?
    @State private var operationCancellable = true
    @State private var reader: FilmFlowReader?
    @State private var isolatedConnection: FilmFlowOAuth.Connection?
    @State private var projects: [FilmFlowProjectSummary] = []
    @State private var projectID = ""
    @State private var retained: [FilmFlowSnapshotStore.Retained] = []
    @State private var snapshotID: UUID?
    @State private var prepared: FilmFlowSnapshot.Prepared?
    @State private var material: FilmFlowMaterial?
    @State private var omissions = Set<String>()
    @State private var selectedObjects = Set<String>()
    @State private var selectedObject = ""
    @State private var targetShot = ""
    @State private var targetMoment = ""
    @State private var targetScene = ""
    @State private var targetEvent = ""
    @State private var movement = ""
    @State private var identityName = ""
    @State private var identityConfirmed = false
    @State private var loadedSnapshotID: UUID?
    @State private var targets: FilmFlowAdoptionCoordinator.Targets?
    @State private var failure: String?
    @State private var message = ""
    @State private var configuredEndpoint = false

    private var current: FilmFlowSnapshotStore.Retained? { retained.first { $0.id == snapshotID } }
    private var snapshot: FilmFlowSnapshot? { prepared?.snapshot ?? (current?.id == loadedSnapshotID ? current?.snapshot : nil) }
    private var item: FilmFlowMaterial.Item? { material?.items.first { $0.id == selectedObject } }
    private var busy: Bool { operation != nil }
    private var sameProject: Bool { editor.workingRoot == home && editor.openWorkingCopyKey == key && editor.openWorkingCopyGeneration == generation }
    private var available: Bool { !busy && sameProject && FilmFlowImportPresenter.canPresent(editor: editor) }
    private var mayAccept: Bool { available && prepared != nil && omissions == Set(prepared?.snapshot.missingImages.map(\.pointer) ?? []) }
    private var mayAdoptNotes: Bool {
        available && current?.id == loadedSnapshotID && current != nil && !selectedObjects.isEmpty
            && targets?.phase == editor.projectState?.nextPhaseName && ["brief", "project_init"].contains(targets?.phase ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Import from FilmFlow").interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    connectionControls
                    retainedControls
                    if let snapshot, let material { snapshotContent(snapshot, material: material) }
                    if let reason = FilmFlowImportPresenter.unavailableReason(editor: editor) {
                        Text(reason).foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    if let failure { Text(failure).foregroundStyle(AppTheme.Text.primaryColor).textSelection(.enabled)
                        .reviewAcceptanceProbe("filmflow.error", text: failure) }
                    if !message.isEmpty { Text(message).textSelection(.enabled).reviewAcceptanceProbe("filmflow.message", text: message) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            AppDivider()
            HStack(spacing: AppTheme.Spacing.md) {
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel operation") { operation?.cancel() }.buttonStyle(InlineActionButtonStyle())
                        .disabled(!operationCancellable)
                        .reviewAcceptanceProbe("filmflow.cancel-operation", state: operationCancellable)
                }
                Spacer()
                Button("Done") { close() }.buttonStyle(InlineActionButtonStyle())
                    .keyboardShortcut(.cancelAction).disabled(busy).reviewAcceptanceProbe("filmflow.done", state: !busy)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(minWidth: AppTheme.Layout.productionDecisionReviewWidth, minHeight: AppTheme.Layout.productionDecisionReviewHeight)
        .reviewAcceptanceProbe("filmflow.sheet")
        .task {
            home = editor.workingRoot; key = editor.openWorkingCopyKey; generation = editor.openWorkingCopyGeneration
            configuredEndpoint = await MainActor.run {
                ExternalMcpServers.httpEndpointURLs().values.contains(where: FilmFlowHTTP.isResource)
            }
            guard !Task.isCancelled else { return }
            run { try await reload() }
        }
        .onDisappear {
            let pending = operation
            pending?.cancel()
            let abandoned = prepared
            let active = reader
            Task {
                await pending?.value
                await Task.detached { abandoned?.discard() }.value
                await active?.close()
            }
        }
        .onChange(of: identityName) { _, _ in identityConfirmed = false }
        .onChange(of: selectedObject) { _, _ in resetMapping() }
        .onChange(of: targetShot) { _, _ in targetMoment = "" }
        .onChange(of: targetScene) { _, _ in targetEvent = "" }
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if configuration.isolated { Text("Isolated acceptance service — no live OAuth or FilmFlow account proof.") }
            Text("Read-only connection to app.filmflow.pro").interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
            if configuredEndpoint { Text("Uses the configured FilmFlow address. Sign-in is stored separately in Keychain.") }
            HStack(spacing: AppTheme.Spacing.md) {
                Button("Connect…") { run { try await connect() } }.buttonStyle(InlineActionButtonStyle()).disabled(!available)
                    .reviewAcceptanceProbe("filmflow.connect", state: available)
                Button("Read projects") { run { try await readProjects() } }.buttonStyle(InlineActionButtonStyle()).disabled(!available)
                    .reviewAcceptanceProbe("filmflow.projects.read", state: available)
                Button("Disconnect") { run {
                    await reader?.close(); reader = nil
                    projects = []; projectID = ""
                    if configuration.isolated { isolatedConnection = nil } else { try await FilmFlowOAuth.shared.disconnect() }
                    message = "Disconnected. Retained snapshots remain available offline."
                } }.buttonStyle(InlineActionButtonStyle()).disabled(!available)
                    .reviewAcceptanceProbe("filmflow.disconnect", state: available)
            }
            if !projects.isEmpty {
                Picker("FilmFlow project", selection: $projectID) {
                    Text("Choose a project").tag("")
                    ForEach(projects) { project in Text(project.title + " · " + project.role).tag(project.projectId) }
                }.disabled(!available).reviewAcceptanceProbe("filmflow.project", state: available, text: projectID)
                Button("Download snapshot") { run { try await capture() } }
                    .buttonStyle(InlineActionButtonStyle()).disabled(!available || projectID.isEmpty)
                    .reviewAcceptanceProbe("filmflow.download", state: available && !projectID.isEmpty)
            }
        }
    }

    private var retainedControls: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if !retained.isEmpty {
                Picker("Retained snapshot", selection: $snapshotID) {
                    Text("Choose a snapshot").tag(nil as UUID?)
                    ForEach(retained) { value in
                        Text(value.snapshot.project.title + " · " + value.snapshot.finishedAt.formatted()).tag(Optional(value.id))
                    }
                }.disabled(!available).reviewAcceptanceProbe("filmflow.snapshot", state: available, text: snapshotID?.uuidString ?? "")
                Button("Open retained snapshot") { run { try await openRetained() } }.buttonStyle(InlineActionButtonStyle())
                    .disabled(!available || current == nil).reviewAcceptanceProbe("filmflow.open-retained", state: available && current != nil)
            }
            Button("Reload current targets") { run { try await reload() } }.buttonStyle(InlineActionButtonStyle()).disabled(!available)
                .reviewAcceptanceProbe("filmflow.targets.reload", state: available)
        }
    }

    @ViewBuilder
    private func snapshotContent(_ snapshot: FilmFlowSnapshot, material: FilmFlowMaterial) -> some View {
        Text(snapshot.project.title).interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
        Text("Captured \(snapshot.startedAt.formatted()) – \(snapshot.finishedAt.formatted()). Separate read calls; matching metadata does not prove an atomic remote version.")
            .foregroundStyle(AppTheme.Text.secondaryColor)
        if snapshot.noActiveScript { Text("No active script. This snapshot contains project and entity material only.") }
        Text("FilmFlow provides descriptions and references, not the original screenplay or NexGenVideo approvals.")
        Text("Aspect ratio: \(material.project.aspectRatio) · Sketch style: \(material.project.sketchStyle). Current project settings are unchanged.")
        if let style = material.project.styleBible { Text(style).textSelection(.enabled) }
        DisclosureGroup("Omitted response fields (\(snapshot.responses.reduce(0) { $0 + $1.omissions.count }))") {
            ForEach(snapshot.responses, id: \.tool) { response in
                Text(response.tool + ": " + response.omissions.joined(separator: ", ")).textSelection(.enabled)
            }
            Text("Image addresses were removed after download. Unknown fields and omitted null fields are not interpreted.")
            Text("Response digests describe SDK-decoded UTF-8 text, not network bytes. Only the retained data and image files can be checked again offline.")
        }
            Picker("Source object", selection: $selectedObject) {
                Text("Choose an object").tag("")
                ForEach(Array(material.items.enumerated()), id: \.element.id) { index, source in
                    Text("\(index + 1). " + source.title).tag(source.id)
                }
            }.disabled(!available).reviewAcceptanceProbe("filmflow.source", state: available, text: selectedObject)
            if let item { itemContent(item) }
        if let prepared {
            ForEach(prepared.snapshot.missingImages) { missing in
                Toggle("Omit unavailable image: " + imageTitle(missing.pointer), isOn: Binding(
                    get: { omissions.contains(missing.pointer) },
                    set: { if $0 { omissions.insert(missing.pointer) } else { omissions.remove(missing.pointer) } }))
                    .disabled(!available).reviewAcceptanceProbe("filmflow.omit." + missing.pointer, state: available,
                                                               text: omissions.contains(missing.pointer) ? "true" : "false")
                Text(missing.reason).foregroundStyle(AppTheme.Text.secondaryColor)
            }
            Button("Accept snapshot into this project") { run(cancellable: false) {
                try requireProject()
                let accepted = try await FilmFlowSnapshotStore.accept(prepared, omittedImages: omissions, editor: editor)
                self.prepared = nil
                await Task.detached { prepared.discard() }.value
                try await reload(); snapshotID = accepted.id
                try await openRetained()
                message = "Snapshot retained. Choose and apply material in its current production phase. No phase was approved."
            } }.buttonStyle(InlineActionButtonStyle()).disabled(!mayAccept)
                .reviewAcceptanceProbe("filmflow.accept", state: mayAccept)
        }
        if current != nil, prepared == nil {
            if let targets { Text("Current phase: " + targets.phase).reviewAcceptanceProbe("filmflow.phase", text: targets.phase) }
            if let message = targets?.message { Text(message).foregroundStyle(AppTheme.Text.secondaryColor) }
            DisclosureGroup {
                ForEach(Array(material.items.enumerated()), id: \.element.id) { index, source in
                    Toggle("\(index + 1). " + source.title, isOn: Binding(get: { selectedObjects.contains(source.id) },
                        set: { if $0 { selectedObjects.insert(source.id) } else { selectedObjects.remove(source.id) } }))
                        .disabled(!available).reviewAcceptanceProbe("filmflow.notes." + source.id, state: available,
                            text: selectedObjects.contains(source.id) ? "true" : "false")
                }
                Button("Use selected planning notes in Brief") { run(cancellable: false) {
                    guard let current else { return }
                    try await FilmFlowAdoptionCoordinator.notes(current, selected: selectedObjects, editor: editor)
                    focusAdoptedPhase()
                    try await reload(); message = "Planning notes selected. Continue Brief normally; no original screenplay or approval was imported."
                } }.buttonStyle(InlineActionButtonStyle()).disabled(!mayAdoptNotes)
                    .reviewAcceptanceProbe("filmflow.notes.apply", state: mayAdoptNotes)
            } label: {
                Text("Planning notes: choose source objects").reviewAcceptanceProbe("filmflow.notes.open")
            }
        }
    }

    @ViewBuilder
    private func itemContent(_ item: FilmFlowMaterial.Item) -> some View {
        Text(item.notes).textSelection(.enabled).reviewAcceptanceProbe("filmflow.source.notes", text: item.notes)
        if let entity = item.entity {
            Text("FilmFlow confirmation: \(entity.isConfirmed ? "confirmed" : "unconfirmed"). This does not confirm the identity in NexGenVideo.")
        }
        if let image = item.image, let directory = prepared?.directory ?? current?.directory {
            ProductionInputPreview(reference: .init(id: image.id, role: "host.filmflow-source", path: image.path, sha256: image.sha256),
                                   dataRoot: directory, title: item.title)
        }
        if let current, prepared == nil, targets?.phase == "brief", let entity = item.entity,
           ["CHARACTER", "LOCATION"].contains(entity.type), item.image != nil {
            TextField("Local identity name", text: $identityName).disabled(!available)
                .reviewAcceptanceProbe("filmflow.identity.name", state: available, text: identityName)
            Toggle("I confirm this displayed image as the named identity", isOn: $identityConfirmed).disabled(!available)
                .reviewAcceptanceProbe("filmflow.identity.confirm", state: available, text: identityConfirmed ? "true" : "false")
            action("Confirm prepared identity", id: "filmflow.identity.apply",
                   enabled: identityConfirmed && !identityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                try await FilmFlowIdentityAdoption.confirm(current, sourceID: item.id, name: identityName,
                    explicitlyConfirmed: identityConfirmed, editor: editor)
            }
        }
        if current != nil, prepared == nil, let board = targets?.board, targets?.phase == "storyboard" {
            Picker("Target shot", selection: $targetShot) {
                Text("Choose a shot").tag("")
                ForEach(Array(board.timing.shots.enumerated()), id: \.element.id) { index, shot in Text("Shot \(index + 1)").tag(shot.id) }
            }.disabled(!available).reviewAcceptanceProbe("filmflow.target.shot", state: available, text: targetShot)
            if let shot = board.timing.shots.first(where: { $0.id == targetShot }) {
                Picker("Target sketch moment", selection: $targetMoment) {
                    Text("Choose a moment").tag("")
                    ForEach(shot.moments, id: \.id) { moment in Text(moment.intent).tag(moment.id) }
                }.disabled(!available).reviewAcceptanceProbe("filmflow.target.moment", state: available, text: targetMoment)
                action("Assign imported sketch", id: "filmflow.sketch.apply", enabled: item.image != nil && !targetMoment.isEmpty) {
                    guard let current else { return }
                    try await FilmFlowAdoptionCoordinator.sketch(current, item: item, shotID: targetShot,
                        momentID: targetMoment, expected: board, editor: editor)
                }
                if let duration = item.shot?.durationSeconds {
                    Text("Source duration: \(duration) seconds. Apply changes only this shot; the song range and neighbouring cuts remain fixed.")
                    action("Apply source shot duration", id: "filmflow.duration.apply", enabled: duration.isFinite && duration > 0) {
                        guard let current else { return }
                        try await FilmFlowAdoptionCoordinator.duration(current, item: item, shotID: targetShot, expected: board, editor: editor)
                    }
                }
            }
        }
        if current != nil, prepared == nil, let script = targets?.script {
            Picker("Target Script scene", selection: $targetScene) {
                Text("Choose a scene").tag("")
                ForEach(script.scenes, id: \.id) { scene in Text(scene.title).tag(scene.id) }
            }.disabled(!available).reviewAcceptanceProbe("filmflow.target.scene", state: available, text: targetScene)
            if let scene = script.scenes.first(where: { $0.id == targetScene }) {
                Picker("Target event", selection: $targetEvent) {
                    Text("Choose an event").tag("")
                    ForEach(scene.events, id: \.id) { event in Text(event.action).tag(event.id) }
                }.disabled(!available).reviewAcceptanceProbe("filmflow.target.event", state: available, text: targetEvent)
                Text("Replace the selected action with the displayed planning description. Existing treatment-beat bindings and dialogue remain; old text anchors are removed.")
                action("Replace selected event action", id: "filmflow.script.apply", enabled: !targetEvent.isEmpty && !item.notes.isEmpty) {
                    guard let current else { return }
                    try await FilmFlowAdoptionCoordinator.script(current, item: item, sceneID: targetScene,
                        eventID: targetEvent, expected: script, editor: editor)
                }
            }
        }
        if current != nil, prepared == nil, let plan = targets?.planning, item.shot != nil {
            Picker("Target planned shot", selection: $targetShot) {
                Text("Choose a shot").tag("")
                ForEach(Array(plan.shots.enumerated()), id: \.element.shotID) { index, shot in Text("Shot \(index + 1)").tag(shot.shotID) }
            }.disabled(!available).reviewAcceptanceProbe("filmflow.target.shot", state: available, text: targetShot)
            Picker("Confirm camera movement", selection: $movement) {
                Text("Choose supported movement").tag("")
                ForEach(CameraMovement.allCases, id: \.rawValue) { option in Text(option.rawValue.replacingOccurrences(of: "_", with: " ")).tag(option.rawValue) }
            }.disabled(!available).reviewAcceptanceProbe("filmflow.camera.movement", state: available, text: movement)
            Text("The displayed source notes are retained as movement detail. Source mode, reference obligations, spatial state and framing remain unchanged.")
            action("Apply camera movement and notes", id: "filmflow.camera.apply", enabled: !targetShot.isEmpty && CameraMovement(rawValue: movement) != nil) {
                guard let current, let choice = CameraMovement(rawValue: movement) else { return }
                try await FilmFlowAdoptionCoordinator.camera(current, item: item, shotID: targetShot,
                    movement: choice, expected: plan, editor: editor)
            }
        }
    }

    private func action(_ title: String, id: String, enabled: Bool, perform: @escaping @MainActor () async throws -> Void) -> some View {
        Button(title) { run(cancellable: false) { try requireProject(); try await perform(); focusAdoptedPhase(); try await reload(); message = "Material adopted. Use Edit → Undo to restore the previous native revision." } }
            .buttonStyle(InlineActionButtonStyle()).disabled(!available || !enabled || targets?.phase != editor.projectState?.nextPhaseName)
            .reviewAcceptanceProbe(id, state: available && enabled && targets?.phase == editor.projectState?.nextPhaseName)
    }

    private func connect() async throws {
        if let connect = configuration.connect { isolatedConnection = try await connect() }
        else {
            let start = try await FilmFlowOAuth.shared.begin()
            let callback = try await authenticate.authenticate(using: start.url, callback: .customScheme("nexgenvideo"),
                                                               preferredBrowserSession: .shared, additionalHeaderFields: [:])
            _ = try await FilmFlowOAuth.shared.finish(start, callback: callback)
        }
        try requireProject()
        try await readProjects()
    }

    private func readProjects() async throws {
        let previous = reader
        reader = nil; projects = []; projectID = ""
        await previous?.close()
        let connection: FilmFlowOAuth.Connection
        if let isolatedConnection { connection = isolatedConnection }
        else { connection = try await FilmFlowOAuth.shared.connection() }
        try requireProject()
        let active = configuration.makeReader(connection)
        reader = active
        let values = try await active.projects()
        try requireProject()
        projects = values; projectID = ""
        message = "Choose the FilmFlow project to capture. Reading never generates media or changes FilmFlow."
    }

    private func capture() async throws {
        guard let reader, let selected = projects.first(where: { $0.id == projectID }) else { return }
        let value = try await reader.capture(project: selected)
        do { try requireProject() } catch { await Task.detached { value.discard() }.value; throw error }
        let previous = prepared
        prepared = value; snapshotID = nil; loadedSnapshotID = value.snapshot.id
        await Task.detached { previous?.discard() }.value
        material = try await Task.detached { try FilmFlowMaterial.load(directory: value.directory, snapshot: value.snapshot) }.value
        omissions = []; selectedObjects = []; selectedObject = ""
        message = "Review the captured material and omissions before accepting this snapshot."
    }

    private func reload() async throws {
        try requireProject()
        guard let home, let root = DataRootResolver.dataRoot(of: home) else { return }
        let values = try await Task.detached { try FilmFlowSnapshotStore.list(dataRoot: root) }.value
        let target = try await FilmFlowAdoptionCoordinator.loadTargets(editor: editor)
        try requireProject()
        retained = values; targets = target
    }

    private func openRetained() async throws {
        guard let current else { return }
        let value = try await Task.detached {
            let snapshot = try FilmFlowSnapshot.verify(directory: current.directory, expectedSHA256: current.sha256)
            return try FilmFlowMaterial.load(directory: current.directory, snapshot: snapshot)
        }.value
        try requireProject()
        let previous = prepared; prepared = nil
        await Task.detached { previous?.discard() }.value
        material = value; loadedSnapshotID = current.id; selectedObjects = []; selectedObject = ""; omissions = []
    }

    private func resetMapping() { targetShot = ""; targetMoment = ""; targetScene = ""; targetEvent = ""; movement = ""; identityName = ""; identityConfirmed = false }
    private func focusAdoptedPhase() {
        editor.setWorkspaceFocus(.production)
        editor.productionSelectedPhase = targets?.phase
        editor.focusedPanel = .project
    }
    private func imageTitle(_ pointer: String) -> String { material?.items.first { pointer.hasPrefix($0.id + "/") }?.title ?? "Project reference" }
    private func requireProject() throws {
        try Task.checkCancellation()
        guard sameProject else { throw FilmFlowFailure.message("The target project changed. Close and reopen the import.") }
    }
    private func run(cancellable: Bool = true, _ body: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        failure = nil; message = ""
        operationCancellable = cancellable
        onBusyChanged(true)
        operation = Task { @MainActor in
            defer { operation = nil; onBusyChanged(false) }
            do { try await body() }
            catch is CancellationError { message = "Operation cancelled." }
            catch { failure = error.localizedDescription }
        }
    }
}
