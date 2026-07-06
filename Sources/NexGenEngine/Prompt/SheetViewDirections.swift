import Foundation

/// Sheet-view direction tables (character / location / prop) and the dispatcher.
/// Port of the `_CHARACTER_VIEW_DIRECTION`, `_LOCATION_VIEW_DIRECTION`,
/// `_PROP_VIEW_DIRECTION` tables and `_sheet_view_direction` from `builder.py`.
enum SheetViewDirections {
    enum DirectionError: Swift.Error, Sendable, Equatable {
        case unknownCharacterView(String)
    }

    static let characterViewDirection: [String: String] = [
        "front":
            "front view, full character visible from head to toe, neutral "
            + "standing pose facing camera, seamless plain white studio backdrop, "
            + "even diffuse studio lighting, full body framing.",
        "side":
            "strict 90 degree side profile of the same character, full body, "
            + "neutral standing pose, seamless plain white studio backdrop, "
            + "even diffuse studio lighting.",
        "back":
            "back view of the same character, full body, neutral standing "
            + "pose, seamless plain white studio backdrop, even diffuse studio "
            + "lighting.",
    ]

    static func expressionDirection(_ view: String) -> String {
        // Port: view.removeprefix("expression_").replace("_", " ")
        let stripped = view.hasPrefix("expression_") ? String(view.dropFirst("expression_".count)) : view
        let tag = stripped.replacingOccurrences(of: "_", with: " ")
        return "front portrait of the same character with a \(tag) facial "
            + "expression, bust-up framing, seamless plain white studio "
            + "backdrop, even diffuse studio lighting."
    }

    static let locationViewDirection: [String: String] = [
        "wide":
            "wide architectural reference of the empty location, capturing "
            + "the defining structural elements (walls, windows, doors, "
            + "fixtures, furniture in original position). Adult eye-level "
            + "camera, slight wide-angle to capture the full space, even "
            + "neutral lighting.",
        "alt_angle":
            "alternate angle of the same empty location from the opposite "
            + "side or 90 degree rotation, showing different structural "
            + "elements than a wide view. Adult eye-level camera, even "
            + "neutral lighting.",
        "detail":
            "detail shot of a defining feature of the same empty location "
            + "(characteristic window, door, fixture, decoration). Even "
            + "neutral lighting.",
        "entrance":
            "reference shot of the location seen from outside, looking in "
            + "through the entrance — gate / door / threshold visible in the "
            + "foreground, the interior or far side of the location visible "
            + "beyond. Even neutral lighting.",
        "floorplan":
            "DEPRECATED. Top-down schematic — image models cannot reliably "
            + "interpret this as geometric ground-truth. Use the scene3d "
            + "pipeline (Marble + Re-Style) instead.",
    ]

    static func locationViewDirectionFor(_ view: String) -> String {
        if let known = locationViewDirection[view] { return known }
        if view.contains(".") {
            // Port: view.split(".", 1) — split on first dot only.
            let dotIndex = view.firstIndex(of: ".")!
            let base = String(view[view.startIndex..<dotIndex])
            let variant = String(view[view.index(after: dotIndex)...])
            let variantClean = variant.replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let baseText = locationViewDirection[base] {
                return "\(baseText) Variant: \(variantClean)."
            }
            return "reference shot of the same empty location, focused on the "
                + "\(base.replacingOccurrences(of: "_", with: " ")) (\(variantClean)) area, even "
                + "neutral lighting."
        }
        return "reference shot of the same empty location, focused on the "
            + "\(view.replacingOccurrences(of: "_", with: " ")) area, even neutral lighting."
    }

    static let propViewDirection: [String: String] = [
        "default":
            "isolated product/prop reference shot, the prop centered on a "
            + "seamless plain white studio backdrop, neutral diffuse studio "
            + "lighting, full object visible, the prop alone in the frame.",
        "closed":
            "the same prop in its closed/folded/sealed state, isolated on a "
            + "seamless plain white studio backdrop, neutral diffuse lighting.",
        "open":
            "the same prop in its open/unfolded/active state, isolated on a "
            + "seamless plain white studio backdrop, neutral diffuse lighting.",
        "worn":
            "the same prop in a worn/used/aged state showing realistic wear, "
            + "isolated on a seamless plain white studio backdrop, neutral "
            + "diffuse lighting.",
        "clean":
            "the same prop in pristine/new condition, isolated on a seamless "
            + "plain white studio backdrop, neutral diffuse lighting.",
    ]

    static func propViewDirectionFor(_ view: String) -> String {
        if let known = propViewDirection[view] { return known }
        return "prop reference shot showing the \(view.replacingOccurrences(of: "_", with: " ")) state, "
            + "isolated on a seamless plain white studio backdrop, neutral "
            + "diffuse lighting."
    }

    /// Port of `_sheet_view_direction(view, kind)`.
    static func direction(view: String, kind: String) throws -> String {
        if kind == "location" { return locationViewDirectionFor(view) }
        if kind == "prop" { return propViewDirectionFor(view) }
        if let known = characterViewDirection[view] { return known }
        if view.hasPrefix("expression_") { return expressionDirection(view) }
        throw DirectionError.unknownCharacterView(view)
    }
}
