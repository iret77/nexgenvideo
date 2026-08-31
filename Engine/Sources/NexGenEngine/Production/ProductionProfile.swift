import Foundation

public struct ProductionProfileID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public static let generativeFilm: Self = "generative_film"
    public static let narrativeStorytelling: Self = "narrative_storytelling"
}

public enum ProductionProfileActivation: Sendable, Equatable {
    case always
    case metadataValue(key: String, allowedValues: Set<String>)

    public func matches(_ metadata: [String: String]) -> Bool {
        switch self {
        case .always:
            return true
        case .metadataValue(let key, let allowedValues):
            guard let value = metadata[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                !value.isEmpty else { return false }
            return allowedValues.contains(value)
        }
    }

}

public struct ProductionProfile: Sendable, Equatable {
    public let id: ProductionProfileID
    public let activation: ProductionProfileActivation

    public init(id: ProductionProfileID, activation: ProductionProfileActivation) {
        self.id = id
        self.activation = activation
    }
}

public enum StandardProductionProfiles {
    public static let generativeFilm = ProductionProfile(
        id: .generativeFilm,
        activation: .always
    )

    public static let narrativeStorytelling = ProductionProfile(
        id: .narrativeStorytelling,
        activation: .metadataValue(
            key: "concept_type",
            allowedValues: ["narrative", "hybrid"]
        )
    )
}

public enum ProductionDiscipline {
    @available(*, deprecated, message: "Resolve visible-character capacity from the selected route")
    public static let maximumGeneratedVisibleCharacters = 2
    @available(*, deprecated, message: "Resolve duration capacity from the selected route")
    public static let normalGeneratedShotMaximumDuration = 12.0

    public static func requiresProductionPlan(_ shot: Shot) -> Bool {
        shot.sourceMode != .imported
    }

    public static func visibleCharacterCount(
        _ shot: Shot,
        bible: Bible?
    ) -> Int {
        let ensembleCounts = Dictionary(
            uniqueKeysWithValues: (bible?.ensembles ?? []).map {
                ($0.id, $0.memberCount)
            }
        )
        return shot.characterRefs.reduce(into: 0) { count, reference in
            count += ensembleCounts[reference] ?? 1
        }
    }

    @available(*, deprecated, message: "Revalidate ProductionRequirementV1 against a selected route")
    public static func hasTooManyVisibleCharacters(
        _ shot: Shot,
        bible: Bible? = nil
    ) -> Bool {
        hasTooManyVisibleCharacters(shot, bible: bible, route: nil)
    }

    public static func hasTooManyVisibleCharacters(
        _ shot: Shot,
        bible: Bible?,
        route: ProductionRouteDisciplineV1?
    ) -> Bool {
        guard let maximum = route?.maximumVisibleCharacters else { return false }
        return shot.sourceMode == .generated
            && visibleCharacterCount(shot, bible: bible)
                > maximum
    }

    @available(*, deprecated, message: "Revalidate ProductionRequirementV1 against a selected route")
    public static func hasUndeclaredLongTake(_ shot: Shot) -> Bool {
        hasUndeclaredLongTake(shot, route: nil)
    }

    public static func hasUndeclaredLongTake(
        _ shot: Shot,
        route: ProductionRouteDisciplineV1?
    ) -> Bool {
        guard let maximum = route?.maximumDurationSeconds else { return false }
        guard shot.sourceMode == .generated,
              shot.durationS > maximum,
              let plan = shot.productionPlan else { return false }
        return !plan.risks.contains(.longTake)
    }

    public static func exceedsReferenceCapacity(
        _ shot: Shot,
        route: ProductionRouteDisciplineV1? = nil
    ) -> Bool {
        guard let maximum = route?.maximumReferences else { return false }
        return shot.sourceMode != .imported
            && shot.referenceImageRefs.count > maximum
    }

    public static func hasUnanchoredCharacterBlocking(_ shot: Shot) -> Bool {
        let plan = shot.productionPlan
        return shot.sourceMode == .generated
            && shot.characterBlocking.contains {
                !hasValidSetAnchor(
                    plan?.setAnchor(for: $0.characterRef),
                    relationToSet: $0.relationToSet,
                    declaredAnchors: shot.visibleZones + shot.propRefs
                )
            }
    }

    public static func hasUnanchoredCharacterBlocking(_ step: Step) -> Bool {
        step.sourceMode == .generated
            && step.characterBlocking.contains {
                !hasValidSetAnchor(
                    $0["set_anchor"],
                    relationToSet: $0["relation_to_set"],
                    declaredAnchors: step.visibleZones + step.propRequest
                )
            }
    }

    private static func hasValidSetAnchor(
        _ setAnchor: String?,
        relationToSet: String?,
        declaredAnchors: [String]
    ) -> Bool {
        guard let setAnchor,
              !setAnchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isDirectionOnlyAnchor(setAnchor),
              let relationToSet,
              !relationToSet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let normalized = normalizeAnchor(setAnchor)
        return declaredAnchors.contains {
            normalizeAnchor($0) == normalized
        }
    }

