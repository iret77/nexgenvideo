import SwiftUI

struct MarkerPanelView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var draftID: String?
    @State private var title = ""
    @State private var note = ""
    @State private var startFrame = ""
    @State private var durationFrames = ""
    @State private var type = ""
    @State private var color = ""
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("Timeline Markers")
                    .interfaceFont(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold)
                Spacer()
                Button("Add Marker", systemImage: "plus") {
                    editor.addTimelineMarkerAtSelection()
                    loadSelection()
                }
                .buttonStyle(.capsule(.prominent, size: .small))
                .disabled(!editor.allowsTimelineEditChrome)
            }

            markerList
            AppDivider()

            if draftID != nil {
                editorFields
            } else {
                Text("Select a marker to edit its time and details.")
                    .interfaceFont(size: AppTheme.FontSize.sm)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Layout.markerPanelWidth, height: AppTheme.Layout.markerPanelHeight)
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
                                    .interfaceFont(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium)
                                    .foregroundStyle(AppTheme.Text.primaryColor)
                                    .lineLimit(1)
                                Text(formatTimecode(frame: marker.startFrame, fps: editor.timeline.fps))
                                    .interfaceFont(size: AppTheme.FontSize.xxs, design: .monospaced)
                                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                            }
                            Spacer()
                            Text(marker.type?.rawValue.capitalized ?? "Marker")
                                .interfaceFont(size: AppTheme.FontSize.xxs)
                                .foregroundStyle(AppTheme.Text.mutedColor)
                            Text("Select")
                                .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium)
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                        .padding(.horizontal, AppTheme.Spacing.smMd)
                        .padding(.vertical, AppTheme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .fill(editor.selectedTimelineMarkerIds.contains(marker.id)
                                    ? AppTheme.Background.prominentColor
                                    : AppTheme.Background.raisedColor)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select marker \(marker.title)")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var editorFields: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            TextField("Title", text: $title)

            HStack(spacing: AppTheme.Spacing.smMd) {
                TextField("Start frame", text: $startFrame)
                    .frame(width: AppTheme.Layout.markerTimeFieldWidth)
                TextField("Duration", text: $durationFrames)
                    .frame(width: AppTheme.Layout.markerTimeFieldWidth)
                NativeChoicePicker(
                    label: "Marker type",
                    options: [NativeChoicePicker.Option(id: "", title: "No Type")]
                        + TimelineMarker.Kind.allCases.map {
                            NativeChoicePicker.Option(id: $0.rawValue, title: $0.rawValue.capitalized)
                        },
                    selection: $type
                )
            }

            TextField("Color (#RRGGBB or automatic)", text: $color)

            TextEditor(text: $note)
                .interfaceFont(size: AppTheme.FontSize.sm)
                .scrollContentBackground(.hidden)
                .padding(AppTheme.Spacing.xs)
                .frame(height: AppTheme.Layout.markerNoteHeight)
                .background(AppTheme.Background.raisedColor)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                )

            if let validationMessage {
                Text(validationMessage)
                    .interfaceFont(size: AppTheme.FontSize.xxs)
                    .foregroundStyle(AppTheme.Status.errorColor)
            }

            HStack(spacing: AppTheme.Spacing.smMd) {
                Button("Jump") { jump() }
                    .buttonStyle(.capsule(.secondary, size: .small))
                Button("Save Edit") { save() }
                    .buttonStyle(.capsule(.prominent, size: .small))
                    .disabled(!editor.allowsTimelineEditChrome)
                Spacer()
                Button("Delete", role: .destructive) { delete() }
                    .buttonStyle(.capsule(.secondary, size: .small))
                    .disabled(!editor.allowsTimelineEditChrome)
            }
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
        color = marker.color?.hexString ?? "automatic"
        validationMessage = nil
    }

    private func save() {
        guard let id = draftID,
              let start = Int(startFrame),
              let duration = Int(durationFrames) else {
            validationMessage = "Enter whole frame numbers for start and duration."
            return
        }
        let parsedColor: TextStyle.RGBA?
        if color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "automatic"
            || color.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parsedColor = nil
        } else if let value = TextStyle.RGBA(hex: color) {
            parsedColor = value
        } else {
            validationMessage = "Enter a hexadecimal color or automatic."
            return
        }
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
