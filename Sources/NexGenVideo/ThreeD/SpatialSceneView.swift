import AppKit
import BpyRuntimeProtocol
import RealityKit
import SwiftUI
import simd

struct SpatialSceneView: View {
    @Bindable var session: SpatialSceneSession
    @Environment(\.interfaceScale) private var textScale
    var editingEnabled = true
    @State private var newName = "Location"
    @State private var position = SIMD3<Double>.zero
    @State private var rotation = SIMD3<Double>.zero
    @State private var scale = SIMD3<Double>(repeating: 1)
    @State private var cameraName = "Camera"
    @State private var fieldOfView = 50.0
    @State private var width = 1280
    @State private var height = 720
    @State private var keyframe = false
    @State private var requestedFrame = 1

    private var editable: Bool { editingEnabled && !session.busy }
    private var canCreate: Bool { editable && !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canTransform: Bool { editable && position.allFinite && rotation.allFinite && scale.allFinite && min(scale.x, scale.y, scale.z) > 0 }
    private var canSaveCamera: Bool {
        editable && !cameraName.isEmpty && fieldOfView.isFinite && (1...170).contains(fieldOfView) && cameraDimensionError == nil
    }

    var body: some View {
        GeometryReader { geometry in
            let minimumWidth = (AppTheme.Layout.spatialInspectorMinWidth + AppTheme.Layout.spatialViewportMinWidth) * textScale
                + AppTheme.BorderWidth.thin
            if geometry.size.width >= minimumWidth {
                HSplitView {
                    ScrollView { inspectorContent }
                        .frame(minWidth: AppTheme.Layout.spatialInspectorMinWidth * textScale,
                               idealWidth: AppTheme.Layout.workflowSidebarDefault * textScale)
                    sceneContent()
                        .frame(minWidth: AppTheme.Layout.spatialViewportMinWidth * textScale)
                }
            } else {
                VStack(spacing: AppTheme.Spacing.sm) {
                    sceneHeader.padding(AppTheme.Spacing.md)
                    sceneError.padding(.horizontal, AppTheme.Spacing.md)
                    ScrollView {
                        VStack(spacing: AppTheme.Spacing.md) {
                            sceneBody(previewHeight: min(AppTheme.Layout.spatialCompactPreviewMaxHeight,
                                max(AppTheme.Layout.inspectorMinHeight, geometry.size.height
                                    - AppTheme.Layout.workspaceHeaderHeight - AppTheme.Layout.toolbarHeight - AppTheme.Spacing.xxl)),
                                zoomRequiresOption: true)
                                .padding(.horizontal, AppTheme.Spacing.md)
                            AppDivider()
                            inspectorContent
                        }
                    }
                }
                .buttonStyle(.capsule())
            }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .foregroundStyle(AppTheme.Text.primaryColor)
        .background(AppTheme.Background.surfaceColor)
        .reviewAcceptanceProbe("spatial.scene", state: !session.busy, text: session.current?.manifest.revision.uuidString ?? "")
        .reviewAcceptanceProbe("spatial.history.intent", text: session.historyIntent?.diagnosticText)
        .reviewAcceptanceProbe("spatial.history.trace", text: session.historyTrace.diagnosticText)
        .task { session.reload() }
        .onChange(of: session.selectedObjectID) { _, _ in updateInspector() }
        .onChange(of: session.snapshot) { _, _ in updateInspector(); requestedFrame = session.frame }
    }

    private var inspectorContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Locations").interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
            ForEach(session.locations) { head in
                Button(head.name) { session.open(head) }
                    .buttonStyle(.capsule(isSelected: head.id == session.current?.manifest.sceneID))
                    .disabled(session.busy)
                    .reviewAcceptanceProbe("spatial.location.\(head.id.uuidString)", state: !session.busy)
            }
            TextField("Location name", text: $newName)
                .disabled(!editingEnabled)
                .accessibilityIdentifier("spatial.location.name")
                .reviewAcceptanceProbe("spatial.location.name", state: editable, text: newName)
            Button("Create location") { Task { await session.create(name: newName) } }
                .disabled(!canCreate)
                .accessibilityIdentifier("spatial.location.create")
                .reviewAcceptanceProbe("spatial.location.create", state: canCreate)
            AppDivider()
            if session.current != nil {
                Menu("Add object") {
                    ForEach(["cube", "sphere", "cylinder", "plane"], id: \.self) { kind in
                        Button(kind.capitalized) { Task { await session.addPrimitive(kind) } }
                    }
                }
                .accessibilityIdentifier("spatial.object.add")
                .reviewAcceptanceProbe("spatial.object.add", state: editable)
                .disabled(!editingEnabled)
                Button("Import GLB…") { Task { await session.importGLB() } }
                    .disabled(!editingEnabled)
                    .accessibilityIdentifier("spatial.import")
                .reviewAcceptanceProbe("spatial.import", state: editable)
                ForEach(session.snapshot?.objects ?? []) { object in
                    Button(object.name) { session.selectedObjectID = object.id }
                        .buttonStyle(.capsule(isSelected: session.selectedObjectID == object.id))
                        .accessibilityIdentifier("spatial.object.\(object.id)")
                .reviewAcceptanceProbe("spatial.object.\(object.id)", state: !session.busy)
                }
                if session.selectedObject != nil { transformInspector.disabled(!editingEnabled) }
                AppDivider()
                cameraInspector
            }
        }
        .buttonStyle(.capsule(size: .regular))
        .disabled(session.busy)
        .padding(AppTheme.Spacing.md)
    }