    private static let directionOnlyAnchorTokens: Set<String> = [
        "the", "of", "screen", "camera", "frame", "image", "shot", "stage",
        "upper", "lower", "top", "bottom", "left", "right", "center", "centre",
        "middle", "foreground", "background", "front", "back", "near", "far",
        "edge", "side", "third", "corner", "area", "region", "zone", "quadrant",
        "portion", "plane",
    ]

    private static func isDirectionOnlyAnchor(_ value: String) -> Bool {
        let tokens = normalizeAnchor(value).split(separator: " ").map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy(directionOnlyAnchorTokens.contains)
    }

    private static func normalizeAnchor(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public enum ProductionProfileGuidance {
    public static func instructions(
        for phase: String,
        profiles: [ProductionProfile]
    ) -> String {
        profiles.compactMap { profile in
            guard let body = guidance(profile.id, phase: phase) else { return nil }
            return "## Core production profile: \(profile.id.rawValue)\n\(body)"
        }.joined(separator: "\n\n")
    }

    private static func guidance(_ id: ProductionProfileID, phase: String) -> String? {
        if id == .generativeFilm {
            switch phase {
        case "production_design":
            return """
            Define the style layer before shots: visual vocabulary, mood, color language, lighting intent, and continuity requirements. Keep character sheets, location geometry, reverse views, and prop sheets in the later Bible phase.
            """
        case "treatment":
            return """
            Design for shots the available models can render reliably. Prefer ellipsis over simulating a difficult continuous action. Flag risky ideas early and define a simpler rescue cut that preserves the same story beat.
            """
        case "storyboard":
            return """
            Keep each generated step to one primary subject action and one coherent camera plan. Preserve every required visible entity and reference demand in structured fields; route selection determines whether a concrete offering can fulfill them. Every character_blocking.set_anchor must exactly name one of that step's visible_zones or prop_request entries; put its spatial relation in character_blocking.relation_to_set. Make entrances, exits, and screen direction explicit in the storyboard fields and notes accepted by the writer.
            """
        case "bible":
            return """
            Preserve the approved style anchor, character states, location geometry, reverse views, props, and scale relationships as named reusable assets. Do not replace exact anchors with prose-only descriptions.
            """
        case "shotlist":
            return """
            Give every generated or AI-enhanced shot a production_plan; imported shots omit it. Preserve the requested duration, visible entities, identity locks, reference jobs, mode, resolution, aspect ratio, and audio intent without reducing them to a lowest-common-denominator model. Plan those demands against the selected route's effective capability profile. Keep one primary action and one coherent camera plan. Every production_plan.blocking_anchors value must exactly name one of that shot's visible_zones or prop_refs entries. Keep visual_prompt to one present-tense sentence describing only the concrete frame-zero subject state: identity, pose, weight, gaze, hands, and impending movement vector. Camera, composition, blocking anchors, continuity, and action stay in their structured fields. Rate renderability green/yellow/red; explicitly assess readable in-frame text, mirrors/reflections, fine hand actions, close eating/drinking, dense face crowds, continuous fights, physics showcases, vehicle mechanics, identity drift, lip sync, duration, camera movement, and complex interactions. Add a rescue cut for every yellow/red shot, and record continuity locks plus match-action cues.
            """
        case "sanity":
            return """
            Treat missing required production plans and yellow/red shots without rescue cuts as production defects. Revalidate the exact ProductionRequirement against the selected route; report structured capability deficits instead of dropping entities, references, modes, or duration. Resolve defects in the owning artifact instead of explaining them away in prose.
            """
        case "frames":
            return """
            Generate and approve still anchors only for generated shots whose keyframe strategy requires them. Skip imported and AI-enhanced shots. A start frame is the exact state at t=0; an end frame is the exact state at t=duration, including the camera endpoint. Never use a representative mid-state. Pass only the shot's concrete frame-role subject as compile_prompt intent. The compiler owns structured camera, composition, blocking, continuity, and all applicable locked ledger directives; do not reconstruct or append those fields in phase prose. Caller setting, lighting, and style are ignored for shot-bound frames. Carry forward named characters, locations, props, and reference truth without substitutes.
            """
        case "render":
            return """
            Render from the approved shot plan and anchors. Keep prompts concise, preserve the declared primary action and camera move, and use the planned rescue cut rather than improvising when a risky shot fails.
            """
        default:
            break
            }
        }

        if id == .narrativeStorytelling {
            switch phase {
        case "treatment":
            return """
            Express the story as observable beats and consequences, not backstory prose. Plan a clear progression from establishment through action and reaction to a resolving detail or transition.
            """
        case "storyboard":
            return """
            Assign every shot a narrative function: establish, action, reaction, detail, or transition. A sequence may compress time, but its spatial and emotional causality must remain legible.
            """
        case "shotlist":
            return """
            Set narrative_beat on every planned generated or AI-enhanced shot. Preserve the approved causal order and make reactions or details visible instead of relying on dialogue or exposition to explain the beat.
            """
        case "sanity":
            return """
            Verify that every planned shot has a narrative beat and that multi-shot sections establish context before action while retaining at least one reaction, detail, or transition beat.
            """
        default:
            break
            }
        }
        return nil
    }
}
