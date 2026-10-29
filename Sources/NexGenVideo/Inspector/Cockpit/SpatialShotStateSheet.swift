import BpyRuntimeProtocol
import NexGenEngine
import RealityKit
import SwiftUI
import simd

struct SpatialShotStateSheet: View {
    let home: URL
    let shotID: String
    let number: Int
    var onSaved: (ShotPlanningDraftV1) -> Void = { _ in }
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var scenes: [SpatialSceneHead] = []
    @State private var sceneID: UUID?
    @State private var cameraID: String?
    @State private var context: PipelineSpatialDerivationWriter.PlanningContext?
    @State private var timeline: SpatialShotPoseTimeline?
    @State private var frame = 0
    @State private var objectID: String?
    @State private var poseEdit = SpatialShotPoseEdit()
    @State private var loading = false
    @State private var saving = false
    @State private var failure: String?
    @State private var resetting = false
    @State private var reducingKeyframes = false
    @State private var reloadToken = 0
    @State private var reloadingState = false

    private var camera: BpySpatialCamera? { context?.scene.snapshot.cameras.first { $0.id == cameraID } }
    private var pose: SpatialClayStateFrame? { try? timeline?.resolved(at: frame) }
    private var pendingTransform: Bool { poseEdit.hasChanges }
    private var active: Bool {
        guard !loading, !saving, editor.workingRoot == home, editor.projectState?.nextPhaseName == "shot_planning",
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let root = DataRootResolver.dataRoot(of: home) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    private var canChooseLocation: Bool { active && timeline == nil && !scenes.isEmpty }
    private var canChooseCamera: Bool { active && timeline == nil && context != nil }
    private var canConfirm: Bool { active && timeline != nil && context != nil && cameraID != nil && !pendingTransform }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Spatial shot state · Shot \(number)")
                .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    if loading { ProgressView("Reading verified locations…") }
                    Picker("Location", selection: $sceneID) {
                        Text("Choose location").tag(UUID?.none)
                        ForEach(scenes) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(!canChooseLocation)
                        .reviewAcceptanceProbe("shot-planning.spatial.location", state: canChooseLocation, text: sceneID?.uuidString ?? "")
                    Picker("Camera", selection: $cameraID) {
                        Text("Choose camera").tag(String?.none)
                        ForEach(context?.scene.snapshot.cameras ?? []) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(!canChooseCamera)
                        .reviewAcceptanceProbe("shot-planning.spatial.camera", state: canChooseCamera, text: cameraID ?? "")
                    if let context, let camera {
                        SpatialShotPosePreview(snapshot: context.scene.snapshot,
                            pose: pose ?? scenePose(context, camera: camera), camera: camera, selectedObjectID: objectID)
                            .frame(minHeight: AppTheme.Layout.previewMinHeight)
                            .reviewAcceptanceProbe("shot-planning.spatial.preview", text: String(frame))
                        if let timeline {
                            if timeline.frameCount > 1 {
                                Slider(value: Binding(get: { Double(frame) }, set: { frame = Int($0.rounded()) }),
                                    in: 0...Double(timeline.frameCount - 1), step: 1)
                                    .disabled(!active || pendingTransform)
                                    .reviewAcceptanceProbe("shot-planning.spatial.scrubber", state: active && !pendingTransform, text: String(frame))
                            }
                            Stepper("Frame \(frame + 1) of \(timeline.frameCount)", value: $frame, in: 0...(timeline.frameCount - 1))
                                .disabled(!active || pendingTransform)
                                .reviewAcceptanceProbe("shot-planning.spatial.frame", state: active && !pendingTransform, text: String(frame))
                            Text("\(timeline.keyframes.count) keyframes · \(timeline.keyframes.keys.sorted().prefix(8).map { String($0 + 1) }.joined(separator: ", "))")
                                .lineLimit(2).foregroundStyle(AppTheme.Text.secondaryColor)
                                .reviewAcceptanceProbe("shot-planning.spatial.keyframes", text: timeline.keyframes.keys.sorted().map(String.init).joined(separator: ","))
                            Picker("Object", selection: $objectID) {
                                Text("Choose object").tag(String?.none)
                                ForEach(context.scene.snapshot.objects) { Text($0.name).tag(Optional($0.id)) }
                            }.disabled(!active || pendingTransform)
                                .reviewAcceptanceProbe("shot-planning.spatial.object", state: active && !pendingTransform, text: objectID ?? "")
                            if poseEdit.transformEditable {
                                vectors("Position", $poseEdit.position)
                                vectors("Rotation (degrees)", $poseEdit.rotation)
                                vectors("Scale", $poseEdit.scale)
                            }
                            if let message = poseEdit.failure { Text(message).foregroundStyle(AppTheme.Status.warningColor) }
                            TextField("Camera vertical field of view (degrees)", value: $poseEdit.fieldOfView, format: .number)
                                .disabled(!active)
                                .reviewAcceptanceProbe("shot-planning.spatial.fov", state: active, text: String(poseEdit.fieldOfView))
                            HStack {
                                Button("Set keyframe") { setKeyframe() }.buttonStyle(InlineActionButtonStyle())
                                    .disabled(!active || !poseEdit.canSetKeyframe)
                                    .reviewAcceptanceProbe("shot-planning.spatial.set", state: active && poseEdit.canSetKeyframe)
                                Button("Remove keyframe") { removeKeyframe() }.buttonStyle(InlineActionButtonStyle())
                                    .disabled(!active || frame == 0 || frame == timeline.frameCount - 1 || timeline.keyframes[frame] == nil || pendingTransform)
                                    .reviewAcceptanceProbe("shot-planning.spatial.remove", state: active && frame > 0 && frame < timeline.frameCount - 1 && timeline.keyframes[frame] != nil && !pendingTransform)
                            }
                            Text("Position and scale interpolate linearly; rotation follows the shortest quaternion path. Each frame keeps every object and the selected camera.")
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                            if timeline.keyframes.count > 2 {
                                Button("Keep only start and end keyframes…") { reducingKeyframes = true }
                                    .buttonStyle(InlineActionButtonStyle()).disabled(!active || pendingTransform)
                            }
                            if pendingTransform {
                                Text("Set the keyframe or discard the transform edits before changing frame or object.").foregroundStyle(AppTheme.Status.warningColor)
                                Button("Discard transform edits") { updateInspector() }.buttonStyle(InlineActionButtonStyle()).disabled(!active)
                                    .reviewAcceptanceProbe("shot-planning.spatial.discard", state: active)
                            }
                            Button("Choose another location or camera…") { resetting = true }.buttonStyle(InlineActionButtonStyle()).disabled(!active)
                        } else {
                            Text("Saved location pose at source frame \(context.scene.snapshot.frame). Confirm this starting pose, then set the shot's camera and object keyframes.")
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                            Button("Use this pose throughout the shot") { seed(context, camera: camera) }
                                .buttonStyle(InlineActionButtonStyle()).disabled(!active)
                                .reviewAcceptanceProbe("shot-planning.spatial.initialize", state: active)
                        }
                    }
                    if scenes.isEmpty && !loading {
                        Text("Create a location and camera in Production Design first.").foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    if let failure {
                        Text(failure).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled)
                            .reviewAcceptanceProbe("shot-planning.spatial.failure", text: failure)
                        Button("Reload saved shot state…") { reloadingState = true }
                            .buttonStyle(InlineActionButtonStyle()).disabled(!active)
                    }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(InlineActionButtonStyle()).keyboardShortcut(.cancelAction).disabled(saving)
                    .reviewAcceptanceProbe("shot-planning.spatial.cancel", state: !saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Confirm shot state") { save() }.buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(!canConfirm).reviewAcceptanceProbe("shot-planning.spatial.confirm", state: canConfirm)
            }
        }
        .padding(AppTheme.Spacing.lg).interfaceFont(size: AppTheme.Typography.ui)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        .reviewAcceptanceProbe("shot-planning.spatial.sheet", text: shotID)
        .task { await loadLocations() }
        .task(id: "\(sceneID?.uuidString ?? "none"):\(reloadToken)") { await loadScene() }
        .onChange(of: frame) { _, _ in updateInspector() }
        .onChange(of: objectID) { _, _ in updateInspector() }
        .onChange(of: editor.workingRoot) { _, value in if value != home { dismiss() } }
        .interactiveDismissDisabled(saving)
        .confirmationDialog("Discard these shot-state edits?", isPresented: $resetting, titleVisibility: .visible) {
            Button("Discard edits", role: .destructive) { timeline = nil; frame = 0; objectID = nil; cameraID = nil }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The saved Shot Planning stays unchanged until you confirm a new state.") }
        .confirmationDialog("Reload the saved shot state?", isPresented: $reloadingState, titleVisibility: .visible) {
            Button("Reload saved state", role: .destructive) { failure = nil; reloadToken += 1 }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This replaces the unsaved poses and keyframes in this window with the current saved state.") }
        .confirmationDialog("Replace the intermediate motion?", isPresented: $reducingKeyframes, titleVisibility: .visible) {
            Button("Keep start and end", role: .destructive) {
                guard let timeline, let first = timeline.keyframes[0], let last = timeline.keyframes[timeline.frameCount - 1] else { return }
                self.timeline = .init(frameCount: timeline.frameCount, keyframes: [0: first, last.frame: last])
                frame = 0; updateInspector()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The motion between these poses will be interpolated again. The saved shot stays unchanged until you confirm it.") }
    }

    private func vectors(_ title: String, _ value: Binding<SIMD3<Double>>) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(title)
            HStack {
                ForEach(0..<3, id: \.self) { axis in
                    TextField(["X", "Y", "Z"][axis], value: Binding(get: { value.wrappedValue[axis] },
                        set: { value.wrappedValue[axis] = $0 }), format: .number)
                        .reviewAcceptanceProbe("shot-planning.spatial.\(title.lowercased()).\(axis)", state: active, text: String(value.wrappedValue[axis]))
                }
            }
        }.disabled(!active)
    }

    private func scenePose(_ context: PipelineSpatialDerivationWriter.PlanningContext, camera: BpySpatialCamera) -> SpatialClayStateFrame {
        .init(frame: 0, objects: context.scene.snapshot.objects.map { .init(objectID: $0.id, matrixWorld: $0.matrixWorld) },
            cameraVerticalFieldOfView: camera.verticalFieldOfView)
    }

    private func seed(_ context: PipelineSpatialDerivationWriter.PlanningContext, camera: BpySpatialCamera) {
        let first = scenePose(context, camera: camera)
        let last = SpatialClayStateFrame(frame: context.frameCount - 1, objects: first.objects,
            cameraVerticalFieldOfView: first.cameraVerticalFieldOfView)
        timeline = .init(frameCount: context.frameCount, keyframes: context.frameCount == 1 ? [0: first] : [0: first, last.frame: last])
        objectID = camera.id; frame = 0; updateInspector(); failure = nil
    }

    private func setKeyframe() {
        guard active, poseEdit.canSetKeyframe else { return }
        do {
            timeline?.keyframes[frame] = try poseEdit.applying()
            updateInspector(); failure = nil
        } catch { failure = error.localizedDescription }
    }

    private func removeKeyframe() {
        guard let timeline, frame > 0, frame < timeline.frameCount - 1 else { return }
        self.timeline?.keyframes.removeValue(forKey: frame)
        updateInspector()
    }

    private func updateInspector() {
        poseEdit = SpatialShotPoseEdit(pose: pose, objectID: objectID)
    }

    private func loadLocations() async {
        guard let root = DataRootResolver.dataRoot(of: home), editor.workingRoot == home else { return }
        loading = true
        defer { loading = false }
        do {
            let shotID = shotID
            let value = try await Task.detached(priority: .userInitiated) {
                try PipelineSpatialSceneAuthority.requireCurrent(dataRoot: root)
                let scenes = try SpatialSceneStore.index(in: root).scenes
                let storyboard = try PlanningWriterIO.storyboard(dataRoot: root)
                let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: storyboard)
                let path = draft.shots.first(where: { $0.shotID == shotID })?.camera.sceneReference?.path
                let selected = scenes.first { SpatialSceneStore.revisionPath(scene: $0.id, revision: $0.revision) + "/scene.blend" == path }
                return (scenes, selected?.id)
            }.value
            guard !Task.isCancelled, editor.workingRoot == home else { return }
            scenes = value.0; sceneID = value.1
        } catch { failure = error.localizedDescription }
    }

    private func loadScene() async {
        context = nil; timeline = nil; cameraID = nil; objectID = nil; frame = 0
        loading = false
        guard let scene = scenes.first(where: { $0.id == sceneID }), let root = DataRootResolver.dataRoot(of: home) else { return }
        loading = true
        defer { if sceneID == scene.id { loading = false } }
        do {
            let shotID = shotID
            let value = try await Task.detached(priority: .userInitiated) {
                let context = try PipelineSpatialDerivationWriter.planningContext(shotID: shotID, scene: scene, dataRoot: root)
                var timeline: SpatialShotPoseTimeline?
                var stateFailure: String?
                if let reference = context.shot.camera.spatialState, let cameraID = context.shot.camera.spatialCameraID,
                   let source = context.shot.camera.sceneReference, source.path == context.sceneReference.path {
                    do {
                        timeline = try PipelineSpatialDerivationWriter.planningPoseTimeline(reference: reference, cameraID: cameraID,
                            sceneReference: source, shotID: shotID, dataRoot: root)
                    } catch {
                        stateFailure = "The saved shot state no longer matches. Choose a camera and confirm a new state. \(error.localizedDescription)"
                    }
                }
                return (context, timeline, stateFailure)
            }.value
            guard !Task.isCancelled, sceneID == scene.id, editor.workingRoot == home else { return }
            context = value.0; failure = value.2
            if let timeline = value.1 {
                cameraID = value.0.shot.camera.spatialCameraID
                self.timeline = timeline
                objectID = cameraID; updateInspector()
            }
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }

    private func save() {
        guard active, !pendingTransform, let context, let timeline, let cameraID else { return }
        saving = true; failure = nil
        Task {
            defer { saving = false }
            do {
                let state = try await Task.detached(priority: .userInitiated) {
                    try timeline.resolve(sceneManifestSHA256: FileDigest.sha256(of: context.scene.manifestData), cameraID: cameraID)
                }.value
                let saved = try await PipelineSpatialDerivationWriter.recordPlanningState(state, context: context, editor: editor,
                    authoringFrames: timeline.keyframes.keys.sorted())
                onSaved(saved)
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}

private struct SpatialShotPosePreview: View {
    let snapshot: BpySpatialSnapshot
    let pose: SpatialClayStateFrame
    let camera: BpySpatialCamera
    let selectedObjectID: String?
    @State private var root = Entity()
    @State private var viewCamera = Entity()
    @State private var failure: String?

    var body: some View {
        RealityView { content in
            content.add(root); content.add(viewCamera); update()
        }.onChange(of: pose) { _, _ in update() }
            .onChange(of: selectedObjectID) { _, _ in update() }
            .onChange(of: camera) { _, _ in update() }
            .aspectRatio(CGFloat(camera.width) / CGFloat(camera.height), contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor).padding(AppTheme.Spacing.md) }
            }
    }

    private func update() {
        root.children.removeAll()
        do {
            let poses = Dictionary(uniqueKeysWithValues: pose.objects.map { ($0.objectID, $0.matrixWorld) })
            for mesh in snapshot.meshes {
                guard let world = poses[mesh.objectID] else { throw SpatialSceneError.changed }
                var descriptor = MeshDescriptor(name: mesh.id)
                descriptor.positions = MeshBuffers.Positions(mesh.positions.map { SIMD3<Float>(Float($0[0]), Float($0[1]), Float($0[2])) })
                descriptor.primitives = .triangles(mesh.triangles)
                let entity = ModelEntity(mesh: try MeshResource.generate(from: [descriptor]), materials: [
                    SimpleMaterial(color: mesh.objectID == selectedObjectID ? AppTheme.Accent.primaryNSColor : AppTheme.Text.secondary,
                        roughness: 0.8, isMetallic: false)])
                entity.transform = .init(matrix: try floatMatrix(world))
                root.addChild(entity)
            }
            guard let world = poses[camera.id] else { throw SpatialSceneError.changed }
            viewCamera.transform = .init(matrix: try floatMatrix(world))
            var projection = try floatMatrix(camera.projection)
            let ratio = Float(tan(camera.verticalFieldOfView / 2) / tan(pose.cameraVerticalFieldOfView / 2))
            projection[0][0] *= ratio; projection[1][1] *= ratio
            for column in 0..<4 { projection[column][2] = (projection[column][3] - projection[column][2]) * 0.5 }
            viewCamera.components.set(ProjectiveTransformCameraComponent(projectionMatrix: projection))
            failure = nil
        } catch { failure = error.localizedDescription }
    }

    private func floatMatrix(_ rows: [Double]) throws -> simd_float4x4 {
        let value = try SpatialShotPoseTimeline.matrix(rows)
        return .init(columns: (SIMD4<Float>(value[0]), SIMD4<Float>(value[1]), SIMD4<Float>(value[2]), SIMD4<Float>(value[3])))
    }
}