    private var sceneHeader: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(session.current?.manifest.name ?? "Location editor")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .lineLimit(1)
                .help(session.current?.manifest.name ?? "Location editor")
            Spacer(minLength: AppTheme.Spacing.sm)
            Button("Undo") { _ = session.requestUndo() }.disabled(!editingEnabled || !session.canUndo)
                .fixedSize(horizontal: true, vertical: false)
                .reviewAcceptanceProbe("spatial.undo", state: editingEnabled && session.canUndo)
            Button("Redo") { _ = session.requestRedo() }.disabled(!editingEnabled || !session.canRedo)
                .fixedSize(horizontal: true, vertical: false)
                .reviewAcceptanceProbe("spatial.redo", state: editingEnabled && session.canRedo)
            if session.busy {
                ProgressView().controlSize(.small)
                if session.canCancel {
                    Button("Cancel") { session.cancel() }
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("spatial.cancel")
                        .reviewAcceptanceProbe("spatial.cancel")
                }
            }
        }
    }

    private func sceneContent() -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            sceneHeader
            sceneError
            sceneBody()
        }
        .buttonStyle(.capsule())
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sceneBody(previewHeight: CGFloat? = nil, zoomRequiresOption: Bool = false) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            if session.snapshot != nil {
                sceneViewport(zoomRequiresOption: zoomRequiresOption).frame(height: previewHeight)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("Frame").fixedSize()
                        TextField("Frame", value: $requestedFrame, format: .number)
                            .frame(width: AppTheme.Layout.spatialFrameFieldWidth * textScale)
                            .onSubmit { Task { await session.evaluate(frame: requestedFrame) } }
                            .accessibilityIdentifier("spatial.frame")
                            .reviewAcceptanceProbe("spatial.frame", state: !session.busy, text: String(requestedFrame))
                        Button("Evaluate") { Task { await session.evaluate(frame: requestedFrame) } }
                            .fixedSize(horizontal: true, vertical: false)
                            .disabled(session.busy)
                            .reviewAcceptanceProbe("spatial.frame.evaluate", state: !session.busy)
                        Spacer(minLength: AppTheme.Spacing.none)
                    }
                    Text(zoomRequiresOption ? "Drag to orbit · Option-drag to pan · Option-scroll to zoom"
                                            : "Drag to orbit · Option-drag to pan · Scroll to zoom")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ContentUnavailableView("No location selected", systemImage: "cube.transparent",
                                       description: Text("Create a location or open an existing one."))
                    .frame(height: previewHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: previewHeight == nil ? .infinity : nil)
    }

    @ViewBuilder
    private var sceneError: some View {
        if let error = session.error {
            Text(error).foregroundStyle(AppTheme.Status.errorColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("spatial.error")
                .reviewAcceptanceProbe("spatial.error", text: error)
        }
        if let notice = session.historyNotice {
            Text(notice).foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("spatial.history.notice")
                .reviewAcceptanceProbe("spatial.history.notice", text: notice)
        }
    }

    @ViewBuilder
    private func sceneViewport(zoomRequiresOption: Bool) -> some View {
        if let data = session.cameraPreview, let image = NSImage(data: data) {
            VStack(spacing: AppTheme.Spacing.sm) {
                Image(nsImage: image).resizable().scaledToFit()
                    .accessibilityIdentifier("spatial.camera.rendered")
                    .reviewAcceptanceProbe("spatial.camera.rendered", text: session.current?.manifest.snapshotSHA256 ?? "")
                Button("Return to viewport") { session.dismissCameraPreview() }
                    .fixedSize(horizontal: true, vertical: false)
                    .reviewAcceptanceProbe("spatial.camera.return")
            }
        } else {
            SpatialSceneViewport(session: session, zoomRequiresOption: zoomRequiresOption)
                .accessibilityIdentifier("spatial.viewport")
                .reviewAcceptanceProbe("spatial.viewport", state: !session.busy)
        }
    }

    private var transformInspector: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            vectorFields("Position", value: $position)
            vectorFields("Rotation", value: $rotation)
            vectorFields("Scale", value: $scale)
            Toggle("Snap to 0.1 scene units", isOn: $session.snap).reviewAcceptanceProbe("spatial.snap", state: session.snap)
            Toggle("Set keyframe", isOn: $keyframe).reviewAcceptanceProbe("spatial.transform.keyframe", state: keyframe)
            Button("Apply transform") {
                Task { await session.transformSelected(position: position, rotation: rotation, scale: scale, keyframe: keyframe) }
            }
            .disabled(!canTransform)
            .accessibilityIdentifier("spatial.transform.apply")
                        .reviewAcceptanceProbe("spatial.transform.apply", state: canTransform)
            Button("Delete object") { Task { await session.removeSelected() } }
                .reviewAcceptanceProbe("spatial.object.delete", state: editable)
        }
    }

    private var cameraInspector: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Picker("View", selection: $session.selectedCameraID) {
                Text("Free view").tag(String?.none)
                ForEach(session.snapshot?.cameras ?? []) { camera in
                    Text(camera.name).tag(Optional(camera.id))
                }
            }
            .accessibilityIdentifier("spatial.camera.select")
                        .reviewAcceptanceProbe("spatial.camera.select", state: !session.busy, text: session.selectedCameraID ?? "")
            TextField("Camera name", text: $cameraName).reviewAcceptanceProbe("spatial.camera.name", text: cameraName)
            Toggle("Set keyframe", isOn: $keyframe)
                .disabled(!editingEnabled)
                .accessibilityIdentifier("spatial.camera.keyframe")
                        .reviewAcceptanceProbe("spatial.camera.keyframe", state: keyframe)
            LabeledContent("Vertical FOV") { TextField("Degrees", value: $fieldOfView, format: .number).reviewAcceptanceProbe("spatial.camera.fov", text: String(fieldOfView)) }
            LabeledContent("Width") { TextField("Pixels", value: $width, format: .number).reviewAcceptanceProbe("spatial.camera.width", text: String(width)) }
            LabeledContent("Height") { TextField("Pixels", value: $height, format: .number).reviewAcceptanceProbe("spatial.camera.height", text: String(height)) }
            if let cameraDimensionError {
                Text(cameraDimensionError).foregroundStyle(AppTheme.Status.errorColor)
                    .accessibilityIdentifier("spatial.camera.dimensions-error")
                        .reviewAcceptanceProbe("spatial.camera.dimensions-error", text: cameraDimensionError)
            } else if let dimensions = try? SpatialClayRenderer.renderDimensions(width: width, height: height),
                      dimensions.width != width || dimensions.height != height {
                Text("Clay render: \(dimensions.width) × \(dimensions.height) pixels")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .accessibilityIdentifier("spatial.camera.render-dimensions")
                        .reviewAcceptanceProbe("spatial.camera.render-dimensions", text: "\(dimensions.width)x\(dimensions.height)")
            }
            Button(session.selectedCamera == nil ? "Create camera from view" : "Update camera") {
                Task { await session.camera(name: cameraName, fieldOfView: fieldOfView, width: width, height: height, keyframe: keyframe) }
            }
            .disabled(!canSaveCamera)
            .accessibilityIdentifier("spatial.camera.apply")
                        .reviewAcceptanceProbe("spatial.camera.apply", state: canSaveCamera)
            Button("Render camera frame") { Task { await session.renderCamera() } }
                .disabled(session.selectedCamera == nil || session.busy)
                .accessibilityIdentifier("spatial.camera.render")
                        .reviewAcceptanceProbe("spatial.camera.render", state: session.selectedCamera != nil && !session.busy)
        }
        .onChange(of: session.selectedCameraID) { _, _ in
            if let camera = session.selectedCamera {
                cameraName = camera.name
                fieldOfView = camera.verticalFieldOfView * 180 / .pi
                width = camera.width
                height = camera.height
            }
        }
    }

    private var cameraDimensionError: String? {
        do { _ = try SpatialClayRenderer.renderDimensions(width: width, height: height); return nil }
        catch { return error.localizedDescription }
    }

    private func vectorFields(_ title: String, value: Binding<SIMD3<Double>>) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title)
            HStack {
                ForEach(0..<3, id: \.self) { axis in
                    TextField(["X", "Y", "Z"][axis], value: Binding(
                        get: { value.wrappedValue[axis] }, set: { value.wrappedValue[axis] = $0 }
                    ), format: .number)
                    .accessibilityIdentifier("spatial.\(title.lowercased()).\(axis)")
                        .reviewAcceptanceProbe("spatial.\(title.lowercased()).\(axis)", state: editable, text: String(value.wrappedValue[axis]))
                }
            }
        }
    }

    private func updateInspector() {
        guard let object = session.selectedObject else { return }
        let matrix = SpatialSceneViewport.matrix(object.matrixWorld)
        let transform = RealityKit.Transform(matrix: matrix)
        position = SIMD3<Double>(transform.translation)
        scale = SIMD3<Double>(transform.scale)
        let rotationMatrix = simd_float3x3(transform.rotation)
        let pitch = asin(max(-1, min(1, -rotationMatrix[0][2])))
        rotation = SIMD3<Double>(Double(atan2(rotationMatrix[1][2], rotationMatrix[2][2])), Double(pitch),
                                 Double(atan2(rotationMatrix[0][1], rotationMatrix[0][0]))) * (180 / .pi)
    }
}

