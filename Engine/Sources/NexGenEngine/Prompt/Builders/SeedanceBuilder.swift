import Foundation

/// ByteDance Seedance 2.0 video-prompt builder. Port of `build_for_seedance_2`
/// from `builder.py` — the 6-step formula with three sub-modes
/// (reference / image-to-video / text-to-video).
enum SeedanceBuilder {
    /// Character-detection tokens for the standard constraints. Port of the
    /// inline tuple in `build_for_seedance_2`.
    private static let characterTokens = [
        "person", "character", "man", "woman", "girl", "boy",
        "performer", "musician", "singer", "dancer", "child",
        "adult", "teen", "people", "figure",
    ]

    static func build(
        _ payload: PromptPayload,
        hasStartImage: Bool = false,
        hasEndImage: Bool = false,
        isPacingArm: Bool = false,
        referenceTags: [ReferenceTag]? = nil
    ) -> String {
        // Port: duration = payload.duration_s or 5  (None or 0.0 → 5).
        let duration: Double = {
            guard let d = payload.durationS, d != 0 else { return 5 }
            return d
        }()
        // Port: aspect = payload.aspect_ratio or "16:9".
        let aspect = payload.aspectRatio.isEmpty ? "16:9" : payload.aspectRatio
        // Port: n = payload.n_shots if payload.n_shots > 0 else 1.
        let n = payload.nShots > 0 ? payload.nShots : 1

        var parts: [String] = []

        if let referenceTags, !referenceTags.isEmpty {
            // ===== Reference-mode =====
            var introParts: [String] = []
            for (i, tag) in referenceTags.enumerated() {
                let label = "@Image\(i + 1)"
                switch tag.role {
                case "character": introParts.append("\(label) is \(tag.hint).")
                case "location": introParts.append("\(label) shows \(tag.hint).")
                case "prop": introParts.append("\(label) is \(tag.hint).")
                default: introParts.append("\(label): \(tag.hint).")
                }
            }
            parts.append(introParts.joined(separator: " "))

            let actionFocus = SlopStripper.strip(payload.subject)
            let subjectAlreadyTagged = !actionFocus.isEmpty && Rx.search(actionFocus, SlopStripper.atTagRE)
            if subjectAlreadyTagged {
                parts.append(actionFocus)
            } else {
                // Port: next((i for i,t in enumerate(reference_tags, start=1) if t.role == "character"), None)
                let firstCharIdx: Int? = {
                    for (i, t) in referenceTags.enumerated() where t.role == "character" {
                        return i + 1
                    }
                    return nil
                }()
                if !actionFocus.isEmpty {
                    if let firstCharIdx {
                        parts.append("@Image\(firstCharIdx) \(actionFocus)")
                    } else {
                        parts.append(actionFocus)
                    }
                } else if let firstCharIdx {
                    parts.append("@Image\(firstCharIdx) in the framed action.")
                } else {
                    parts.append("The framed action plays out.")
                }
            }
            if !payload.setting.isEmpty { parts.append(SlopStripper.strip(payload.setting)) }
            if !payload.camera.isEmpty { parts.append(SlopStripper.strip(payload.camera)) }
            if !payload.light.isEmpty { parts.append(SlopStripper.strip(payload.light)) }
            if !payload.style.isEmpty { parts.append(SlopStripper.strip(payload.style)) }
            if referenceTags.count > 1 {
                let joined = (0..<referenceTags.count).map { "@Image\($0 + 1)" }.joined(separator: ", ")
                parts.append(
                    "\(joined) stay on-model and visually consistent with their "
                    + "reference images throughout the shot."
                )
            }
            parts.append(
                "Preserve identity, design, colors, and proportions "
                + "from the referenced images throughout the shot."
            )
        } else if hasStartImage || hasEndImage {
            // ===== Image-to-video =====
            if hasStartImage && hasEndImage {
                parts.append("@Image1 is the first frame at t=0, @Image2 is the final frame at t=duration.")
            } else if hasStartImage {
                parts.append("@Image1 is the first frame at t=0.")
            }
            let actionFocus = SlopStripper.strip(payload.subject)
            if !actionFocus.isEmpty { parts.append(actionFocus) }
            if !payload.camera.isEmpty { parts.append(SlopStripper.strip(payload.camera)) }
            if !payload.light.isEmpty { parts.append(SlopStripper.strip(payload.light)) }
            parts.append("Preserve composition, colors, identity, and lighting from the anchor frame(s).")
        } else {
            // ===== Text-to-video (full 6-step) =====
            parts.append(SlopStripper.strip(payload.subject))
            if !payload.composition.isEmpty { parts.append(SlopStripper.strip(payload.composition)) }
            if !payload.setting.isEmpty { parts.append(SlopStripper.strip(payload.setting)) }
            if !payload.camera.isEmpty { parts.append(SlopStripper.strip(payload.camera)) }
            if !payload.light.isEmpty { parts.append(SlopStripper.strip(payload.light)) }
            if !payload.style.isEmpty { parts.append(SlopStripper.strip(payload.style)) }
        }

        // Step 6 — Constraints (positive).
        let userConstraints = (payload.negatives).map { PositivePhrasing.phrase($0) }
        var standardConstraints = BuilderSupport.seedanceStandardVideoPositives
        let subjectLower = payload.subject.lowercased()
        let hasCharacter = characterTokens.contains { subjectLower.contains($0) }
        if hasCharacter {
            standardConstraints.append(contentsOf: BuilderSupport.seedanceCharacterPositives)
        }
        if let shadowConstraint = BuilderSupport.cartoonShadowConstraint(payload) {
            standardConstraints.append(shadowConstraint)
        }
        let allConstraints = userConstraints + standardConstraints.filter { !userConstraints.contains($0) }
        if !allConstraints.isEmpty {
            parts.append("Constraints: " + allConstraints.joined(separator: "; ") + ".")
        }

        if let pacingBlock = BuilderSupport.seedancePacingBlock(payload.durationS, isPacingArm: isPacingArm) {
            parts.append(pacingBlock)
        }

        let hasRef = referenceTags != nil && !(referenceTags!.isEmpty)
        if hasRef || hasStartImage || hasEndImage {
            parts.append("Total: \(String(format: "%.0f", duration))s, \(aspect).")
        } else {
            let headerKind = n == 1
                ? "Single continuous shot as one continuous take"
                : "\(n)-shot sequence as one continuous take"
            parts.append("\(headerKind). Total: \(String(format: "%.0f", duration))s / \(aspect).")
        }
        parts.append(contentsOf: payload.directives)
        return BuilderSupport.joinClean(parts)
    }
}
