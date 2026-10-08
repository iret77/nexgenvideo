import SwiftUI

struct MarkerPanelView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var draftID: String?
    @State private var title = ""
    @State private var note = ""
    @State private var startFrame = ""
    @State private var durationFrames = ""
    @State private var type = ""
    @Environment(\.interfaceScale) private var interfaceScale
    @State private var color = Color(AppTheme.Timeline.markerDefault)
    @State private var automaticColor = true
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("Timeline Markers")
                    .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                Spacer()
                Button("Add Marker", systemImage: "plus") {
                    editor.addTimelineMarkerAtSelection()
                    loadSelection()
                }
                .buttonStyle(.capsule(draftID == nil ? .prominent : .secondary))
                .disabled(!editor.allowsTimelineEditChrome)
            }

            markerList
            AppDivider()

            if draftID != nil {
                editorFields
            } else {
                Text("Select a marker to edit its time and details.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Layout.markerPanelWidth * interfaceScale, height: AppTheme.Layout.markerPanelHeight * interfaceScale)
        .background(AppTheme.Background.surfaceColor)
        .onAppear {
            if editor.selectedTimelineMarkerIds.isEmpty, let first = editor.timeline.markers.first {
                editor.selectedTimelineMarkerIds = [first.id]
            }
            loadSelection()
        }
        .onChange(of: editor.selectedTimelineMarkerIds) { _, _ in loadSelection() }
        .onChange(of: editor.timeline.markers) { _, _ in loadSelection() }
    }

    private var markerList: some View {
        ScrollView {
            LazyVStack(spacing: AppTheme.Spacing.xs) {
                ForEach(editor.timeline.markers) { marker in
                    Button {
                        editor.selectedTimelineMarkerIds = [marker.id]
                    } label: {
                        HStack(spacing: AppTheme.Spacing.smMd) {
                            Circle()
                                .fill(Color(marker.color?.nsColor ?? AppTheme.Timeline.markerDefault))
                                .frame(width: AppTheme.IconSize.xxs, height: AppTheme.IconSize.xxs)
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                Text(marker.title)
                                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                                    .foregroundStyle(AppTheme.Text.primaryColor)
                                    .lineLimit(1)
                                Text(formatTimecode(frame: marker.startFrame, fps: editor.timeline.fps))
                                    .interfaceFont(size: AppTheme.Typography.metadata, design: .monospaced)
                                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                            }
                            Spacer()
                            Text(marker.type?.rawValue.capitalized ?? "Marker")
                                .interfaceFont(size: AppTheme.Typography.metadata)
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        }
                        .padding(.horizontal, AppTheme.Spacing.smMd)
                        .padding(.vertical, AppTheme.Spacing.sm)

                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(isActive: editor.selectedTimelineMarkerIds.contains(marker.id))
                    .accessibilityLabel("Select marker \(marker.title)")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var editorFields: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                InspectorFormRow(label: "Title") {
                    TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                }
                InspectorFormRow(label: "Start frame") {
                    TextField("Start frame", text: $startFrame).textFieldStyle(.roundedBorder)
                }
                InspectorFormRow(label: "Duration") {
                    TextField("Duration in frames", text: $durationFrames).textFieldStyle(.roundedBorder)
                }
                InspectorFormRow(label: "Type") {
                    NativeChoicePicker(
                        label: "Marker type",
                        options: [NativeChoicePicker.Option(id: "", title: "No Type")]
                            + TimelineMarker.Kind.allCases.map {
                                NativeChoicePicker.Option(id: $0.rawValue, title: $0.rawValue.capitalized)
                            },
                        selection: $type
                    )
                }
                InspectorFormRow(label: "Color") {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Toggle("Automatic", isOn: $automaticColor)
                            .toggleStyle(.switch)
                            .controlSize(.regular)
                        ColorField(displayColor: automaticColor ? Color(AppTheme.Timeline.markerDefault) : color) {
                            color = $0
                            automaticColor = false
                        }
                    }
                }
                InspectorFormRow(label: "Note") {
                    TextEditor(text: $note)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .scrollContentBackground(.hidden)
                        .padding(AppTheme.Spacing.xs)
                        .frame(height: AppTheme.Layout.markerNoteHeight * interfaceScale)
                        .inspectorControlChrome()
                        .accessibilityLabel("Marker note")
                }
                if let validationMessage {
                    Text(validationMessage)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Status.errorColor)
                }
                WrapLayout(spacing: AppTheme.Spacing.smMd, trailingLastItem: true) {
                    Button("Jump") { jump() }.buttonStyle(.capsule(.secondary))
                    Button("Save Edit") { save() }
                        .buttonStyle(.capsule(.prominent))
                        .disabled(!editor.allowsTimelineEditChrome)
                    Button("Delete", role: .destructive) { delete() }
                        .buttonStyle(.capsule(.secondary))
                        .disabled(!editor.allowsTimelineEditChrome)
                }
            }
            .interfaceFont(size: AppTheme.Typography.ui)
        }
    }

    private func loadSelection() {
        guard let marker = editor.selectedTimelineMarker else {
            draftID = nil
            return
        }
        draftID = marker.id
        title = marker.title
        note = marker.note
        startFrame = String(marker.startFrame)
        durationFrames = String(marker.durationFrames)
        type = marker.type?.rawValue ?? ""
        color = Color(marker.color?.nsColor ?? AppTheme.Timeline.markerDefault)
        automaticColor = marker.color == nil
        validationMessage = nil
    }

    private func save() {
        guard let id = draftID,
              let start = Int(startFrame),
              let duration = Int(durationFrames) else {
            validationMessage = "Enter whole frame numbers for start and duration."
            return
        }
        let parsedColor: TextStyle.RGBA? = automaticColor ? nil : TextStyle.RGBA(color)
        do {
            _ = try editor.updateTimelineMarker(id: id) {
                $0.startFrame = start
                $0.durationFrames = duration
                $0.title = title
                $0.note = note
                $0.type = TimelineMarker.Kind(rawValue: type)
                $0.color = parsedColor
            }
            loadSelection()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func jump() {
        guard let id = draftID else { return }
        editor.jumpToTimelineMarker(id: id)
    }

    private func delete() {
        guard let id = draftID else { return }
        do {
            try editor.deleteTimelineMarkers(ids: [id])
            if let first = editor.timeline.markers.first {
                editor.selectedTimelineMarkerIds = [first.id]
            }
            loadSelection()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