private extension SIMD3 where Scalar == Double {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

private struct SpatialSceneViewport: View {
    @Bindable var session: SpatialSceneSession
    var zoomRequiresOption = false
    @State private var root = Entity()
    @State private var camera = Entity()
    @State private var renderError: String?
    @State private var previousDrag = CGSize.zero

    var body: some View {
        RealityView { content in
            content.add(root)
            content.add(camera)
            updateGeometry()
            updateCamera()
        } update: { _ in
            updateCamera()
        }
        .task(id: session.snapshotRevision) { updateGeometry() }
        .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { event in
            session.selectedObjectID = event.entity.name
        })
        .simultaneousGesture(DragGesture().onChanged { event in
            guard session.selectedCamera == nil else { return }
            let delta = CGSize(width: event.translation.width - previousDrag.width,
                               height: event.translation.height - previousDrag.height)
            previousDrag = event.translation
            let offset = session.freeCameraPosition - session.freeCameraTarget
            let distance = max(0.1, simd_length(offset))
            if NSEvent.modifierFlags.contains(.option) {
                let right = simd_normalize(simd_cross(offset, [0, 0, 1]))
                let up = simd_normalize(simd_cross(right, offset))
                let shift = (right * Float(delta.width) + up * Float(delta.height)) * distance * 0.002
                session.freeCameraPosition += shift
                session.freeCameraTarget += shift
            } else {
                let yaw = atan2(offset.y, offset.x) - Float(delta.width) * 0.01
                let pitch = max(-1.5, min(1.5, asin(offset.z / distance) + Float(delta.height) * 0.01))
                session.freeCameraPosition = session.freeCameraTarget
                    + SIMD3<Float>(cos(yaw) * cos(pitch), sin(yaw) * cos(pitch), sin(pitch)) * distance
            }
        }.onEnded { _ in previousDrag = .zero })
        .overlay {
            SpatialViewportScroll(zoomRequiresOption: zoomRequiresOption) { delta in
                guard session.selectedCamera == nil else { return }
                let offset = session.freeCameraPosition - session.freeCameraTarget
                let distance = max(0.1, min(10_000, simd_length(offset) * exp(Float(delta) * 0.01)))
                session.freeCameraPosition = session.freeCameraTarget + simd_normalize(offset) * distance
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let renderError { Text(renderError).padding(AppTheme.Spacing.md) }
        }
        .aspectRatio(session.selectedCamera.map { CGFloat($0.width) / CGFloat($0.height) }, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateGeometry() {
        root.children.removeAll()
        do {
            for mesh in session.snapshot?.meshes ?? [] {
                var descriptor = MeshDescriptor(name: mesh.id)
                descriptor.positions = MeshBuffers.Positions(mesh.positions.map { SIMD3<Float>(Float($0[0]), Float($0[1]), Float($0[2])) })
                descriptor.primitives = .triangles(mesh.triangles)
                let resource = try MeshResource.generate(from: [descriptor])
                let selected = session.selectedObjectID == mesh.objectID
                let material = SimpleMaterial(color: selected ? AppTheme.Accent.primaryNSColor : AppTheme.Text.secondary,
                                              roughness: 0.8, isMetallic: false)
                let entity = ModelEntity(mesh: resource, materials: [material])
                entity.name = mesh.objectID
                entity.transform = RealityKit.Transform(matrix: Self.matrix(mesh.matrixWorld))
                entity.components.set(InputTargetComponent())
                entity.generateCollisionShapes(recursive: false)
                root.addChild(entity)
            }
            renderError = nil
        } catch { renderError = error.localizedDescription }
    }

    private func updateCamera() {
            for child in root.children {
                guard let entity = child as? ModelEntity else { continue }
                entity.model?.materials = [SimpleMaterial(
                    color: session.selectedObjectID == entity.name ? AppTheme.Accent.primaryNSColor : AppTheme.Text.secondary,
                    roughness: 0.8, isMetallic: false
                )]
            }
            if let selected = session.selectedCamera {
                camera.transform = RealityKit.Transform(matrix: Self.matrix(selected.matrixWorld))
                var projection = Self.matrix(selected.projection)
                for column in 0..<4 { projection[column][2] = (projection[column][3] - projection[column][2]) * 0.5 }
                camera.components.remove(PerspectiveCameraComponent.self)
                camera.components.set(ProjectiveTransformCameraComponent(projectionMatrix: projection))
            } else {
                camera.components.remove(ProjectiveTransformCameraComponent.self)
                camera.components.set(PerspectiveCameraComponent(near: 0.01, far: 10_000,
                                                                 fieldOfViewInDegrees: 50, fieldOfViewOrientation: .vertical))
                camera.look(at: session.freeCameraTarget, from: session.freeCameraPosition, upVector: [0, 0, 1], relativeTo: nil)
            }
    }

    static func matrix(_ rows: [Double]) -> simd_float4x4 {
        simd_float4x4(columns: (
            [Float(rows[0]), Float(rows[4]), Float(rows[8]), Float(rows[12])],
            [Float(rows[1]), Float(rows[5]), Float(rows[9]), Float(rows[13])],
            [Float(rows[2]), Float(rows[6]), Float(rows[10]), Float(rows[14])],
            [Float(rows[3]), Float(rows[7]), Float(rows[11]), Float(rows[15])]
        ))
    }
}

private struct SpatialViewportScroll: NSViewRepresentable {
    let zoomRequiresOption: Bool
    let zoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollView { ScrollView(zoomRequiresOption: zoomRequiresOption, zoom: zoom) }
    func updateNSView(_ view: ScrollView, context: Context) {
        view.zoomRequiresOption = zoomRequiresOption
        view.zoom = zoom
    }

    final class ScrollView: NSView {
        var zoomRequiresOption: Bool
        var zoom: (CGFloat) -> Void
        init(zoomRequiresOption: Bool, zoom: @escaping (CGFloat) -> Void) {
            self.zoomRequiresOption = zoomRequiresOption; self.zoom = zoom; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }
        override func scrollWheel(with event: NSEvent) {
            if zoomRequiresOption && !event.modifierFlags.contains(.option) { super.scrollWheel(with: event) }
            else { zoom(event.scrollingDeltaY) }
        }
    }
}
