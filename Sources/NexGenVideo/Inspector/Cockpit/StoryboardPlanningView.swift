import NexGenEngine
import SwiftUI
import UniformTypeIdentifiers

struct StoryboardPlanningView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var snapshot: StoryboardBundleSnapshot?
    @State private var sketches: [String: CGImage] = [:]
    @State private var failure: String?
    @State private var loading = false
    @State private var animatic = false
    @State private var playback = StoryboardAnimaticController()
    @State private var sketchImport: SketchImport?
    @State private var showingImport = false
    @State private var importing = false
    @State private var importFailure: String?
    @State private var loadGeneration = 0
    @State private var editRequest: StoryboardNativeEditRequest?
    @State private var imageInspection: SketchInspection?
    @State private var deletingShot: StoryboardTimingV1.PlannedShot?
    @State private var spatialSketch: SpatialSketch?
    @State private var nativeSketch: NativeSketch?

    private struct NativeSketch: Identifiable {
        let id = UUID()
        let target: SpatialSketch
        let mode: StoryboardNativeSketchSheet.Mode
    }

    private struct SpatialSketch: Identifiable {
        let id = UUID()
        let home: URL
        let shotID: String
        let momentID: String
        let intent: String
        let fingerprint: String
    }

    private struct SketchInspection: Identifiable {
        let id = UUID()
        let url: URL
        let sha256: String
        let title: String
    }

    private struct SketchImport {
        let shotID: String
        let momentID: String
        let fingerprint: String
        let home: URL
    }

    private var canAttachSketch: Bool {
        guard !loading, !importing, !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              editor.projectState?.nextPhaseName == "storyboard",
              let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            HStack {
                Picker("Storyboard view", selection: $animatic) {
                    Text("Board").tag(false)
                    Text("Animatic").tag(true)
                }.pickerStyle(.segmented).reviewAcceptanceProbe("storyboard.view", state: animatic)
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            if let snapshot {
                HStack(spacing: AppTheme.Spacing.md) {
                    Button("Undo") { history(redo: false, snapshot: snapshot) }
                        .disabled(!canAttachSketch || !PipelineStoryboardEditor.canUndo(editor: editor))
                        .reviewAcceptanceProbe("storyboard.undo", state: canAttachSketch && PipelineStoryboardEditor.canUndo(editor: editor))
                    Button("Redo") { history(redo: true, snapshot: snapshot) }
                        .disabled(!canAttachSketch || !PipelineStoryboardEditor.canRedo(editor: editor))
                        .reviewAcceptanceProbe("storyboard.redo", state: canAttachSketch && PipelineStoryboardEditor.canRedo(editor: editor))
                    Spacer(minLength: AppTheme.Spacing.sm)
                    if !canAttachSketch && editor.projectState?.nextPhaseName != "storyboard" {
                        Text("Reopen Storyboard to edit.").foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                }.buttonStyle(InlineActionButtonStyle()).padding(.horizontal, AppTheme.Spacing.lg)
            }
            if let importFailure { Text(importFailure).foregroundStyle(AppTheme.Status.errorColor).padding(.horizontal, AppTheme.Spacing.lg) }
            if let failure {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text(failure).foregroundStyle(AppTheme.Status.errorColor)
                    Button("Reload Storyboard") { Task { await load() } }.buttonStyle(InlineActionButtonStyle())
                }.padding(AppTheme.Spacing.lg)
            } else if let snapshot {
                if animatic { animaticView(snapshot) } else { board(snapshot) }
            } else if !loading {
                CockpitStateView.empty(icon: "rectangle.split.3x1", title: "No Storyboard yet",
                    message: "The Storyboard combines the Script, planned cuts and sketches for visual review.")
            }
        }
        .padding(.top, AppTheme.Spacing.md)
        .interfaceFont(size: AppTheme.Typography.ui)
        .reviewAcceptanceProbe("storyboard.v2.workspace", text: snapshot?.fingerprint)
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision)") { await load() }
        .onChange(of: animatic) { _, active in
            playback.pause()
            editor.storyboardAnimaticPlayback = active ? playback : nil
        }
        .onAppear { if animatic { editor.storyboardAnimaticPlayback = playback } }
        .onDisappear {
            playback.pause()
            if editor.storyboardAnimaticPlayback === playback { editor.storyboardAnimaticPlayback = nil }
        }
        .sheet(item: $editRequest, onDismiss: { Task { await load() } }) { request in
            StoryboardNativeEditSheet(request: request).environment(editor)
        }
        .sheet(item: $imageInspection) { image in
            ProductionImageInspectionView(url: image.url, sha256: image.sha256, title: image.title)
        }
        .sheet(item: $spatialSketch, onDismiss: { Task { await load() } }) { target in
            StoryboardSpatialSketchSheet(home: target.home, shotID: target.shotID, momentID: target.momentID,
                intent: target.intent, fingerprint: target.fingerprint).environment(editor)
        }
        .sheet(item: $nativeSketch, onDismiss: { Task { await load() } }) { request in
            StoryboardNativeSketchSheet(home: request.target.home, shotID: request.target.shotID,
                momentID: request.target.momentID, intent: request.target.intent, fingerprint: request.target.fingerprint,
                mode: request.mode).environment(editor)
        }
        .confirmationDialog("Delete this planned shot?", isPresented: Binding(
            get: { deletingShot != nil }, set: { if !$0 { deletingShot = nil } }), titleVisibility: .visible) {
            if let shot = deletingShot, let snapshot {
                Button("Delete shot", role: .destructive) { apply(.delete(shotID: shot.id), snapshot: snapshot); deletingShot = nil }
            }
            Button("Cancel", role: .cancel) { deletingShot = nil }
        } message: {
            Text("Other cuts keep their positions. Story steps must remain assigned to another shot. You can undo this change.")
        }
        .fileImporter(isPresented: $showingImport, allowedContentTypes: [.image]) { result in
            guard let target = sketchImport else { return }
            sketchImport = nil
            switch result {
            case .failure(let error): importFailure = error.localizedDescription
            case .success(let url):
                importing = true; importFailure = nil
                Task {
                    defer { importing = false }
                    guard editor.workingRoot == target.home else { importFailure = "The project changed. Choose the sketch again."; return }
                    do {
                        _ = try await PipelineStoryboardEditor.attachImage(from: url, shotID: target.shotID,
                            momentID: target.momentID, expectedFingerprint: target.fingerprint, editor: editor)
                        await load()
                    } catch { importFailure = error.localizedDescription }
                }
            }
        }
    }

    private func nativeSource(_ mode: StoryboardNativeSketchSheet.Mode, shot: StoryboardTimingV1.PlannedShot,
                              moment: StoryboardTimingV1.Moment, snapshot: StoryboardBundleSnapshot) {
        guard canAttachSketch, let home = editor.workingRoot else { return }
        nativeSketch = .init(target: .init(home: home, shotID: shot.id, momentID: moment.id,
            intent: moment.intent, fingerprint: snapshot.fingerprint), mode: mode)
    }

    private func board(_ snapshot: StoryboardBundleSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                Text(snapshot.storyboard.summary).textSelection(.enabled)
                ForEach(Array(snapshot.timing.shots.enumerated()), id: \.element.id) { index, shot in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        HStack {
                            Button("Shot \(index + 1)") {
                                select(shot: shot, number: index + 1, snapshot: snapshot)
                            }
                            .buttonStyle(InlineActionButtonStyle())
                            .accessibilityLabel("Inspect Shot \(index + 1)")
                            .accessibilityAddTraits(editor.storyboardPlanningSelection?.shot.id == shot.id ? .isSelected : [])
                            Spacer(minLength: AppTheme.Spacing.sm)
                            Text(duration(shot.durationTicks)).foregroundStyle(AppTheme.Text.secondaryColor)
                            Menu("Edit shot") {
                                Button("Timing…") { edit(.timing, shot: shot, snapshot: snapshot) }
                                Button("Framing…") { edit(.framing, shot: shot, snapshot: snapshot) }
                                Button("Story steps…") { edit(.steps, shot: shot, snapshot: snapshot) }
                                Divider()
                                Button("Move earlier") { moveShot(index, offset: -1, snapshot: snapshot) }.disabled(index == 0)
                                Button("Move later") { moveShot(index, offset: 1, snapshot: snapshot) }.disabled(index + 1 == snapshot.timing.shots.count)
                                Button("Split…") { edit(.split, shot: shot, snapshot: snapshot) }.disabled(snapshot.timing.mode == .multicam)
                                Button("Duplicate…") { edit(.duplicate, shot: shot, snapshot: snapshot) }.disabled(snapshot.timing.mode == .multicam)
                                Button("Delete shot…", role: .destructive) { deletingShot = shot }
                            }.disabled(!canAttachSketch).reviewAcceptanceProbe("storyboard.shot.edit.\(shot.id)")
                            Button("Open in Animatic") { playback.seek(to: shot.startTicks); playback.cameraID = shot.cameraID; animatic = true }
                                .buttonStyle(InlineActionButtonStyle())
                                .reviewAcceptanceProbe("storyboard.animatic.\(shot.id)")
                        }
                        ForEach(snapshot.storyboard.steps.filter { shot.stepIDs.contains($0.id) }, id: \.id) { step in
                            Text(step.action).textSelection(.enabled)
                            if let binding = snapshot.causality.bindings.first(where: { $0.stepID == step.id }) {
                                Button("Edit action…") { edit(.action(step, binding), shot: shot, snapshot: snapshot) }
                                    .buttonStyle(InlineActionButtonStyle()).disabled(!canAttachSketch)
                            }
                        }
                        Text("\(shot.framing.scale) · \(shot.framing.cameraView) · \(shot.framing.composition)")
                            .foregroundStyle(AppTheme.Text.secondaryColor).textSelection(.enabled)
                        if shot.moments.isEmpty {
                            Label("Sketches are required before Storyboard approval.", systemImage: "photo.badge.exclamationmark")
                                .foregroundStyle(AppTheme.Status.warningColor)
                        }
                        ForEach(Array(shot.moments.enumerated()), id: \.element.id) { momentIndex, moment in
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                Text("Moment \(momentIndex + 1) · \(duration(moment.offsetTicks))").fontWeight(AppTheme.FontWeight.medium)
                                if let image = sketches[moment.id] {
                                    Button {
                                        guard let asset = moment.asset, let home = editor.workingRoot,
                                              let root = DataRootResolver.dataRoot(of: home) else { return }
                                        imageInspection = .init(url: root.appendingPathComponent(asset.image.path),
                                            sha256: asset.image.sha256, title: moment.intent)
                                    } label: {
                                        Image(image, scale: 1, label: Text(moment.intent)).resizable().aspectRatio(contentMode: .fit)
                                            .frame(height: AppTheme.Layout.previewMinHeight)
                                    }.buttonStyle(.plain).accessibilityLabel("Inspect sketch: \(moment.intent)")
                                    .reviewAcceptanceProbe("storyboard.sketch.inspect.\(moment.id)")
                                } else {
                                    Label(moment.asset == nil ? "Sketch missing" : "Sketch unavailable", systemImage: "photo.badge.exclamationmark")
                                        .foregroundStyle(AppTheme.Status.warningColor)
                                }
                                if let problem = snapshot.sketchProblems[moment.id] {
                                    Text(problem).foregroundStyle(AppTheme.Status.warningColor).textSelection(.enabled)
                                }
                                Text(moment.intent).textSelection(.enabled)
                                Button(moment.asset == nil ? "Choose sketch…" : "Replace sketch…") {
                                    guard let home = editor.workingRoot else { return }
                                    sketchImport = SketchImport(shotID: shot.id, momentID: moment.id,
                                        fingerprint: snapshot.fingerprint, home: home)
                                    showingImport = true
                                }
                                .buttonStyle(InlineActionButtonStyle())
                                .disabled(!canAttachSketch)
                                .help(canAttachSketch ? "Attach an image to this planned moment." : "Reopen Storyboard before changing approved sketches.")
                                .reviewAcceptanceProbe("storyboard.sketch.import.\(moment.id)", state: canAttachSketch)
                                Menu("Other sketch sources") {
                                    Button("Capture source video frame…") { nativeSource(.sourceFrame, shot: shot, moment: moment, snapshot: snapshot) }
                                    Button("Import external sketch…") { nativeSource(.external, shot: shot, moment: moment, snapshot: snapshot) }
                                    Button("Create from location…") {
                                        guard let home = editor.workingRoot else { return }
                                        spatialSketch = .init(home: home, shotID: shot.id, momentID: moment.id,
                                            intent: moment.intent, fingerprint: snapshot.fingerprint)
                                    }
                                }.disabled(!canAttachSketch)
                                .reviewAcceptanceProbe("storyboard.sketch.sources.\(moment.id)", state: canAttachSketch)
                                Menu("Edit moment") {
                                    Button("Timing and action…") { edit(.moment(moment), shot: shot, snapshot: snapshot) }
                                    Button("Move earlier") { moveMoment(momentIndex, offset: -1, shot: shot, snapshot: snapshot) }
                                        .disabled(momentIndex == 0)
                                    Button("Move later") { moveMoment(momentIndex, offset: 1, shot: shot, snapshot: snapshot) }
                                        .disabled(momentIndex + 1 == shot.moments.count)
                                    if moment.asset != nil {
                                        Button("Remove image") { apply(.removeSketch(shotID: shot.id, momentID: moment.id), snapshot: snapshot) }
                                    }
                                    Button("Delete moment", role: .destructive) {
                                        apply(.deleteMoment(shotID: shot.id, momentID: moment.id), snapshot: snapshot)
                                    }.disabled(shot.moments.count <= 1)
                                }.disabled(!canAttachSketch)
                            }
                            .reviewAcceptanceProbe("storyboard.moment.\(moment.id)", text: snapshot.sketchProblems[moment.id] == nil
                                ? moment.asset?.image.sha256 ?? "missing" : "unavailable")
                        }
                        Button("Add sketch moment…") { edit(.addMoment, shot: shot, snapshot: snapshot) }
                            .buttonStyle(InlineActionButtonStyle()).disabled(!canAttachSketch)
                            .reviewAcceptanceProbe("storyboard.moment.add.\(shot.id)")
                    }
                    .padding(AppTheme.Spacing.lg)
                    .background(AppTheme.Background.raisedColor)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                    .reviewAcceptanceProbe("storyboard.plan.\(shot.id)", text: shot.primaryStepID)
                }
            }.padding(AppTheme.Spacing.lg)
        }
    }

    private func animaticView(_ snapshot: StoryboardBundleSnapshot) -> some View {
        @Bindable var playback = playback
        return VStack(spacing: AppTheme.Spacing.md) {
            if snapshot.timing.mode == .multicam {
                Picker("Camera", selection: $playback.cameraID) {
                    ForEach(snapshot.timing.shots, id: \.id) { shot in
                        Text(shot.cameraID ?? shot.id).tag(shot.cameraID)
                    }
                }.pickerStyle(.menu)
            }
            Group {
                if let moment = playback.activeMoment, let asset = moment.asset, let image = sketches[moment.id] {
                    Image(image, scale: 1, label: Text(moment.intent)).resizable().aspectRatio(contentMode: .fit)
                        .reviewAcceptanceProbe("animatic.image", text: "\(moment.id):\(asset.image.sha256)")
                } else {
                    CockpitStateView.empty(icon: "rectangle.slash", title: playback.tick >= playback.endTick ? "End of Animatic" : "No sketch at this time",
                        message: playback.tick >= playback.endTick ? "Play to start again." : "This interval has no image. Add the required sketch before visual approval.")
                }
            }
            .frame(maxWidth: .infinity, minHeight: AppTheme.Spacing.none, maxHeight: .infinity)
            .clipped()
            if let failure = playback.failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor) }
            if let moment = playback.activeMoment { Text(moment.intent).textSelection(.enabled) }
            HStack {
                Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                    if playback.isPlaying { playback.pause() } else { Task { await playback.play() } }
                }
                .buttonStyle(InlineActionButtonStyle())
                .disabled(playback.isPreparing || playback.timing == nil)
                .reviewAcceptanceProbe("animatic.play", state: !playback.isPreparing && playback.timing != nil)
                Slider(value: Binding(get: { Double(playback.tick) }, set: { value in
                    let start = snapshot.timing.rangeStartTicks, end = playback.endTick
                    playback.seek(to: value >= Double(end) ? end : value <= Double(start) ? start : Int64(value))
                }), in: Double(snapshot.timing.rangeStartTicks)...Double(snapshot.timing.rangeStartTicks + snapshot.timing.rangeDurationTicks))
                .disabled(playback.timing == nil || playback.isPreparing)
                .accessibilityLabel("Animatic position")
                Text("\(duration(playback.tick)) / \(duration(playback.endTick))").monospacedDigit()
            }
            Text(snapshot.timing.audio == nil ? "No audio assigned" : "Storyboard audio")
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.bottom, AppTheme.Spacing.lg)
        .reviewAcceptanceProbe("animatic.workspace", text: String(playback.tick))
    }

    private func duration(_ tick: Int64) -> String {
        guard let timing = snapshot?.timing else { return "–" }
        return String(format: "%.2f s", timing.timebase.seconds(for: tick))
    }

    private func edit(_ kind: StoryboardNativeEditRequest.Kind, shot: StoryboardTimingV1.PlannedShot, snapshot: StoryboardBundleSnapshot) {
        guard canAttachSketch, let home = editor.workingRoot else { return }
        playback.pause()
        editRequest = .init(kind: kind, shot: shot, snapshot: snapshot, home: home)
    }

    private func moveShot(_ index: Int, offset: Int, snapshot: StoryboardBundleSnapshot) {
        var ids = snapshot.timing.shots.map(\.id)
        guard ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        apply(.reorder(shotIDs: ids), snapshot: snapshot)
    }

    private func moveMoment(_ index: Int, offset: Int, shot: StoryboardTimingV1.PlannedShot, snapshot: StoryboardBundleSnapshot) {
        var ids = shot.moments.map(\.id)
        guard ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        apply(.reorderMoments(shotID: shot.id, momentIDs: ids), snapshot: snapshot)
    }

    private func apply(_ command: PipelineStoryboardEditor.Command, snapshot: StoryboardBundleSnapshot) {
        guard canAttachSketch else { return }
        playback.pause()
        importing = true
        Task {
            defer { importing = false }
            do {
                _ = try await PipelineStoryboardEditor.apply(command, expectedFingerprint: snapshot.fingerprint, editor: editor)
                importFailure = nil
                await load()
            } catch { importFailure = error.localizedDescription }
        }
    }

    private func history(redo: Bool, snapshot: StoryboardBundleSnapshot) {
        guard canAttachSketch else { return }
        playback.pause()
        importing = true
        Task {
            defer { importing = false }
            do {
                if redo { _ = try await PipelineStoryboardEditor.redo(expectedFingerprint: snapshot.fingerprint, editor: editor) }
                else { _ = try await PipelineStoryboardEditor.undo(expectedFingerprint: snapshot.fingerprint, editor: editor) }
                importFailure = nil
                await load()
            } catch { importFailure = error.localizedDescription }
        }
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let home = editor.workingRoot
        let selectedID = editor.storyboardPlanningSelection?.home == home ? editor.storyboardPlanningSelection?.shot.id : nil
        editor.storyboardPlanningSelection = nil
        playback.pause(); snapshot = nil; sketches = [:]; loading = true; failure = nil
        defer { if generation == loadGeneration { loading = false } }
        guard let home, let root = DataRootResolver.dataRoot(of: home) else { snapshot = nil; return }
        do {
            _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: editor.declaredPluginName,
                declaredBinding: editor.declaredPluginBinding, declaredProductionContract: editor.declaredProductionContract)
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(StoryboardV2.currentPath).path) else { snapshot = nil; return }
            let value = try await Task.detached(priority: .userInitiated) {
                let snapshot = try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false)
                return (snapshot, try ProductionPlanningPresentation.sketchImages(snapshot, dataRoot: root))
            }.value
            guard generation == loadGeneration, !Task.isCancelled, editor.workingRoot == home else { return }
            await playback.configure(value.0.timing, dataRoot: root)
            guard generation == loadGeneration, !Task.isCancelled, editor.workingRoot == home else { return }
            sketches = value.1; snapshot = value.0
            if let selectedID, let index = value.0.timing.shots.firstIndex(where: { $0.id == selectedID }) {
                select(shot: value.0.timing.shots[index], number: index + 1, snapshot: value.0)
            }
        } catch {
            guard generation == loadGeneration, !Task.isCancelled, editor.workingRoot == home else { return }
            snapshot = nil; failure = error.localizedDescription
        }
    }

    private func select(shot: StoryboardTimingV1.PlannedShot, number: Int, snapshot: StoryboardBundleSnapshot) {
        guard let home = editor.workingRoot else { return }
        editor.storyboardPlanningSelection = .init(home: home, fingerprint: snapshot.fingerprint, shot: shot, number: number,
            steps: snapshot.storyboard.steps.filter { shot.stepIDs.contains($0.id) }, timebase: snapshot.timing.timebase)
    }
}
