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
                #"\b(?:controlled\s+pan|whip[- ]?pan|pan(?:s|ned|ning)?\s+(?:left|right|across|around|toward|towards)|(?:camera|lens|view|shot)\s+(?:slowly\s+|gently\s+|smoothly\s+)?pan(?:s|ned|ning)?(?:\s+(?:left|right|across|around|toward|towards))?)\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "tilt",
            expression: Rx.compile(
                #"\b(?:controlled\s+tilt|tilt(?:s|ed|ing)?\s+(?:up|down)|(?:camera|lens|view|shot)\s+(?:slowly\s+|gently\s+|smoothly\s+)?tilt(?:s|ed|ing)?(?:\s+(?:up|down))?)\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "dolly_in",
            expression: Rx.compile(
                #"\b(?:(?:dolly|push)[- ]?in|(?:camera|lens|view|shot)\s+(?:slowly\s+|gently\s+|smoothly\s+)?(?:(?:is|was)\s+)?(?:doll(?:y|ies|ied|ying)|push(?:es|ed|ing)?|mov(?:e|es|ed|ing)|glid(?:e|es|ed|ing)|slid(?:e|es|ing)|advanc(?:e|es|ed|ing))\s+(?:in|forward))\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "dolly_out",
            expression: Rx.compile(
                #"\b(?:(?:dolly|pull)[- ]?(?:out|back)|(?:camera|lens|view|shot)\s+(?:slowly\s+|gently\s+|smoothly\s+)?(?:(?:is|was)\s+)?(?:doll(?:y|ies|ied|ying)|pull(?:s|ed|ing)?|mov(?:e|es|ed|ing)|glid(?:e|es|ed|ing)|slid(?:e|es|ing)|retreat(?:s|ed|ing)?)\s+(?:out|back|backward))\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "tracking",
            expression: Rx.compile(
                #"\b(?:controlled\s+tracking\s+move|tracking\s+(?:camera|shot)|track(?:s|ed|ing)?\s+(?:left|right|forward|back|along|with)|camera\s+(?:tracks|follows|trucks))\b"#,
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
                #"\b(?:controlled\s+crane\s+move|crane(?:s|d|ing)?\s+(?:up|down)|camera\s+(?:cranes|booms|jibs)(?:\s+(?:up|down))?)\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "orbit",
            expression: Rx.compile(
                #"\b(?:controlled\s+orbit|orbit(?:s|ed|ing)?\s+around|camera\s+(?:orbits|circles|rotates\s+around))\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "zoom",
            expression: Rx.compile(
                #"\b(?:controlled\s+optical\s+zoom|zoom(?:s|ed|ing)?[- ]?(?:in|out)|(?:camera|lens|view|shot)\s+zoom(?:s|ed|ing)?(?:[- ]?(?:in|out))?)\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "pedestal",
            expression: Rx.compile(
                #"\b(?:pedestal(?:\s+(?:up|down|rise|drop))?|camera\s+(?:rises|lowers|elevates|descends)\s+vertically)\b"#,
                caseInsensitive: true
            )
        ),
        MovementPattern(
            category: "generic",
            expression: Rx.compile(
                #"\b(?:(?:camera|lens|view|shot|frame)\s+(?:slowly\s+|gently\s+|smoothly\s+)?(?:(?:is|was)\s+)?(?:mov(?:e|es|ed|ing)|travel(?:s|ed|ing)?|glid(?:e|es|ed|ing)|slid(?:e|es|ing)|advanc(?:e|es|ed|ing)|retreat(?:s|ed|ing)?|sweep(?:s|ing)?|swept|arc(?:s|ed|ing)?|doll(?:y|ies|ied|ying)|drift(?:s|ed|ing)?|creep(?:s|ing)?|crept|eas(?:e|es|ed|ing)|float(?:s|ed|ing)?|crawl(?:s|ed|ing)?|swoop(?:s|ed|ing)?|ris(?:e|es|en|ing)|rose|descend(?:s|ed|ing)?)|(?:moving|gliding|sliding|dollying|drifting|floating)\s+camera|controlled\s+camera\s+movement)\b"#,
                caseInsensitive: true
            )
        ),
    ]

    public static func stillPromptViolations(_ prompt: String) -> [String] {
        detectedMovementOccurrences(in: prompt).map {
            "still prompt contains camera movement category '\($0.category)'"
        }
    }

    public static func videoPromptViolations(
        _ prompt: String,
        expectedMovement: CameraMovement?,
        expectedMovementDetail: String?
    ) -> [String] {
        guard let expectedMovement else { return [] }
        let approvedDirective = expectedMovement.promptProse(detail: expectedMovementDetail)
        let approvedExpression = Rx.compile(
            Rx.escape(approvedDirective),
            caseInsensitive: true
        )
        let approvedCount = Rx.allGroup0(prompt, approvedExpression).count
        guard approvedCount == 1 else {
            return [
                approvedCount == 0
                    ? "video prompt is missing the exact approved camera movement"
                    : "video prompt repeats the approved camera movement \(approvedCount) times",
            ]
        }
        let remainder = Rx.sub(prompt, approvedExpression, with: "")
        let outsidePlan = detectedMovementOccurrences(in: remainder)
        guard outsidePlan.isEmpty else {
            let labels = outsidePlan.map {
                $0.count == 1 ? $0.category : "\($0.category) (\($0.count)x)"
            }
            return [
                "video prompt contains camera movement outside the approved plan: "
                    + labels.joined(separator: ", "),
            ]
        }
        return []
    }

    public static func cameraMovementDetailViolations(
        _ detail: String,
        expectedMovement: CameraMovement
    ) -> [String] {
        let detected = detectedMovementOccurrences(in: detail)
        if expectedMovement == .other {
            let count = detected.reduce(0) { $0 + $1.count }
            return detected.count <= 1 && count <= 1
                ? []
                : ["camera movement detail contains multiple movements"]
        }
        let expectedCategory: String?
        switch expectedMovement {
        case .static: expectedCategory = nil
        case .pan: expectedCategory = "pan"
        case .tilt: expectedCategory = "tilt"
        case .dollyIn: expectedCategory = "dolly_in"
        case .dollyOut: expectedCategory = "dolly_out"
        case .tracking: expectedCategory = "tracking"
        case .handheld: expectedCategory = "handheld"
        case .crane: expectedCategory = "crane"
        case .orbit: expectedCategory = "orbit"
        case .zoom: expectedCategory = "zoom"
        case .other: expectedCategory = nil
        }
        let unexpected = detected.filter { $0.category != expectedCategory }
        let repeated = detected.contains { $0.count > 1 }
        return unexpected.isEmpty && !repeated
            ? []
            : ["camera movement detail conflicts with the declared movement"]
    }

    private static func detectedMovementOccurrences(
        in prompt: String
    ) -> [(category: String, count: Int)] {
        var detected = movementPatterns.compactMap { pattern in
            let count = Rx.allGroup0(prompt, pattern.expression).count
            return count == 0 ? nil : (pattern.category, count)
        }
        if detected.contains(where: { $0.category != "generic" }) {
            detected.removeAll { $0.category == "generic" }
        }
        return detected
    }
}
