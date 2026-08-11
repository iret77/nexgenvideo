import Foundation

public enum ProductionPromptPolicy {
    private struct MovementPattern {
        let category: String
        let expression: NSRegularExpression
    }

    private static let movementPatterns: [MovementPattern] = [
        MovementPattern(
            category: "pan",
            expression: Rx.compile(
                #"\b(?:controlled\s+pan|whip[- ]?pan|(?:camera|lens|view|shot)\s+(?:slowly\s+|gently\s+|smoothly\s+)?pan(?:s|ned|ning)?)\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "tilt",
            expression: Rx.compile(
                #"\b(?:controlled\s+tilt|(?:camera|lens|view|shot)\s+(?:slowly\s+|gently\s+|smoothly\s+)?tilt(?:s|ed|ing)?(?:\s+(?:up|down))?)\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "dolly_in",
            expression: Rx.compile(
                #"\b(?:(?:dolly|push)[- ]?in|camera\s+(?:pushes|moves|glides|slides|advances)\s+(?:in|forward))\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "dolly_out",
            expression: Rx.compile(
                #"\b(?:(?:dolly|pull)[- ]?(?:out|back)|camera\s+(?:pulls|moves|glides|slides|retreats)\s+(?:out|back|backward))\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "tracking",
            expression: Rx.compile(
                #"\b(?:controlled\s+tracking\s+move|tracking\s+(?:camera|shot)|camera\s+(?:tracks|follows|trucks))\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "handheld",
            expression: Rx.compile(
                #"\b(?:controlled\s+handheld\s+movement|handheld(?:\s+(?:camera|movement|drift|sway))?|shaky[- ]?cam)\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "crane",
            expression: Rx.compile(
                #"\b(?:controlled\s+crane\s+move|camera\s+(?:cranes|booms|jibs)(?:\s+(?:up|down))?)\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "orbit",
            expression: Rx.compile(
                #"\b(?:controlled\s+orbit|camera\s+(?:orbits|circles|rotates\s+around))\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "zoom",
            expression: Rx.compile(
                #"\b(?:controlled\s+optical\s+zoom|(?:camera|lens|view|shot)\s+zoom(?:s|ed|ing)?(?:[- ]?(?:in|out))?)\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "generic",
            expression: Rx.compile(
                #"\b(?:(?:camera|lens|view|shot)\s+(?:slowly\s+|gently\s+|smoothly\s+)?(?:moves?|travels?|glides?|slides?|advances?|retreats?|sweeps?|arcs?)|(?:moving|gliding|sliding)\s+camera|controlled\s+camera\s+movement)\b"#,
                caseInsensitive: true
            )
        ),
    ]

    public static func stillPromptViolations(_ prompt: String) -> [String] {
        detectedMovementCategories(in: prompt).map {
            "still prompt contains camera movement category '\($0)'"
        }
    }

    public static func videoPromptViolations(
        _ prompt: String,
        expectedMovement: CameraMovement?
    ) -> [String] {
        guard let expectedMovement else { return [] }
        let detected = detectedMovementCategories(in: prompt)
        if expectedMovement == .other {
            guard detected.count <= 1 else {
                return ["video prompt contains multiple camera movement categories: \(detected.joined(separator: ", "))"]
            }
            return []
        }
        let allowed: Set<String>
        switch expectedMovement {
        case .static: allowed = []
        case .pan: allowed = ["pan"]
        case .tilt: allowed = ["tilt"]
        case .dollyIn: allowed = ["dolly_in"]
        case .dollyOut: allowed = ["dolly_out"]
        case .tracking: allowed = ["tracking"]
        case .handheld: allowed = ["handheld"]
        case .crane: allowed = ["crane"]
        case .orbit: allowed = ["orbit"]
        case .zoom: allowed = ["zoom"]
        case .other: allowed = []
        }
        let unexpected = detected.filter { !allowed.contains($0) }
        guard unexpected.isEmpty else {
            return ["video prompt contains camera movement outside the approved plan: \(unexpected.joined(separator: ", "))"]
        }
        return []
    }

    private static func detectedMovementCategories(in prompt: String) -> [String] {
        var detected = movementPatterns.compactMap { pattern in
            Rx.search(prompt, pattern.expression) ? pattern.category : nil
        }
        if detected.count > 1 {
            detected.removeAll { $0 == "generic" }
        }
        return detected
    }
}
