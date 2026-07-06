import Foundation

/// Provider image-prompt builders. Port of `build_for_nano_banana`,
/// `build_for_gpt_image_2`, `build_for_imagen`, `build_for_runway_image` from
/// `builder.py`. `throws` because the sheet-view dispatcher raises on an unknown
/// character/ensemble view (Python `ValueError`).
enum ImageBuilders {
    /// Deduplicate positives case-insensitively, preserving first-seen order.
    /// Port of the inline `seen`/`dedup` loop shared by nano-banana / gpt-image-2.
    private static func dedupPositives(_ negatives: [String]) -> [String] {
        var seen = Set<String>()
        var dedup: [String] = []
        for n in negatives {
            let p = PositivePhrasing.phrase(n)
            if !seen.contains(p.lowercased()) {
                dedup.append(p)
                seen.insert(p.lowercased())
            }
        }
        return dedup
    }

    /// Port of `build_for_nano_banana`.
    static func nanoBanana(_ payload: PromptPayload, sheetKind: String = "character") throws -> String {
        let subject = SlopStripper.strip(payload.subject)
        let setting = SlopStripper.strip(payload.setting)
        let composition = SlopStripper.strip(payload.composition)
        let camera = SlopStripper.strip(payload.camera)
        let light = SlopStripper.strip(payload.light)
        let style = SlopStripper.strip(payload.style)

        var parts: [String] = []
        if !payload.sheetView.isEmpty {
            let viewLabel = payload.sheetView.replacingOccurrences(of: "_", with: " ")
            parts.append("\(subject), captured as a \(viewLabel) reference sheet")
            parts.append(try SheetViewDirections.direction(view: payload.sheetView, kind: sheetKind))
        } else {
            parts.append(subject)
            if !setting.isEmpty { parts.append(setting) }
            if !composition.isEmpty { parts.append(composition) }
            if !camera.isEmpty { parts.append(camera) }
            if !light.isEmpty { parts.append(light) }
        }
        let styleAlreadyInSubject = subject.lowercased().contains("style")
        if !style.isEmpty && !styleAlreadyInSubject {
            parts.append("Style: \(style)")
        }
        if !payload.multiRefHints.isEmpty {
            let refLines = payload.multiRefHints.enumerated()
                .map { "Image \($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespacesAndNewlines))" }
                .joined(separator: "; ")
            parts.append(
                "References — \(refLines). Use these as style and composition "
                + "anchors: match the flat illustration style, palette, line "
                + "treatment, camera angle, and figure-to-set scale of the "
                + "references. Stay strictly within the architectural depth "
                + "and perspective already shown in the references. Output "
                + "ONE single full-frame image filling the entire frame "
                + "edge-to-edge as one unified continuous picture."
            )
        }
        if !payload.negatives.isEmpty {
            parts.append("Composition rules: " + dedupPositives(payload.negatives).joined(separator: ", "))
        }
        parts.append(contentsOf: payload.directives)
        return BuilderSupport.joinClean(parts)
    }

    /// Port of `build_for_gpt_image_2`.
    static func gptImage2(_ payload: PromptPayload, sheetKind: String = "character") throws -> String {
        let subject = SlopStripper.strip(payload.subject)
        let setting = SlopStripper.strip(payload.setting)
        let composition = SlopStripper.strip(payload.composition)
        let camera = SlopStripper.strip(payload.camera)
        let light = SlopStripper.strip(payload.light)
        let style = SlopStripper.strip(payload.style)

        var lines: [String] = []
        if !payload.sheetView.isEmpty {
            lines.append("Scene:\n" + (try SheetViewDirections.direction(view: payload.sheetView, kind: sheetKind)))
            lines.append("Subject:\n\(subject)")
        } else {
            if !setting.isEmpty { lines.append("Scene:\n\(setting)") }
            lines.append("Subject:\n\(subject)")
            var details: [String] = []
            if !composition.isEmpty { details.append(composition) }
            if !camera.isEmpty { details.append(camera) }
            if !light.isEmpty { details.append(light) }
            if !style.isEmpty && !subject.lowercased().contains("style") {
                details.append("Style: \(style)")
            }
            if !details.isEmpty {
                lines.append("Important details:\n" + details.joined(separator: " "))
            }
        }
        let useCase: String
        if !payload.sheetView.isEmpty {
            if sheetKind == "character" {
                useCase = "character reference sheet for downstream image-to-video"
            } else if sheetKind == "location" {
                useCase = "location reference plate for downstream image-to-video"
            } else {
                useCase = "\(sheetKind) reference plate"
            }
        } else {
            useCase = payload.isStartFrame
                ? "video keyframe (t=0 anchor frame)"
                : "video keyframe (end-position anchor frame)"
        }
        lines.append("Use case:\n\(useCase)")
        if !payload.multiRefHints.isEmpty {
            let refLines = payload.multiRefHints.enumerated()
                .map { "Image \($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespacesAndNewlines))" }
                .joined(separator: "\n")
            lines.append(
                "References:\n" + refLines + "\n"
                + "Use these as style and composition anchors: match the "
                + "illustration style, palette, line treatment, camera angle, "
                + "figure-to-set scale, and architectural depth of the "
                + "references. Preserve face identity, body proportions, "
                + "outfit, brand colors, lighting setup, framing. Treat the "
                + "references as style guides only; stay strictly within the "
                + "architectural depth and perspective already shown there. "
                + "Output ONE single full-frame image filling the entire frame "
                + "edge-to-edge as one unified continuous picture."
            )
        }
        if !payload.negatives.isEmpty {
            lines.append("Constraints:\n" + dedupPositives(payload.negatives).joined(separator: ", "))
        }
        lines.append(contentsOf: payload.directives)
        // Port: "\n\n".join(line for line in lines if line and line.strip())
        return lines
            .filter { !$0.isEmpty && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    /// Port of `build_for_imagen`.
    static func imagen(_ payload: PromptPayload, sheetKind: String = "character") throws -> String {
        let subject = SlopStripper.strip(payload.subject)
        let setting = SlopStripper.strip(payload.setting)
        let composition = SlopStripper.strip(payload.composition)
        let camera = SlopStripper.strip(payload.camera)
        let light = SlopStripper.strip(payload.light)
        let style = SlopStripper.strip(payload.style)

        var parts: [String] = []
        if !payload.sheetView.isEmpty {
            parts.append(try SheetViewDirections.direction(view: payload.sheetView, kind: sheetKind))
            parts.append(subject)
        } else {
            parts.append(subject)
            if !composition.isEmpty { parts.append(composition) }
            if !setting.isEmpty { parts.append(setting) }
            if !camera.isEmpty { parts.append(camera) }
            if !light.isEmpty { parts.append(light) }
        }
        if !style.isEmpty && !subject.lowercased().contains("style") {
            parts.append(style)
        }
        if !payload.negatives.isEmpty {
            parts.append(payload.negatives.map { PositivePhrasing.phrase($0) }.joined(separator: ", "))
        }
        if payload.sheetView.isEmpty {
            parts.append(
                "Output a single full-frame image filling the entire frame "
                + "edge-to-edge as one unified continuous picture."
            )
        }
        parts.append(contentsOf: payload.directives)
        return BuilderSupport.joinClean(parts)
    }

    /// Port of `build_for_runway_image` — delegates to gpt-image-2.
    static func runwayImage(_ payload: PromptPayload, sheetKind: String = "character") throws -> String {
        try gptImage2(payload, sheetKind: sheetKind)
    }
}
