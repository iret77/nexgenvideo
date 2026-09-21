import Foundation

enum TimelineMarkerMutationError: LocalizedError, Equatable {
    case invalidID
    case duplicateID(String)
    case invalidTime
    case emptyTitle
    case titleTooLong
    case noteTooLong
    case invalidColor
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidID: "Marker ID must not be empty."
        case .duplicateID(let id): "Marker ID is duplicated: \(id)"
        case .invalidTime: "Marker time must be a non-negative frame range."
        case .emptyTitle: "Marker title is required."
        case .titleTooLong: "Marker title is too long."
        case .noteTooLong: "Marker note is too long."
        case .invalidColor: "Marker color components must be between 0 and 1."
        case .notFound(let id): "Marker not found: \(id)"
        }
    }
}

extension EditorViewModel {
    var displayedTimelineMarkers: [TimelineMarker] {
        guard let preview = timelineMarkerPreview else { return timeline.markers }
        return timeline.markers.map { $0.id == preview.id ? preview : $0 }
    }

    var selectedTimelineMarker: TimelineMarker? {
        guard selectedTimelineMarkerIds.count == 1, let id = selectedTimelineMarkerIds.first else { return nil }
        return displayedTimelineMarkers.first { $0.id == id }
    }

    func timelineMarkerSnapFrames(excluding markerID: String? = nil) -> [Int] {
        displayedTimelineMarkers.flatMap { marker -> [Int] in
            guard marker.id != markerID else { return [] }
            return marker.durationFrames > 0 ? [marker.startFrame, marker.endFrame] : [marker.startFrame]
        }
    }

    @discardableResult
    func createTimelineMarker(
        startFrame: Int,
        durationFrames: Int = 0,
        title: String,
        note: String = "",
        type: TimelineMarker.Kind? = nil,
        color: TextStyle.RGBA? = nil,
        actionName: String = "Add Marker"
    ) throws -> TimelineMarker {
        let marker = TimelineMarker(
            startFrame: startFrame,
            durationFrames: durationFrames,
            title: title,
            note: note,
            type: type,
            color: color
        )
        try replaceTimelineMarkers(timeline.markers + [marker], actionName: actionName)
        selectedTimelineMarkerIds = [marker.id]
        return timeline.markers.first { $0.id == marker.id } ?? marker
    }

    @discardableResult
    func updateTimelineMarker(
        id: String,
        actionName: String = "Edit Marker",
        _ change: (inout TimelineMarker) -> Void
    ) throws -> TimelineMarker {
        guard let index = timeline.markers.firstIndex(where: { $0.id == id }) else {
            throw TimelineMarkerMutationError.notFound(id)
        }
        var markers = timeline.markers
        change(&markers[index])
        markers[index].id = id
        try replaceTimelineMarkers(markers, actionName: actionName)
        guard let updated = timeline.markers.first(where: { $0.id == id }) else {
            throw TimelineMarkerMutationError.notFound(id)
        }
        return updated
    }

    func deleteTimelineMarkers(ids: Set<String>, actionName: String = "Delete Marker") throws {
        guard !ids.isEmpty else { return }
        let missing = ids.subtracting(timeline.markers.map(\.id))
        if let id = missing.first { throw TimelineMarkerMutationError.notFound(id) }
        try replaceTimelineMarkers(
            timeline.markers.filter { !ids.contains($0.id) },
            actionName: ids.count == 1 ? actionName : "Delete Markers"
        )
        selectedTimelineMarkerIds.subtract(ids)
        if let preview = timelineMarkerPreview, ids.contains(preview.id) {
            timelineMarkerPreview = nil
        }
    }

    func addTimelineMarkerAtSelection() {
        if activePreviewTab != .timeline {
            selectPreviewTab(id: PreviewTab.timeline.id)
        }
        let range = validSelectedTimelineRange
        let start = range?.startFrame ?? activeFrame
        let duration = range.map { $0.endFrame - $0.startFrame } ?? 0
        let ordinal = timeline.markers.count + 1
        if let marker = try? createTimelineMarker(
            startFrame: start,
            durationFrames: duration,
            title: "Marker \(ordinal)"
        ) {
            selectedTimelineMarkerIds = [marker.id]
            selectedTimelineRange = nil
            markerPanelPresented = true
        }
    }

    func jumpToTimelineMarker(id: String) {
        guard let marker = timeline.markers.first(where: { $0.id == id }) else { return }
        if activePreviewTab != .timeline {
            selectPreviewTab(id: PreviewTab.timeline.id)
        }
        selectedTimelineMarkerIds = [id]
        seekToFrame(marker.startFrame)
    }

    func applyTimelineMarkerOffset(atFrame frame: Int, delta: Int, actionName: String) {
        withTimelineSwap(actionName: actionName) {
            timeline.markers = RippleEngine.rippleMarkers(timeline.markers, openingAt: frame, by: delta)
        }
    }

    private func replaceTimelineMarkers(_ markers: [TimelineMarker], actionName: String) throws {
        let normalized = try validatedTimelineMarkers(markers)
        withTimelineSwap(actionName: actionName) {
            timeline.markers = normalized.sorted {
                $0.startFrame == $1.startFrame ? $0.id < $1.id : $0.startFrame < $1.startFrame
            }
        }
    }

    private func validatedTimelineMarkers(_ markers: [TimelineMarker]) throws -> [TimelineMarker] {
        var ids = Set<String>()
        return try markers.map { marker in
            var marker = marker
            marker.id = marker.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !marker.id.isEmpty else { throw TimelineMarkerMutationError.invalidID }
            guard ids.insert(marker.id).inserted else { throw TimelineMarkerMutationError.duplicateID(marker.id) }
            guard marker.startFrame >= 0,
                  marker.durationFrames >= 0,
                  marker.startFrame.addingReportingOverflow(marker.durationFrames).overflow == false else {
                throw TimelineMarkerMutationError.invalidTime
            }
            marker.title = marker.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !marker.title.isEmpty else { throw TimelineMarkerMutationError.emptyTitle }
            guard marker.title.count <= TimelineMarker.maxTitleLength else {
                throw TimelineMarkerMutationError.titleTooLong
            }
            guard marker.note.count <= TimelineMarker.maxNoteLength else {
                throw TimelineMarkerMutationError.noteTooLong
            }
            if let color = marker.color {
                let components = [color.r, color.g, color.b, color.a]
                guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw TimelineMarkerMutationError.invalidColor
                }
            }
            return marker
        }
    }
}
