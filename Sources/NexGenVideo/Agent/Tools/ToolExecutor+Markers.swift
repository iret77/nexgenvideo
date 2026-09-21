import Foundation

extension ToolExecutor {
    func manageMarkers(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let action = args.string("action") else { throw ToolError("Missing required argument: action") }
        let marker: TimelineMarker
        switch action {
        case "create":
            marker = try editor.createTimelineMarker(
                startFrame: try args.requireInt("startFrame"),
                durationFrames: args.int("durationFrames") ?? 0,
                title: try args.requireString("title"),
                note: args["note"] as? String ?? "",
                type: try markerType(args["type"] as? String, allowNone: false),
                color: try markerColor(args["color"] as? String, allowAutomatic: false),
                actionName: "Add Marker (Agent)"
            )

        case "update":
            let id = try args.requireString("markerId")
            let changedKeys = Set(args.keys).subtracting(["action", "markerId"])
            guard !changedKeys.isEmpty else { throw ToolError("manage_markers.update requires at least one changed field") }
            let changesType = args.keys.contains("type")
            let changesColor = args.keys.contains("color")
            let parsedType = try markerType(args["type"] as? String, allowNone: true)
            let parsedColor = try markerColor(args["color"] as? String, allowAutomatic: true)
            marker = try editor.updateTimelineMarker(id: id, actionName: "Edit Marker (Agent)") {
                if let value = args.int("startFrame") { $0.startFrame = value }
                if let value = args.int("durationFrames") { $0.durationFrames = value }
                if let value = args["title"] as? String { $0.title = value }
                if let value = args["note"] as? String { $0.note = value }
                if changesType { $0.type = parsedType }
                if changesColor { $0.color = parsedColor }
            }

        case "delete":
            let id = try args.requireString("markerId")
            guard let existing = editor.timeline.markers.first(where: { $0.id == id }) else {
                throw ToolError("Marker not found: \(id)")
            }
            try editor.deleteTimelineMarkers(ids: [id], actionName: "Delete Marker (Agent)")
            return .ok("Deleted marker \u{201C}\(existing.title)\u{201D}.")

        default:
            throw ToolError("Invalid marker action: \(action)")
        }

        guard let json = Self.jsonString(Self.timelineMarkerPayload(marker)) else {
            throw ToolError("Failed to encode marker result")
        }
        return .ok(json)
    }

    private func markerType(_ raw: String?, allowNone: Bool) throws -> TimelineMarker.Kind? {
        guard let raw else { return nil }
        if allowNone, raw == "none" { return nil }
        guard let value = TimelineMarker.Kind(rawValue: raw) else {
            throw ToolError("Invalid marker type: \(raw)")
        }
        return value
    }

    private func markerColor(_ raw: String?, allowAutomatic: Bool) throws -> TextStyle.RGBA? {
        guard let raw else { return nil }
        if allowAutomatic, raw == "automatic" { return nil }
        guard let value = TextStyle.RGBA(hex: raw) else {
            throw ToolError("Invalid marker color: \(raw). Use #RGB, #RRGGBB, or #RRGGBBAA.")
        }
        return value
    }
}
