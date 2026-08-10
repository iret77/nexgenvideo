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
    public static let maximumGeneratedVisibleCharacters = 2
    public static let normalGeneratedShotMaximumDuration = 12.0

    private static let directionOnlySetAnchors: Set<String> = [
        "left", "right", "center", "centre",
        "screen left", "screen right", "screen center", "screen centre",
        "camera left", "camera right", "camera center", "camera centre",
        "frame left", "frame right", "frame center", "frame centre",
    ]

    public static func requiresProductionPlan(_ shot: Shot) -> Bool {
        shot.sourceMode != .imported
    }

    public static func hasTooManyVisibleCharacters(_ shot: Shot) -> Bool {
        shot.sourceMode == .generated
            && shot.characterRefs.count > maximumGeneratedVisibleCharacters
    }

    public static func hasUndeclaredLongTake(_ shot: Shot) -> Bool {
        guard shot.sourceMode == .generated,
              shot.durationS > normalGeneratedShotMaximumDuration,
              let plan = shot.productionPlan else { return false }
        return !plan.risks.contains(.longTake)
    }

    public static func hasUnanchoredCharacterBlocking(_ shot: Shot) -> Bool {
        shot.sourceMode == .generated
            && shot.characterBlocking.contains {
                !hasValidSetAnchor(
                    $0.setAnchor,
                    relationToSet: $0.relationToSet
                )
            }
    }

    public static func hasUnanchoredCharacterBlocking(_ step: Step) -> Bool {
        step.sourceMode == .generated
            && step.characterBlocking.contains {
                !hasValidSetAnchor(
                    $0["set_anchor"],
                    relationToSet: $0["relation_to_set"]
                )
            }
    }

    private static func hasValidSetAnchor(
        _ setAnchor: String?,
        relationToSet: String?
    ) -> Bool {
        guard let setAnchor,
              !setAnchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let relationToSet,
              !relationToSet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let normalized = setAnchor.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return !directionOnlySetAnchors.contains(normalized)
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
            Build reusable production assets before shots: a style anchor, character sheets for every visible state, and location geometry with named zones, camera anchors, and reverse views. Treat identity, scale, wardrobe, props, lighting, and screen direction as continuity facts.
            """
        case "treatment":
            return """
            Design for shots the available models can render reliably. Prefer ellipsis over simulating a difficult continuous action. Flag risky ideas early and define a simpler rescue cut that preserves the same story beat.
            """
        case "storyboard":
            return """
            Keep each generated shot to one primary subject action and one camera movement, with no more than two visible characters. Name each generated-shot blocking set_anchor separately from its spatial relation. Make entrances, exits, screen direction, match-action cues, and continuity locks explicit.
            """
        case "bible":
            return """
            Preserve the approved style anchor, character states, location geometry, reverse views, props, and scale relationships as named reusable assets. Do not replace exact anchors with prose-only descriptions.
            """
        case "shotlist":
            return """
            Give every generated or AI-enhanced shot a production_plan; imported shots omit it. Generated shots should normally last 4–12 seconds, contain one primary action, one camera movement, and at most two visible characters. Rate renderability green/yellow/red; explicitly assess readable in-frame text, mirrors/reflections, fine hand actions, close eating/drinking, dense face crowds, continuous fights, physics showcases, vehicle mechanics, identity drift, non-English lip sync, long takes, aggressive camera moves, and complex interactions. Add a rescue cut for every yellow/red shot, and record continuity locks plus match-action cues.
            """
        case "sanity":
            return """
            Treat missing required production plans, generated-shot undeclared long takes or excessive visible characters, and yellow/red shots without rescue cuts as production defects. Resolve them in the owning artifact instead of explaining them away in prose.
            """
        case "frames":
            return """
            Generate and approve still anchors before motion. Carry forward the shot's named characters, locations, props, continuity locks, and exact camera setup; do not invent substitutes during frame generation.
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
